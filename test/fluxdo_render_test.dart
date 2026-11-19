import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import 'test_text_finders.dart';

void main() {
  Future<void> pump(WidgetTester tester, String html) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FluxdoRender(cookedHtml: html),
        ),
      ),
    );
  }

  group('FluxdoRender 集成', () {
    testWidgets('简单段落渲染', (tester) async {
      await pump(tester, '<p>hello</p>');
      expect(findRenderedText('hello'), findsOneWidget);
    });

    testWidgets('含 em / strong 的段落合并为单块文本', (tester) async {
      await pump(tester, '<p>a <em>b</em> <strong>c</strong></p>');
      // 整段合并渲染(直绘块或 Text.rich),visible 文本是拼接结果
      expect(findRenderedText('a b c'), findsOneWidget);
    });

    testWidgets('多个段落渲染多个文本块', (tester) async {
      await pump(tester, '<p>p1</p><p>p2</p>');
      expect(findRenderedText('p1'), findsOneWidget);
      expect(findRenderedText('p2'), findsOneWidget);
    });

    testWidgets('空 HTML 渲染 SizedBox.shrink', (tester) async {
      await pump(tester, '');
      // 没有 Text widget 出现
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('cookedHtml 变化时重 parse', (tester) async {
      await pump(tester, '<p>before</p>');
      expect(findRenderedText('before'), findsOneWidget);

      await pump(tester, '<p>after</p>');
      expect(findRenderedText('after'), findsOneWidget);
      expect(findRenderedText('before'), findsNothing);
    });

    testWidgets('传 parsedNodes 时复用已解析节点', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FluxdoRender(
              cookedHtml: '<p>ignored</p>',
              parsedNodes: [
                ParagraphNode(id: 'b_0', inlines: [TextRun('parsed')]),
              ],
            ),
          ),
        ),
      );
      expect(findRenderedText('parsed'), findsOneWidget);
      expect(findRenderedText('ignored'), findsNothing);
    });
  });
}
