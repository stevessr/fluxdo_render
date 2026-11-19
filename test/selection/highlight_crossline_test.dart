import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/selection/selection_highlight_painter.dart';

/// 真实多行文字:跨行选区经 tight getBoxesForSelection + merge 后,
/// 应得到「每行一个矩形、行数 = 跨越行数」,绝不是一个横跨整段的大矩形。
void main() {
  testWidgets('真实跨行选区不会合并成整段矩形', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 120,
              child: Text.rich(
                const TextSpan(
                    text: 'AAAAA BBBBB CCCCC DDDDD EEEEE FFFFF GGGGG',
                    style: TextStyle(fontSize: 16)),
                textDirection: TextDirection.ltr,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final p = tester.allRenderObjects.whereType<RenderParagraph>().first;
    final totalH = p.size.height; // 多行总高

    // 选第一行末到第二行中(跨 1 个换行)
    final boxes = p.getBoxesForSelection(
      const TextSelection(baseOffset: 3, extentOffset: 14),
    );
    final rects = mergeSelectionBoxesByLine(boxes);

    // 每个矩形高度都该 ≈ 单行(远小于整段),绝不出现跨整段的大块。
    for (final r in rects) {
      expect(r.height, lessThan(totalH * 0.6),
          reason: '单个高亮矩形不应跨越大半段落(整段 bug 的特征)');
    }
    // 跨了换行,应至少 2 个矩形(两行各一)
    expect(rects.length, greaterThanOrEqualTo(2),
        reason: '跨行选区应每行一个矩形');
  });

  testWidgets('单行选区只有一个矩形', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: Text.rich(
                const TextSpan(text: '一行短文字选择', style: TextStyle(fontSize: 16)),
                textDirection: TextDirection.ltr,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final p = tester.allRenderObjects.whereType<RenderParagraph>().first;
    final boxes = p.getBoxesForSelection(
      const TextSelection(baseOffset: 1, extentOffset: 4),
    );
    final rects = mergeSelectionBoxesByLine(boxes);
    expect(rects.length, 1);
  });
}
