/// Spoiler 遮罩效果 —— GPU fragment shader 程序化粒子(参考 Telegram
/// 新版做法):粒子完全在 `shaders/spoiler.frag` 里按 hash(cell, time)
/// 生成,CPU 侧每帧只更新一个 time uniform + 一次 drawRect(替代旧 CPU
/// 粒子系统:每实例每帧模拟 120~900 个粒子对象 + 分桶拷贝 Float32List,
/// 多实例同屏线性叠加卡顿)。
///
/// GPU 侧成本 ∝ 可见面积 × 每像素 ops,且 Impeller 无 raster cache、
/// 可见区域每帧重执行 shader —— 所以 .frag 必须保持每像素几十 ops 量级
/// (见 frag 头注释),widget 侧动画更新率压到 ~30fps。
///
/// 未揭示时 shader 输出不透明色(背景并入)**完全遮盖**内容;shader
/// 未加载/加载失败时退化为纯色静态遮罩。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;

/// spoiler 动画 Ticker 的统一门控(块级 [_SpoilerBlockWidget] / 行内
/// [_SpoilerInlineWidget] 共用,此前两处复制导致同款缺陷):
///
/// - ~30fps 节流:尘埃闪烁无需满帧率;
/// - **屏幕可见性门控**(修复项):sliver 挂载(cacheExtent 预取区)≠ 可见。
///   Ticker 常驻会让整个 app 永不进入空闲帧 —— Priority.idle 的 chunk
///   预热被饿死、帧管线全速空转,视口外的遮罩还在每 33ms 烧一次 GPU
///   (Impeller 无 raster cache,shader 全量重执行)。现在不可见即停表,
///   降级为 500ms 低频探针待命(普通 Timer,不驱动帧调度),回到屏内
///   自动复跑;粒子场取全局时钟,复跑不回卷。
/// - reveal / reduce-motion 语义与原实现一致。
mixin SpoilerTickerGate<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  static const Duration _tickInterval = Duration(milliseconds: 33);
  static const Duration _wakeProbeInterval = Duration(milliseconds: 500);

  /// shader 时间源 —— Ticker 只更新 value(painter 以其为 repaint
  /// Listenable),不 setState 重建 widget 子树。
  final ValueNotifier<double> spoilerTime =
      ValueNotifier(SpoilerShader.timeSeconds);

  Ticker? _gateTicker;
  Timer? _wakeProbe;
  Duration _lastTick = Duration.zero;
  Size _screenSize = Size.zero;

  bool spoilerRevealed = false;
  bool spoilerReduceMotion = false;

  /// 揭开涟漪动画(Telegram `SpoilerEffect.startRipple` 同款):点击后
  /// 以点击处为圆心、区域对角线为最大半径做圆形裁剪扩散,内容随圆
  /// 扩大显形、粒子遮罩同步淡出;时长 clamp(对角线×0.3, 250, 550)ms,
  /// 结束后 [spoilerRevealed] 才置真(此前仍是遮蔽态 + 动画层)。
  bool spoilerRevealing = false;
  final ValueNotifier<double> spoilerRevealProgress = ValueNotifier(0);
  Offset? spoilerRevealOrigin;
  Duration? _revealClockStart;
  double _revealDurationMs = 250;

  /// initState 里调用。
  void initSpoilerTicker() {
    _gateTicker = createTicker(_onSpoilerTick);
  }

  /// didChangeDependencies 里调用:同步 reduce-motion,并缓存屏幕尺寸
  /// (tick 回调里不能 depend InheritedWidget)。
  void syncSpoilerDeps() {
    final mq = MediaQuery.maybeOf(context);
    spoilerReduceMotion = mq?.disableAnimations ?? false;
    _screenSize = mq?.size ?? Size.zero;
    syncSpoilerTicker();
  }

  /// 按「未揭示 + 非 reduce-motion」启停(reduce-motion 渲染静态遮罩,
  /// 不跑动画 → 也让 golden/pumpAndSettle 能 settle)。
  void syncSpoilerTicker() {
    final t = _gateTicker;
    if (t == null) return;
    final shouldRun = !spoilerRevealed && !spoilerReduceMotion;
    if (shouldRun && !t.isActive) {
      _cancelWakeProbe();
      _lastTick = Duration.zero;
      t.start();
    } else if (!shouldRun && t.isActive) {
      t.stop();
      _cancelWakeProbe();
    }
  }

  /// 点击揭开:记录点击原点并启动涟漪动画(reduce-motion 下直接揭示,
  /// 无动画)。[localPosition] / [size] 为点击坐标与遮罩区域尺寸 ——
  /// 动画时长按 Telegram 公式由对角线推出,坐标作圆形裁剪圆心。
  void revealSpoiler(Offset localPosition, Size size) {
    if (spoilerRevealed || spoilerRevealing) return;
    if (spoilerReduceMotion) {
      setState(() => spoilerRevealed = true);
      syncSpoilerTicker();
      return;
    }
    final diag =
        math.sqrt(size.width * size.width + size.height * size.height);
    _revealDurationMs = (diag * 0.3).clamp(250.0, 550.0);
    spoilerRevealOrigin = localPosition;
    spoilerRevealProgress.value = 0;
    _revealClockStart = null;
    setState(() => spoilerRevealing = true);
    syncSpoilerTicker();
  }

  void _onSpoilerTick(Duration elapsed) {
    if (!mounted || spoilerRevealed) return;
    // 揭开动画进行中:跳过节流(短动画要满帧率)与离屏门控,推进涟漪
    // 进度;粒子场继续走全局时钟(淡出中仍在漂移)。到点一次性置揭示态,
    // syncSpoilerTicker 随即停表。
    if (spoilerRevealing) {
      _revealClockStart ??= elapsed;
      final p = (elapsed - _revealClockStart!).inMicroseconds /
          (_revealDurationMs * 1000);
      if (p >= 1) {
        spoilerRevealProgress.value = 1;
        setState(() {
          spoilerRevealing = false;
          spoilerRevealed = true;
        });
        syncSpoilerTicker();
        return;
      }
      spoilerRevealProgress.value = p;
      _lastTick = elapsed;
      spoilerTime.value = SpoilerShader.timeSeconds;
      return;
    }
    if (elapsed - _lastTick < _tickInterval) return; // ~30fps 节流
    if (!_isOnScreen()) {
      _gateTicker?.stop();
      _startWakeProbe();
      return;
    }
    _lastTick = elapsed;
    spoilerTime.value = SpoilerShader.timeSeconds;
  }

  /// 自身全局矩形是否与屏幕(含 64px 余量)相交。拿不到屏幕尺寸时视为
  /// 可见 —— 保守不误停。
  bool _isOnScreen() {
    if (_screenSize == Size.zero) return true;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return false;
    final rect = ro.localToGlobal(Offset.zero) & ro.size;
    return rect.overlaps((Offset.zero & _screenSize).inflate(64));
  }

  void _startWakeProbe() {
    _wakeProbe ??= Timer.periodic(_wakeProbeInterval, (_) {
      if (!mounted || spoilerRevealed || spoilerReduceMotion) return;
      if (_isOnScreen()) {
        _cancelWakeProbe();
        _lastTick = Duration.zero;
        final t = _gateTicker;
        if (t != null && !t.isActive) t.start();
      }
    });
  }

  void _cancelWakeProbe() {
    _wakeProbe?.cancel();
    _wakeProbe = null;
  }

  /// dispose 里调用(宿主自持的 shader 仍由宿主释放)。
  void disposeSpoilerTicker() {
    _cancelWakeProbe();
    _gateTicker?.dispose();
    _gateTicker = null;
    spoilerTime.dispose();
    spoilerRevealProgress.dispose();
  }
}

