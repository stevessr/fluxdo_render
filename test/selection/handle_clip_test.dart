import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/selection/projection.dart';
import 'package:fluxdo_render/src/selection/selectable_block_handle.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';

void main() {
  testWidgets('注入 clipBoundsGetter:globalRect 裁剪到可视区(不溢出)',
      (tester) async {
    final v = ScrollController();
    final boxKey = GlobalKey();
    final longText =
        List.generate(40, (i) => 'line $i content here').join('\n');
    late RenderParagraph para;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              key: boxKey,
              width: 200,
              height: 150, // 比内容小 → 滚动
              child: SingleChildScrollView(
                controller: v,
                child: Text(longText,
                    style: const TextStyle(fontSize: 14),
                    textDirection: TextDirection.ltr),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    para = tester.allRenderObjects.whereType<RenderParagraph>().first;

    // clipBoundsGetter = 限高 SizedBox 的全局框(模拟代码块 clipBoundsKey)。
    Rect? clip() {
      final ro = boxKey.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
      return ro.localToGlobal(Offset.zero) & ro.size;
    }

    final handle = CallbackBlockHandle(
      id: const SelectableBlockId(0),
      paragraphGetter: () => para,
      projectionGetter: () => RenderTextProjection.empty,
      clipBoundsGetter: clip,
    );

    // RenderParagraph 完整高度远超 viewport(150)。
    expect(para.size.height, greaterThan(150));

    final rect = handle.globalRect();
    expect(rect, isNotNull);
    expect(rect!.height, lessThanOrEqualTo(150 + 1),
        reason: 'globalRect 应裁剪到 clipBounds 可视区,不溢出');

    // 滚动后仍裁剪在可视区内。
    v.jumpTo(300);
    await tester.pumpAndSettle();
    final rect2 = handle.globalRect();
    expect(rect2, isNotNull);
    expect(rect2!.height, lessThanOrEqualTo(150 + 1));
  });

  testWidgets('无 clipBoundsGetter:globalRect 不裁剪(普通段落)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: Text('单行普通段落',
                  style: const TextStyle(fontSize: 16),
                  textDirection: TextDirection.ltr),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final para = tester.allRenderObjects.whereType<RenderParagraph>().first;
    final handle = CallbackBlockHandle(
      id: const SelectableBlockId(0),
      paragraphGetter: () => para,
      projectionGetter: () => RenderTextProjection.empty,
    );
    final rect = handle.globalRect();
    expect(rect, isNotNull);
    // 无裁剪 → 等于 paragraph 自身全局框。
    expect(rect!.height, closeTo(para.size.height, 0.5));
  });
}
