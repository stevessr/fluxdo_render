/// 验证块级列表项(li 含 h4/p 等块级子,如 FAQ 的 Q/A)的 marker 对齐:
/// bullet 必须落在内容首行,而非浮在首块(heading)上 margin 之上。
///
/// 背景:首块若是 heading,它带 `em * headingMargin` 的上 padding(legacy
/// compact 也保留),marker 放在 Row 顶部会浮高。修法是给 marker 加等量上
/// padding。这条 test 直接断言 bullet 顶部 Y ≈ 首块文字顶部 Y(防回归)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

import '../test_text_finders.dart';

void main() {
  testWidgets('块级 li:bullet 与首块(h4)文字顶部对齐', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => NodeFactory().buildList(
              ctx,
              const ListNode(
                id: 'l',
                ordered: false,
                depth: 0,
                items: [
                  ListItem(
                    inlines: [],
                    blocks: [
                      HeadingNode(id: 'h', level: 4, inlines: [TextRun('Q')]),
                      ParagraphNode(id: 'p', inlines: [TextRun('A')]),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // bullet(现为绘制 disc)与 'Q' 文字的垂直中心应接近(都居中到首行)→
    // 证明 bullet 落在 heading 首行上,而非浮在 margin 之上。
    final discCenter =
        tester.getCenter(find.byKey(const ValueKey('ul_marker_disc'))).dy;
    final qCenter = tester.getCenter(findRenderedText('Q')).dy;
    expect((discCenter - qCenter).abs(), lessThan(8.0),
        reason: 'bullet 浮高了:discCenter=$discCenter qCenter=$qCenter');
  });
}
