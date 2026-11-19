/// 验证 DefinitionListNode 渲染:dt 文本可见(常规字重)+ dd 左缩进 1.25em。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

import '../test_text_finders.dart';

void main() {
  Future<void> pump(WidgetTester tester, DefinitionListNode node) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => NodeFactory().buildDefinitionList(ctx, node),
          ),
        ),
      ),
    );
  }

  testWidgets('dt + dd 文本均渲染', (tester) async {
    await pump(
      tester,
      const DefinitionListNode(
        id: 'dl',
        items: [
          DefinitionItem(
            term: [TextRun('术语')],
            definitions: [
              [
                ParagraphNode(id: 'p1', inlines: [TextRun('释义内容')]),
              ],
            ],
          ),
        ],
      ),
    );
    expect(findRenderedText('术语'), findsOneWidget);
    expect(findRenderedText('释义内容'), findsOneWidget);
  });

  testWidgets('dd 左缩进 1.25em(存在 left == em*1.25 的 Padding)',
      (tester) async {
    await pump(
      tester,
      const DefinitionListNode(
        id: 'dl',
        items: [
          DefinitionItem(
            term: [TextRun('T')],
            definitions: [
              [
                ParagraphNode(id: 'p1', inlines: [TextRun('D')]),
              ],
            ],
          ),
        ],
      ),
    );
    // 至少有一个 Padding 的 left == em*1.25(dd 缩进,对齐 Discourse
    // `dd { margin-left: 1.25em }`)。em = bodyMedium fontSize。
    final ctx = tester.element(findRenderedText('D'));
    final em = Theme.of(ctx).textTheme.bodyMedium?.fontSize ?? 14;
    final expected = em * 1.25;
    final paddings = tester.widgetList<Padding>(find.byType(Padding));
    final hasIndent = paddings.any((p) {
      final pad = p.padding;
      return pad is EdgeInsets && pad.left == expected;
    });
    expect(hasIndent, isTrue, reason: 'dd 应有 left:1.25em 缩进对齐 Discourse');
  });
}
