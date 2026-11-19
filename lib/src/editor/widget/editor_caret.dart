/// 平滑光标 overlay。
///
/// 两个独立动画:
/// - **移动滑行**:caretRect 变化时从当前显示位置 RectTween 滑到新位置
///   (~90ms easeOutCubic;跨行/字号变化时高度一并插值)。首次出现/
///   重新聚焦直接落位,不从旧位置飞。
/// - **呼吸闪烁**:亮-渐隐-灭-渐现循环(1100ms 周期),替代传统硬切。
///   光标移动/打字时重置为常亮段(主流编辑器手感);composing 期间
///   [alwaysVisible] 常亮。只有渐隐、渐现两段逐帧动画;常亮、常灭段画面
///   不变,等待期间不出帧(整圈约 2/3 的时间,见 [FrameAlignedWakeup]),
///   编辑器聚焦时同屏的玻璃工具岛等也不必每帧重算。
library;

import 'package:flutter/widgets.dart';
import '../../config/render_shapes.dart';
import '../../render/frame_aligned_wakeup.dart';

class EditorCaret extends StatefulWidget {
  const EditorCaret({
    super.key,
    required this.caretRect,
    required this.color,
    this.alwaysVisible = false,
    this.moveGeneration = 0,
  });

  /// 编辑器局部坐标系里的光标矩形(宽 0,画 2px 竖线);null = 无光标。
  final Rect? caretRect;

  final Color color;

  final bool alwaysVisible;

  /// 移动代际:与上次 build 相同 → 纯导航(点击/方向键),位置变化滑行;
  /// 不同 → 编辑帧,按**移动距离**细分(VS Code explicit 模式的改良):
  /// - 同行小步(打字/退格,≤ ~1.5 字符宽)→ 瞬时贴上。文字排版是瞬时的,
  ///   小步滑行会让光标永远追着刚打出的字跑(VS Code `on` 模式的通病);
  /// - 跨行/大跳(回车、段合并、删除选区、软换行跨行)→ 照常滑行,
  ///   大位移的动画是视觉锚点,不存在追赶感。
  final int moveGeneration;

  @override
  State<EditorCaret> createState() => _EditorCaretState();
}

