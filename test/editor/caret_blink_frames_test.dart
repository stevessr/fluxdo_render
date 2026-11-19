import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/widget/editor_caret.dart';
import 'package:fluxdo_render/src/render/frame_aligned_wakeup.dart';

/// 原来 `AnimationController.repeat()` 驱动的呼吸曲线(与 EditorCaret 一致)
final Animatable<double> _originalCurve = TweenSequence<double>([
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

void main() {
  for (final hz in [60.0, 120.0]) {
    testWidgets('光标呼吸 ${hz.round()}Hz:每帧不透明度与原循环一致,常值段不请求帧', (
      tester,
    ) async {
      tester.view.display.refreshRate = hz;
      addTearDown(tester.view.display.resetRefreshRate);
      final frame = Duration(microseconds: (1e6 / hz).round());
      // 帧时间戳只在帧内可读,用常驻帧回调记下每帧的时间戳
      var frameTime = Duration.zero;
      tester.binding.addPersistentFrameCallback((ts) => frameTime = ts);
      await tester.pumpWidget(
        const MaterialApp(
          home: Stack(
            children: [
              EditorCaret(
                caretRect: Rect.fromLTWH(10, 10, 0, 20),
                color: Color(0xFF000000),
              ),
            ],
          ),
        ),
      );
      // 下一帧是本圈起点
      await tester.pump();
      final origin = frameTime;
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(EditorCaret),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;

      final requestsBefore = FrameAlignedWakeup.debugFrameRequests;
      var scheduledFrames = 0;
      // 两圈,逐 vsync 推进
      final frames = (2200 * hz / 1000).round();
      for (var i = 0; i < frames; i++) {
        if (tester.binding.hasScheduledFrame) scheduledFrames++;
        await tester.pump(frame);
        final elapsed = frameTime - origin;
        final phase = (elapsed.inMicroseconds % 1100000) / 1100000;
        expect(
          opacity(),
          moreOrLessEquals(_originalCurve.transform(phase), epsilon: 1e-6),
          reason: '第 $i 帧(相位 ${phase.toStringAsFixed(3)})',
        );
      }
      // 渐变段占 32%,其余时间只在唤醒时各请求一帧
      final fadeFrames = (frames * 0.32).ceil();
      expect(scheduledFrames, lessThanOrEqualTo(fadeFrames + 8));
      expect(
        FrameAlignedWakeup.debugFrameRequests - requestsBefore,
        lessThanOrEqualTo(8),
        reason: '两圈只在每段渐变前各唤醒一次',
      );
    });
  }
}
