/// iOS/iPadOS 三指文本编辑手势识别。
///
/// **为什么要自己实现**:源码模式用原生 TextField,系统手势白拿;富文本
/// 是自绘编辑器,系统不认它是文本输入区,所有手势都不会到达 —— 撤销、
/// 复制、粘贴在富文本下全部手势失效。
///
/// 手势定义取自 Apple 官方文档(已核实原文):
/// - Pages for iPad 用户指南:
///   "three-finger swipe to the **left** to undo"
///   "three-finger swipe to the **right** to redo"
/// - iPad 用户指南 "Select and edit text":
///   Copy  = "pinch closed with three fingers"
///   Cut   = "pinch closed with three fingers **two times**"
///   Paste = "pinch **open** with three fingers"
///
/// (注意不是两指 —— 两指在 iOS 上是滚动/缩放,Apple 文档中没有两指
/// 文本编辑手势。)
///
/// 与既有手势的关系:编辑器现有 tap/longPress 是单指、pan 已用
/// supportedDevices 限定给 mouse/trackpad,多指手势位是空的,不冲突。
library;

import 'package:flutter/gestures.dart';

/// 三指手势种类。
enum ThreeFingerGesture { undo, redo, copy, cut, paste }

/// 识别参数(集中成常量便于调参与测试)。
class ThreeFingerConfig {
  const ThreeFingerConfig._();

  /// 判定为「滑动」的最小横向位移(逻辑像素)。
  static const double swipeMinDx = 60;

  /// 滑动时允许的最大纵向偏移比例 —— 超过则认为用户在滚动而非左右滑。
  static const double swipeMaxSlope = 0.8;

  /// 捏合/张开需要的最小「三指跨度变化」(逻辑像素)。
  ///
  /// **不能用 ScaleUpdateDetails.scale 判捏合**。实测三指纯左滑时,
  /// scale 在 1.00↔1.39 之间逐帧来回跳 —— 因为手指不可能同一帧里
  /// 齐步移动,先动的手指拉大了瞬时跨度。且这个噪声在 dx 才 12px
  /// 时就出现,早于 swipe 阀值,任何基于焦点位移的后置守卫都拦不住。
  ///
  /// 改用手指实际跨度(最远两指距离)的**累计变化**:平移时它回归
  /// 原值,捏合时它单调收缩 —— 物理上就区分得开。
  static const double pinchMinSpanDelta = 50;

  /// 两次捏合算「剪切」的时间窗。
  static const Duration doublePinchWindow = Duration(milliseconds: 600);
}

/// 三指手势识别器。
///
/// 基于 [ScaleGestureRecognizer] —— 它是 Flutter 中唯一同时提供
/// pointerCount、scale 与 focalPoint 的识别器,三指的「捏合」和「平移」
/// 都能从同一个手势流里判出来。
///
/// 生命周期:每次手势结束时**只**派发一个结果(捏合与滑动互斥,先达成
/// 阈值的胜出),避免一次手势既撤销又粘贴。
class ThreeFingerGestureRecognizer extends ScaleGestureRecognizer {
  ThreeFingerGestureRecognizer({required this.onGesture, super.debugOwner})
    : super(
        // 只服务触摸屏:鼠标/触控板的多指事件语义完全不同(触控板三指
        // 是系统级切换应用),不能借用。
        supportedDevices: const {PointerDeviceKind.touch},
      ) {
    onStart = _handleStart;
    onUpdate = _handleUpdate;
    onEnd = _handleEnd;
  }

  /// 实时跟踪每根手指位置 —— scale 噪声太大,只能自己算跨度。
  final Map<int, Offset> _points = {};