class _EditorCaretState extends State<EditorCaret>
    with TickerProviderStateMixin {
  // 不能用惰性字段初始化器(late final = AnimationController(...)):
  // 光标从未显示过时首次访问会发生在 dispose() → unmount 期间
  // createTicker 崩溃("Looking up a deactivated widget's ancestor")。
  late final AnimationController _move;
  late final AnimationController _blink;

  @override
  void initState() {
    super.initState();
    _move = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (widget.caretRect != null) {
      _rectAnim = AlwaysStoppedAnimation(widget.caretRect);
      _startBlink();
    }
  }

  static const Duration _blinkPeriod = Duration(milliseconds: 1100);

  /// 呼吸曲线里的两段渐变(起止占周期比例),与 [_blinkCurve] 的权重对应
  /// (40 常亮 / 16 渐隐 / 14 常灭 / 16 渐现 / 14 常亮),渐变之外曲线是常值
  static const List<(double, double)> _blinkFades = [
    (0.40, 0.56),
    (0.70, 0.86),
  ];

  /// 等待下一段渐变;代际号让重置 / 停止时丢弃在途的链
  FrameAlignedWakeup? _blinkWakeup;
  int _blinkGeneration = 0;
  bool _blinking = false;

  /// 本圈起点的帧时间戳,各段按它定时,节拍不随回调延迟累积漂移
  Duration _blinkOrigin = Duration.zero;

  /// 呼吸曲线:前 40% 常亮(打字时反复重置只会停留在这段)→ 渐隐 →
  /// 短灭 → 渐现 → 短亮,循环。
  static final Animatable<double> _blinkCurve = TweenSequence<double>([
    TweenSequenceItem(tween: ConstantTween(1), weight: 40),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 0.0,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 16,
    ),
    TweenSequenceItem(tween: ConstantTween(0), weight: 14),
    TweenSequenceItem(
      tween: Tween(
        begin: 0.0,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 16,
    ),
    TweenSequenceItem(tween: ConstantTween(1), weight: 14),
  ]);

  Animation<Rect?>? _rectAnim;

  /// reduce-motion(didChangeDependencies 缓存):滑行退化为直接落位,
  /// 呼吸退化为硬切闪烁。
  bool _reduceMotion = false;

  Rect? get _displayRect => _rectAnim?.value ?? widget.caretRect;

  /// 所在路由可见(TickerMode)。常值段的计时器不受 Ticker 静音约束,
  /// 路由被盖住时整条呼吸链停下,回来后从常亮段重新开始
  bool _tickerEnabled = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _tickerEnabled) {
      _tickerEnabled = enabled;
      _stopBlink();
      if (widget.caretRect != null) _startBlink();
    }
  }

  @override
  void didUpdateWidget(covariant EditorCaret oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.caretRect;
    final rectChanged = target != oldWidget.caretRect;
    if (!rectChanged && widget.alwaysVisible == oldWidget.alwaysVisible) {
      return;
    }

    if (target == null) {
      _move.stop();
      _stopBlink();
      _rectAnim = null;
      return;
    }

    if (rectChanged) {
      // 起点必须取「当前显示位置」:动画进行中取动画值,否则取**旧** widget
      // 的 rect —— 不能 fallback 到 widget.caretRect(那是新目标,会导致
      // from == target、tween 永不启动、光标瞬移)。
      final from = _rectAnim?.value ?? oldWidget.caretRect;
      final isEditFrame = widget.moveGeneration != oldWidget.moveGeneration;
      // 同行小步:垂直基本重合 + 水平位移 ≤ ~1.5 字符宽(行高近似字宽上界)
      final smallSameLineStep =
          from != null &&
          (from.top - target.top).abs() < target.height * 0.5 &&
          (from.left - target.left).abs() <= target.height * 1.5;
      if (from == null || _reduceMotion || (isEditFrame && smallSameLineStep)) {
        // 首次出现/重新聚焦/reduce-motion/打字小步:直接落位。
        _move.stop();
        _rectAnim = AlwaysStoppedAnimation(target);
      } else if (from != target) {
        _rectAnim = _move.drive(
          RectTween(
            begin: from,
            end: target,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
        );
        _move.forward(from: 0);
      }
    }
    // 移动/打字/composing 切换 → 回到常亮段重新计时。
    _stopBlink();
    _startBlink();
  }

  void _startBlink() {
    if (widget.alwaysVisible || !_tickerEnabled) {
      _stopBlink(); // 停在常亮段
    } else if (!_blinking) {
      _blinking = true;
      final generation = _blinkGeneration;
      // 以下一帧为本圈起点(此前停在常亮段,画面不变)
      _blinkWakeup = FrameAlignedWakeup(
        target: Duration.zero,
        now: null,
        onFrame: (timeStamp) {
          _blinkWakeup = null;
          if (!mounted || generation != _blinkGeneration) return;
          _blinkOrigin = timeStamp;
          _scheduleFade(0, generation, timeStamp);
        },
      );
    }
  }

  /// 停止呼吸并回到常亮段起点
  void _stopBlink() {
    _blinkGeneration++;
    _blinking = false;
    _blinkWakeup?.cancel();
    _blinkWakeup = null;
    _blink.stop();
    _blink.value = 0;
  }

  Duration _blinkAt(double fraction) => _blinkOrigin + _blinkPeriod * fraction;

  /// 常值段只等待、不出帧,到第 [index] 段渐变的起点再逐帧推进。渐变的
  /// 值按「本圈起点 + 已过时间」算,每一帧都与原来连续循环时的值相同,
  /// 不受唤醒落在哪个 vsync 影响。reduce-motion 下渐变是硬切,直接等到
  /// 曲线越过 0.5 的那一刻再跳。
  void _scheduleFade(int index, int generation, Duration? now) {
    final (start, end) = _blinkFades[index];
    _blinkWakeup = FrameAlignedWakeup(
      target: _blinkAt(_reduceMotion ? _crossingOf(index) : start),
      now: now,
      onFrame: (timeStamp) {
        _blinkWakeup = null;
        if (!mounted || generation != _blinkGeneration) return;
        final phase =
            (timeStamp - _blinkOrigin).inMicroseconds /
            _blinkPeriod.inMicroseconds;
        if (_reduceMotion || phase >= end) {
          _blink.value = end;
          _afterFade(index, generation, timeStamp);
          return;
        }
        // 先把这一帧的值写进去:animateWith 起步时只设值、不通知,不写的话
        // 这一帧还显示上一段的值。模拟的 0 时刻就是这一帧(在帧回调里启动)
        _blink.value = phase.clamp(start, end);
        _blink
            .animateWith(
              _BlinkFadeSimulation(
                phase: phase,
                start: start,
                end: end,
                period: _blinkPeriod,
              ),
            )
            .whenCompleteOrCancel(() {
              if (!mounted || generation != _blinkGeneration) return;
              _afterFade(index, generation, FrameAlignedWakeup.frameNow);
            });
      },
    );
  }

  void _afterFade(int index, int generation, Duration? now) {
    if (index + 1 < _blinkFades.length) {
      _scheduleFade(index + 1, generation, now);
      return;
    }
    // 一圈走完回到常亮段,下一圈从本圈终点接着算
    _blinkOrigin += _blinkPeriod;
    _blink.value = 0;
    _scheduleFade(0, generation, now);
  }

  /// 第 [index] 段渐变里曲线越过 0.5 的位置(二分,按段缓存)
  static final Map<int, double> _crossings = {};
  static double _crossingOf(int index) => _crossings.putIfAbsent(index, () {
    final (start, end) = _blinkFades[index];
    final rising = _blinkCurve.transform(end) > _blinkCurve.transform(start);
    var lo = start, hi = end;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if ((_blinkCurve.transform(mid) >= 0.5) == rising) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return hi;
  });

  @override
  void dispose() {
    _blinkWakeup?.cancel();
    _move.dispose();
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.caretRect == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: Listenable.merge([_move, _blink]),
      builder: (context, _) {
        final rect = _displayRect;
        if (rect == null) return const SizedBox.shrink();
        var opacity = widget.alwaysVisible ? 1.0 : _blinkCurve.evaluate(_blink);
        if (_reduceMotion) opacity = opacity >= 0.5 ? 1.0 : 0.0;
        return Positioned(
          left: rect.left - 1,
          top: rect.top,
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity,
              child: Container(
                width: 2,
                height: rect.height,
                decoration: ShapeDecoration(
                  color: widget.color,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.renderShapes.borderRadius(1),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 渐变段:值随时间匀速前进(一圈 [period]),限定在 [start, end] 内;
/// [phase] 是启动那一帧在本圈里的位置,可能略早于 [start]
class _BlinkFadeSimulation extends Simulation {
  _BlinkFadeSimulation({
    required this.phase,
    required this.start,
    required this.end,
    required Duration period,
  }) : _speed = Duration.microsecondsPerSecond / period.inMicroseconds;

  final double phase;
  final double start;
  final double end;
  final double _speed;

  @override
  double x(double time) => (phase + time * _speed).clamp(start, end);

  @override
  double dx(double time) => _speed;

  @override
  bool isDone(double time) => phase + time * _speed >= end;
}