/// spoiler shader 全局加载器(进程内只 fromAsset 一次,所有实例共享)。
class SpoilerShader {
  SpoilerShader._();

  static ui.FragmentProgram? _program;
  static Future<void>? _loading;
  static final Stopwatch _clock = Stopwatch()..start();

  /// 全局连续时间基(秒)—— 所有 spoiler 共用,widget 重建 / Ticker
  /// 重启不回卷,粒子场永远处于"进行中"而不是从头重播(Telegram 同款
  /// 全局时钟做法)。每 4096s 回卷一次,保住 shader 内 float32 精度。
  static double get timeSeconds =>
      (_clock.elapsedMicroseconds % 4096000000) / 1e6;

  /// 已加载的 program(未加载完成/失败时为 null → painter 只画静态背景)。
  static ui.FragmentProgram? get program => _program;

  /// 确保 shader 已加载(幂等;失败静默,遮罩退化为静态背景)。
  ///
  /// asset key 双回退:被主项目依赖时是 `packages/fluxdo_render/...`,
  /// 包自身作为 root(单测 / example 直跑)时不带前缀。
  static Future<void> ensureLoaded() {
    if (_program != null) return Future.value();
    return _loading ??= _load();
  }

  static Future<void> _load() async {
    for (final key in const [
      'packages/fluxdo_render/shaders/spoiler.frag',
      'shaders/spoiler.frag',
    ]) {
      try {
        _program = await ui.FragmentProgram.fromAsset(key);
        _warmUp();
        return;
      } catch (_) {
        // 换下一个 key。
      }
    }
    debugPrint('[SpoilerShader] 加载失败,退化为静态遮罩');
    _loading = null;
  }