  /// 一旦确认三指同时在场,立即宣布胜出。
  ///
  /// 否则同层的 TapGestureRecognizer 会先拿下竞技场并把本识别器 reject
  /// 掉(实测:有 Tap 共存时三指手势完全不触发)。三指同时按下对
  /// tap/longPress 来说本就不是合法输入,抢过来不会误伤单指交互。
  bool _claimed = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _points[event.pointer] = event.position;
    super.addAllowedPointer(event);
    _claimIfThreeFingers();
  }

  void _claimIfThreeFingers() {
    if (_claimed || _points.length < 3) return;
    _claimed = true;
    // 对所有已受理的指针宣布胜出
    for (final pointer in _points.keys) {
      resolvePointer(pointer, GestureDisposition.accepted);
    }
  }

  @override
  void rejectGesture(int pointer) {
    // 输给单指滚动/长按后，不会再收到该指针的 up，必须同步清理。
    _points.remove(pointer);
    if (_points.isEmpty) _claimed = false;
    super.rejectGesture(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _points[event.pointer] = event.position;
      // ScaleGestureRecognizer 默认也会认单指平移；三指未齐时让外层滚动处理。
      if (!_claimed && _points.length < 3) return;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _points.remove(event.pointer);
      if (_points.isEmpty) _claimed = false;
    }
    super.handleEvent(event);
  }

  /// 当前三指跨度 = 最远两指的距离。不足三指时返回 0。
  double get _span {
    if (_points.length < 3) return 0;
    final pts = _points.values.toList();
    var maxD = 0.0;
    for (var i = 0; i < pts.length; i++) {
      for (var j = i + 1; j < pts.length; j++) {
        final d = (pts[i] - pts[j]).distance;
        if (d > maxD) maxD = d;
      }
    }
    return maxD;
  }

  Offset get _focal =>
      _points.values.reduce((a, b) => a + b) / _points.length.toDouble();

  /// 命中回调。宿主据此调用对应的内容操作。
  ///
  /// 非 final:GestureRecognizerFactoryWithHandlers 的 initializer 会在
  /// 每次 build 时重新赋值(回调闭包捕获了新的 State)。
  void Function(ThreeFingerGesture gesture) onGesture;

  Offset _startFocal = Offset.zero;

  /// 三指齐备那一刻的跨度基准。
  double _startSpan = 0;
  bool _sawThreeFingers = false;

  /// 基准是否已在「三指均落地」后重新取过。
  bool _baselineReady = false;
  bool _fired = false;

  /// 上一次「捏合」的时间,用于识别 double pinch = 剪切。
  DateTime? _lastPinchInAt;

  void _handleStart(ScaleStartDetails d) {
    // 注意:onStart 会随落指多次触发(1 指、2 指、3 指各一次)。基准必须
    // 等三指全部落地后才能定 —— 用 1 指时的焦点做基准会把“第二、三指
    // 落地”造成的焦点跳变当成位移。
    _resetBaseline(d.focalPoint, d.pointerCount);
  }

  void _resetBaseline(Offset focal, int pointerCount) {
    _startFocal = _points.isEmpty ? focal : _focal;
    _startSpan = _span;
    _sawThreeFingers = pointerCount >= 3;
    _baselineReady = _sawThreeFingers && _startSpan > 0;
    _fired = false;
  }

  void _handleUpdate(ScaleUpdateDetails d) {
    if (_fired) return;
    if (d.pointerCount < 3) return;

    // 三指刚齐:以此刻焦点/跨度为基准重新起算(丢弃落指阶段的干扰)。
    if (!_baselineReady) {
      _resetBaseline(d.focalPoint, d.pointerCount);
      return;
    }

    final delta = _focal - _startFocal;
    final movedX = delta.dx.abs();

    // --- 左右滑 ---
    if (movedX >= ThreeFingerConfig.swipeMinDx &&
        delta.dy.abs() <= movedX * ThreeFingerConfig.swipeMaxSlope) {
      _fire(delta.dx < 0 ? ThreeFingerGesture.undo : ThreeFingerGesture.redo);
      return;
    }

    // --- 捏合/张开 ---
    // 看手指实际跨度的变化量,不看 scale(后者在平移时噪声极大)。
    final spanDelta = _span - _startSpan;
    if (spanDelta <= -ThreeFingerConfig.pinchMinSpanDelta) {
      _fire(_resolvePinchIn());
    } else if (spanDelta >= ThreeFingerConfig.pinchMinSpanDelta) {
      _fire(ThreeFingerGesture.paste);
    }
  }

  /// 捏合:窗口内第二次 = 剪切,否则复制。
  ///
  /// 官方定义「pinch closed two times」= 剪切。这里按「上一次捏合距今
  /// 是否在窗口内」判定,而不是等第二次 —— 等待会让单次复制延迟生效。
  /// 代价是剪切会先触发一次复制(内容已进剪贴板),第二次再删除选区,
  /// 与官方观感一致。
  ThreeFingerGesture _resolvePinchIn() {
    final now = DateTime.now();
    final last = _lastPinchInAt;
    _lastPinchInAt = now;
    if (last != null &&
        now.difference(last) <= ThreeFingerConfig.doublePinchWindow) {
      _lastPinchInAt = null; // 消费掉,避免三次捏合连锁判成剪切
      return ThreeFingerGesture.cut;
    }
    return ThreeFingerGesture.copy;
  }

  void _fire(ThreeFingerGesture g) {
    _fired = true;
    onGesture(g);
  }

  void _handleEnd(ScaleEndDetails d) {
    _sawThreeFingers = false;
    _baselineReady = false;
    _fired = false;
    if (_points.isEmpty) _claimed = false;
  }
}
