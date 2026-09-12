/// 三指文本编辑手势识别。
///
/// 手势定义取自 Apple 官方文档(见 three_finger_gestures.dart 头注释):
/// 三指左滑=撤销、右滑=重做、捏合=复制、捏合两次=剪切、张开=粘贴。
///
/// 用真实 widget + 三个 TestGesture 驱动,而不是直接喂 recognizer ——
/// 这样连同手势竞技场的裁决一起验证(编辑器里它要和单指 tap/longPress
/// 共存)。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

Future<void> _pumpHarness(
  WidgetTester tester,
  List<ThreeFingerGesture> got,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            // 与编辑器同构:单指 tap 也在场,验证不互相抢
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  TapGestureRecognizer.new,
                  (r) => r.onTap = () {},
                ),
            ThreeFingerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  ThreeFingerGestureRecognizer
                >(
                  () => ThreeFingerGestureRecognizer(onGesture: got.add),
                  (r) => r.onGesture = got.add,
                ),
          },
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
}

/// 三指同时按下 → 位移/缩放 → 抬起。
///
/// [move] 对三指施加相同位移(纯平移,scale 不变);
/// [scale] 让三指相对中心收拢(<1)或张开(>1)。
Future<void> _threeFinger(
  WidgetTester tester, {
  Offset move = Offset.zero,
  double scale = 1.0,
}) async {
  const center = Offset(400, 300);
  final starts = <Offset>[
    center + const Offset(-60, 0),
    center,
    center + const Offset(60, 0),
  ];

  // 每根手指落地后各 pump 一帧:真机上三指不可能同帧落地,识别器
  // 需要在三指齐备后才能取到跨度基准。
  final gestures = <TestGesture>[];
  for (final s in starts) {
    gestures.add(await tester.startGesture(s, kind: PointerDeviceKind.touch));
    await tester.pump();
  }

  // 分几步移动,贴近真实手势流(单步跳变也能识别,但多步更接近真机)
  const steps = 4;
  for (var step = 1; step <= steps; step++) {
    final t = step / steps;
    for (var i = 0; i < 3; i++) {
      final curScale = 1.0 + (scale - 1.0) * t;
      final scaled = center + (starts[i] - center) * curScale;
      final target = scaled + move * t;
      await gestures[i].moveTo(target);
    }
    await tester.pump();
  }

  for (final g in gestures) {
    await g.up();
  }
  await tester.pump();
}

void main() {
  testWidgets('单指拖动不被吞，滚动后仍能识别三指手势', (tester) async {
    final scroll = ScrollController();
    final got = <ThreeFingerGesture>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              SizedBox(
                height: 2000,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.opaque,
                  gestures: {
                    ThreeFingerGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          ThreeFingerGestureRecognizer
                        >(
                          () =>
                              ThreeFingerGestureRecognizer(onGesture: got.add),
                          (r) => r.onGesture = got.add,
                        ),
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      final before = scroll.offset;
      final gesture = await tester.startGesture(const Offset(400, 300));
      await gesture.moveBy(const Offset(0, -100));
      await gesture.moveBy(const Offset(0, -100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(before));
      expect(got, isEmpty);
    }
    await _threeFinger(tester, move: const Offset(-140, 0));
    expect(got, [ThreeFingerGesture.undo]);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });

  testWidgets('三指左滑 = 撤销', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    await _threeFinger(tester, move: const Offset(-140, 0));
    expect(got, [ThreeFingerGesture.undo]);
  });

  testWidgets('三指右滑 = 重做', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    await _threeFinger(tester, move: const Offset(140, 0));
    expect(got, [ThreeFingerGesture.redo]);
  });

  testWidgets('三指捏合 = 复制', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    await _threeFinger(tester, scale: 0.4);
    expect(got, [ThreeFingerGesture.copy]);
  });

  testWidgets('三指张开 = 粘贴', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    await _threeFinger(tester, scale: 2.2);
    expect(got, [ThreeFingerGesture.paste]);
  });

  testWidgets('窗口内连续两次捏合:第二次是剪切', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    await _threeFinger(tester, scale: 0.4);
    await _threeFinger(tester, scale: 0.4);
    expect(got, [ThreeFingerGesture.copy, ThreeFingerGesture.cut]);
  });

  testWidgets('竖向滑动不误判(留给页面滚动)', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    await _threeFinger(tester, move: const Offset(0, -160));
    expect(got, isEmpty);
  });

  testWidgets('微小位移不触发(手抖容差)', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    await _threeFinger(tester, move: const Offset(-20, 0));
    expect(got, isEmpty);
  });

  testWidgets('一次手势只派发一个结果', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    // 又张开又左滑:先达阈值者胜出,但只能有一个
    await _threeFinger(tester, move: const Offset(-160, 0), scale: 2.2);
    expect(got.length, 1);
  });

  testWidgets('单指操作不触发三指手势', (tester) async {
    final got = <ThreeFingerGesture>[];
    await _pumpHarness(tester, got);
    final g = await tester.startGesture(
      const Offset(400, 300),
      kind: PointerDeviceKind.touch,
    );
    await g.moveBy(const Offset(-200, 0));
    await g.up();
    await tester.pump();
    expect(got, isEmpty);
  });
}
