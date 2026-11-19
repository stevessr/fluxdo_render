/// 按帧时间戳定时唤醒，等待期间不出帧。
///
/// 低频动画（剧透粒子约 30fps、光标呼吸的常亮 / 常灭段）如果用常驻 Ticker
/// 计时，Ticker 每个 vsync 都会请求下一帧：画面没变，引擎照样整帧合成、整屏
/// 光栅化，同屏的玻璃等也跟着每帧重算。这里用计时器等待，在目标时刻前将近
/// 一帧醒来、只请求一帧，回调在不早于目标的第一个 vsync 上执行：
///
/// - 不会提前：早到的帧在回调里复核，不到点就再等下一个 vsync；
/// - 不会拖后：提前量将近一帧，计时器只有在 UI 线程被占满将近一帧时才会
///   错过目标 vsync，这种情况下常驻 Ticker 也赶不上那一帧的呈现；
/// - 回调里拿到的是帧时间戳，接着用它算下一次目标，节拍不会累积漂移。
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';

class FrameAlignedWakeup {
  /// 在帧时间戳 [target] 或之后的第一个 vsync 调用 [onFrame]。[now] 是安排
  /// 时所在帧的时间戳（拿不到时传 null，直接请求下一帧）。
  FrameAlignedWakeup({
    required Duration target,
    required Duration? now,
    required this.onFrame,
  }) : _target = target {
    final wait = now == null ? Duration.zero : target - now - _lead;
    if (wait > Duration.zero) {
      _timer = Timer(wait, _request);
    } else {
      _request();
    }
  }

  final void Function(Duration timeStamp) onFrame;
  final Duration _target;
  Timer? _timer;
  int? _callbackId;
  bool _cancelled = false;

  /// 测试用：所有唤醒累计请求过的帧数
  static int debugFrameRequests = 0;

  /// 当前所在帧的时间戳；不在帧内（计时器、手势回调里）时为 null
  static Duration? get frameNow {
    final binding = SchedulerBinding.instance;
    final phase = binding.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      return null;
    }
    return binding.currentFrameTimeStamp;
  }

  /// 当前屏幕一帧的时长（拿不到刷新率时按 60Hz）
  static Duration get frameInterval {
    final rate = SchedulerBinding
        .instance
        .platformDispatcher
        .views
        .firstOrNull
        ?.display
        .refreshRate;
    final hz = rate == null || rate < 30 ? 60.0 : rate;
    return Duration(microseconds: (1e6 / hz).round());
  }

  /// 提前量比一帧略短：计时从回调真正执行时算起（比该帧 vsync 晚一两毫秒），
  /// 唤醒点落在目标 vsync 之前的那一帧里，前面不多出帧
  static Duration get _lead => frameInterval - const Duration(milliseconds: 2);

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    final id = _callbackId;
    if (id != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
      _callbackId = null;
    }
  }

  void _request() {
    _timer = null;
    if (_cancelled) return;
    debugFrameRequests++;
    _callbackId = SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
  }

  void _onFrame(Duration timeStamp) {
    _callbackId = null;
    if (_cancelled) return;
    // 目标 vsync 的时间戳可能比目标略早，按半帧容差认定到点
    if (timeStamp < _target - frameInterval ~/ 2) {
      _request();
      return;
    }
    onFrame(timeStamp);
  }
}
