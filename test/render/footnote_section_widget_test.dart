import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';
import 'package:fluxdo_render/src/widget/fluxdo_render.dart';

import '../test_text_finders.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  const body =
      '<p>正文<sup class="footnote-ref"><a href="#fn:1">1</a></sup>'
      '和另一处<sup class="footnote-ref"><a href="#fn:1">1</a></sup>。</p>';
  const footnotes =
      '<hr class="footnotes-sep"><ol class="footnotes-list">'
      '<li id="fn:1"><p>脚注正文 <a class="footnote-backref" href="#ref">↩︎</a></p>'
      '</li></ol>';

  for (final wrapped in [false, true]) {
    testWidgets('行内脚注隐藏文末列表，同一脚注可重复点击（section=$wrapped）', (tester) async {
      final taps = <(String, String?)>[];
      await tester.pumpWidget(
        _wrap(
          FluxdoRender(
            cookedHtml:
                body +
                (wrapped
                    ? '<section class="footnotes">$footnotes</section>'
                    : footnotes),
            footnoteTapHandler: (_, id, html) => taps.add((id, html)),
          ),
        ),
      );
      expect(findRenderedTextContaining('脚注正文'), findsNothing);
      expect(findRenderedText('1.'), findsNothing);
      final refs = findRenderedText('[1]');
      expect(refs, findsNWidgets(2));
      await tester.tap(refs.first);
      await tester.tap(refs.last);
      expect(taps, [('fn:1', '脚注正文'), ('fn:1', '脚注正文')]);
    });
  }

  testWidgets('隐藏的脚注区不占高度', (tester) async {
    const key = ValueKey('footnote-section');
    final factory = NodeFactory(footnoteTapHandler: (_, _, _) {});
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => SizedBox(
            key: key,
            child: factory.build(
              context,
              const FootnotesSectionNode(
                id: 'fn',
                entries: [
                  FootnoteEntry(
                    id: 'fn:1',
                    number: '1',
                    inlines: [TextRun('脚注正文')],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(key)).height, 0);
  });

  testWidgets('截图模式保留完整文末脚注，退出截图后恢复隐藏', (tester) async {
    for (final screenshot in [true, false]) {
      await tester.pumpWidget(
        _wrap(
          FluxdoRender(
            cookedHtml: body + footnotes,
            screenshotMode: screenshot,
            footnoteTapHandler: (_, _, _) {},
          ),
        ),
      );
      expect(
        findRenderedText('1.'),
        screenshot ? findsOneWidget : findsNothing,
      );
      expect(
        findRenderedTextContaining('脚注正文'),
        screenshot ? findsOneWidget : findsNothing,
      );
    }
  });

  testWidgets('引用块内的脚注也按行内模式隐藏', (tester) async {
    await tester.pumpWidget(
      _wrap(
        FluxdoRender(
          cookedHtml: '<blockquote>$body$footnotes</blockquote>',
          footnoteTapHandler: (_, _, _) {},
        ),
      ),
    );
    expect(findRenderedText('[1]'), findsNWidgets(2));
    expect(findRenderedTextContaining('脚注正文'), findsNothing);
  });

  testWidgets('buildFootnotesSection 渲染编号 + 正文 + 分隔线', (tester) async {
    final node = FootnotesSectionNode(
      id: 'b_0',
      entries: const [
        FootnoteEntry(id: 'fn:1', number: '1', inlines: [TextRun('脚注甲')]),
        FootnoteEntry(id: 'fn:2', number: '2', inlines: [TextRun('脚注乙')]),
      ],
    );
    final factory = NodeFactory();
    await tester.pumpWidget(
      _wrap(Builder(builder: (ctx) => factory.build(ctx, node))),
    );
    expect(findRenderedText('1.'), findsOneWidget);
    expect(findRenderedText('2.'), findsOneWidget);
    expect(findRenderedTextContaining('脚注甲'), findsOneWidget);
    expect(findRenderedTextContaining('脚注乙'), findsOneWidget);
  });

  testWidgets('entries 为空 → 渲染 SizedBox.shrink(不占高)', (tester) async {
    const node = FootnotesSectionNode(id: 'b_0');
    final factory = NodeFactory();
    await tester.pumpWidget(
      _wrap(Builder(builder: (ctx) => factory.build(ctx, node))),
    );
    expect(findRenderedText('1.'), findsNothing);
    // 无文本、无分隔线内容
    expect(find.byType(InkWell), findsNothing);
  });
}