  /// 离屏画 1×1 预热 GPU pipeline —— runtime effect 的 PSO 是首次真正
  /// 绘制时才在 raster 线程编译的,不预热则每次 app 启动后第一个 spoiler
  /// 上屏瞬间会卡一下。
  static void _warmUp() {
    try {
      final shader = _program!.fragmentShader();
      for (var i = 0; i < 10; i++) {
        shader.setFloat(i, i < 2 ? 0.0 : 1.0); // time/seed=0,颜色=白
      }
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..shader = shader,
      );
      final picture = recorder.endRecording();
      final image = picture.toImageSync(1, 1); // 触发 raster 线程真实执行
      image.dispose();
      picture.dispose();
      shader.dispose();
    } catch (e) {
      debugPrint('[SpoilerShader] 预热失败(不影响功能): $e');
    }
  }
}

/// 遮罩绘制器:不透明背景填满 + shader 粒子尘埃层。
///
/// [time] 同时作为 repaint Listenable —— Ticker 只更新 time.value,
/// 不 setState 重建 widget 子树。
///
/// [shader] 由 widget State 持有并 dispose(painter 每次 rebuild 会重建,
/// 不能拥有 shader 生命周期);为 null(未加载完成/失败)时只画静态背景。
class SpoilerEffectPainter extends CustomPainter {
  SpoilerEffectPainter({
    required this.time,
    required this.seed,
    required this.shader,
    required this.isDark,
    required this.backgroundColor,
    this.borderRadius = 4.0,
  }) : super(repaint: time);

  final ValueListenable<double> time;
  final double seed;
  final ui.FragmentShader? shader;
  final bool isDark;
  final Color backgroundColor;
  final double borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RSuperellipse.fromRectAndRadius(rect, Radius.circular(borderRadius));

    canvas.save();
    canvas.clipRSuperellipse(rrect);
    final s = shader;
    if (s != null && size.width > 0 && size.height > 0) {
      final baseColor = isDark ? Colors.white : Colors.grey.shade800;
      // shader 输出不透明色(背景已并入)→ 单次绘制、无半透明混合层;
      // setFloat 只改 uniform,零分配。
      s
        ..setFloat(0, time.value) // u_time
        ..setFloat(1, seed) // u_seed
        ..setFloat(2, baseColor.r) // u_color
        ..setFloat(3, baseColor.g)
        ..setFloat(4, baseColor.b)
        ..setFloat(5, 1.0)
        ..setFloat(6, backgroundColor.r) // u_bg
        ..setFloat(7, backgroundColor.g)
        ..setFloat(8, backgroundColor.b)
        ..setFloat(9, 1.0);
      canvas.drawRect(rect, Paint()..shader = s);
    } else {
      // shader 未就绪/加载失败:纯色静态遮罩,内容照样被完全遮盖。
      canvas.drawRSuperellipse(rrect, Paint()..color = backgroundColor);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(SpoilerEffectPainter old) =>
      old.isDark != isDark ||
      old.backgroundColor != backgroundColor ||
      old.seed != seed ||
      old.shader != shader ||
      old.time != time;
}

/// 揭开涟漪圆形裁剪 —— 以点击处为圆心、「区域对角线 × progress」为半径
/// 的圆(对齐 Telegram `SpoilerEffect.getRipplePath`)。配合遮罩层淡出,
/// 形成"从点击处散开"的揭开动画。
class SpoilerRevealClipper extends CustomClipper<Path> {
  const SpoilerRevealClipper({required this.origin, required this.progress});

  final Offset origin;
  final double progress;

  @override
  Path getClip(Size size) {
    final maxRadius =
        math.sqrt(size.width * size.width + size.height * size.height);
    return Path()
      ..addOval(Rect.fromCircle(
          center: origin, radius: maxRadius * progress.clamp(0.0, 1.0)));
  }

  @override
  bool shouldReclip(SpoilerRevealClipper old) =>
      old.progress != progress || old.origin != origin;
}
