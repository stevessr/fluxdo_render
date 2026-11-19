import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/render/spoiler_effect.dart';

void main() {
  testWidgets('shader 粒子层实际输出非透明像素', (tester) async {
    await tester.runAsync(() async {
      await SpoilerShader.ensureLoaded();
      expect(SpoilerShader.program, isNotNull, reason: 'shader 应加载成功');
      final shader = SpoilerShader.program!.fragmentShader();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      SpoilerEffectPainter(
        time: ValueNotifier(1.234),
        seed: 42.0,
        shader: shader,
        isDark: true,
        backgroundColor: const Color(0xFF101010),
      ).paint(canvas, const Size(200, 60));
      final image = await recorder.endRecording().toImage(200, 60);
      final data = await image.toByteData();
      // 统计与背景色(0xFF101010)不同的像素数。
      var diff = 0;
      for (var i = 0; i < data!.lengthInBytes; i += 4) {
        final r = data.getUint8(i), g = data.getUint8(i + 1), b = data.getUint8(i + 2);
        if ((r - 0x10).abs() > 8 || (g - 0x10).abs() > 8 || (b - 0x10).abs() > 8) diff++;
      }
      debugPrint('非背景像素: $diff / ${200 * 60}');
      expect(diff, greaterThan(50), reason: '粒子层应画出可见像素');
    });
  });
}
