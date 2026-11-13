/// 平滑光标 overlay。
///
/// 两个独立动画:
/// - **移动滑行**:caretRect 变化时从当前显示位置 RectTween 滑到新位置
///   (~90ms easeOutCubic;跨行/字号变化时高度一并插值)。首次出现/
///   重新聚焦直接落位,不从旧位置飞。
/// - **呼吸闪烁**:亮-渐隐-灭-渐现循环(1100ms 周期),替代传统硬切。
///   光标移动/打字时重置为常亮段(主流编辑器手感);composing 期间
///   [alwaysVisible] 常亮。
library;

import 'package:flutter/widgets.dart';
import '../../config/render_shapes.dart';

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

  /// 呼吸曲线:前 40% 常亮(打字时反复重置只会停留在这段)→ 渐隐 →
  /// 短灭 → 渐现 → 短亮,循环。
  static final Animatable<double> _blinkCurve = TweenSequence<double>([
    TweenSequenceItem(tween: ConstantTween(1), weight: 40),
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.0)
          .chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 16,
    ),
    TweenSequenceItem(tween: ConstantTween(0), weight: 14),
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.0)
          .chain(CurveTween(curve: Curves.easeInCubic)),
      weight: 16,
    ),
    TweenSequenceItem(tween: ConstantTween(1), weight: 14),
  ]);

  Animation<Rect?>? _rectAnim;

  /// reduce-motion(didChangeDependencies 缓存):滑行退化为直接落位,
  /// 呼吸退化为硬切闪烁。
  bool _reduceMotion = false;

  Rect? get _displayRect => _rectAnim?.value ?? widget.caretRect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
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
      _blink.stop();
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
      final smallSameLineStep = from != null &&
          (from.top - target.top).abs() < target.height * 0.5 &&
          (from.left - target.left).abs() <= target.height * 1.5;
      if (from == null || _reduceMotion || (isEditFrame && smallSameLineStep)) {
        // 首次出现/重新聚焦/reduce-motion/打字小步:直接落位。
        _move.stop();
        _rectAnim = AlwaysStoppedAnimation(target);
      } else if (from != target) {
        _rectAnim = _move.drive(
          RectTween(begin: from, end: target)
              .chain(CurveTween(curve: Curves.easeOutCubic)),
        );
        _move.forward(from: 0);
      }
    }
    // 移动/打字/composing 切换 → 回到常亮段重新计时。
    _blink.value = 0;
    _startBlink();
  }

  void _startBlink() {
    if (widget.alwaysVisible) {
      _blink.stop();
      _blink.value = 0; // 常亮段
    } else if (!_blink.isAnimating) {
      _blink.repeat();
    }
  }

  @override
  void dispose() {
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
        var opacity =
            widget.alwaysVisible ? 1.0 : _blinkCurve.evaluate(_blink);
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
                decoration: ShapeDecoration(color: widget.color,shape: RoundedSuperellipseBorder(borderRadius: context.renderShapes.borderRadius(1), ),),
              ),
            ),
          ),
        );
      },
    );
  }
}
