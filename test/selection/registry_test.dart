import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

import '../test_text_finders.dart';

void main() {
  Widget wrap(SelectionController controller, List<Widget> children) {
    return MaterialApp(
      home: Scaffold(
        body: SelectionScope(
          controller: controller,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }

  InlineSpanText para(String text, [int order = 0]) => InlineSpanText(
        inlines: [TextRun(text)],
        baseStyle: const TextStyle(fontSize: 14),
        documentOrder: order,
      );

  testWidgets('N 个段落 → registry 注册 N 个块', (tester) async {
    final controller = SelectionController(SelectionRegistry());
    await tester.pumpWidget(wrap(controller, [
      para('第一段', 0),
      para('第二段', 1),
      para('第三段', 2),
    ]));
    await tester.pumpAndSettle();
    expect(controller.registry.length, 3);
  });

  testWidgets('orderedBlocks 按文档序(docOrder)升序', (tester) async {
    final controller = SelectionController(SelectionRegistry());
    await tester.pumpWidget(wrap(controller, [
      para('上', 0),
      para('中', 1),
      para('下', 2),
    ]));
    await tester.pumpAndSettle();
    final order = controller.registry.orderedBlocks();
    expect(order.length, 3);
    // docOrder 递增(= 文档/视觉序,纯逻辑、不依赖几何)
    for (var i = 1; i < order.length; i++) {
      expect(order[i].id.docOrder > order[i - 1].id.docOrder, isTrue,
          reason: 'orderedBlocks 应按 docOrder 升序');
    }
  });

  testWidgets('dispose 段落 → live 句柄注销(逻辑块表保留)', (tester) async {
    final controller = SelectionController(SelectionRegistry());
    await tester.pumpWidget(wrap(controller, [para('A', 0), para('B', 1)]));
    await tester.pumpAndSettle();
    expect(controller.registry.liveLength, 2);

    // 移除一个段落 → live 句柄减少(逻辑块表常驻,length 不变)
    await tester.pumpWidget(wrap(controller, [para('A', 0)]));
    await tester.pumpAndSettle();
    expect(controller.registry.liveLength, 1);
  });

  testWidgets('handle.projection 反映段落内容', (tester) async {
    final controller = SelectionController(SelectionRegistry());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: controller,
            child: InlineSpanText(
              inlines: const [
                TextRun('心情'),
                EmojiRun(name: 'heart', url: 'x'),
              ],
              baseStyle: const TextStyle(fontSize: 14),
              emojiImageBuilder: (ctx, emoji, size) =>
                  SizedBox(width: size, height: size),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final h = controller.registry.liveHandles.first;
    expect(h.projection.projectAll(), '心情:heart:');
    // 文本几何实时可取(emoji 段落走直绘岛,geometry 是直绘 RenderObject
    // 而非 RenderParagraph —— 选区几何统一经 BlockTextGeometry 抽象)。
    final g = h.geometry;
    expect(g, isNotNull);
    // renderLength = 文字 2 字 + emoji 占 1 ￼
    expect(h.projection.renderLength, 3);
    // 几何原语可用:emoji 占位落在词边界上整颗选中
    final wb = g!.getWordBoundary(const TextPosition(offset: 2));
    expect(wb.end - wb.start, greaterThanOrEqualTo(1));
  });

  testWidgets('无 SelectionScope 时不崩(退化不可选)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: para('无选区上下文')),
      ),
    );
    await tester.pumpAndSettle();
    expect(findRenderedText('无选区上下文'), findsOneWidget);
  });
}
