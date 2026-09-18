import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';
import 'package:fluxdo_render/src/widget/selection_content_layer.dart';
import '../test_text_finders.dart';

void main() {
  testWidgets('Android 长按先显示手柄再显示官方菜单，展开后菜单接收点击', (tester) async {
    tester.view.physicalSize = const Size(280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = SelectionController(SelectionRegistry());
    var quotes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: controller,
            child: SelectionContentLayer(
              controller: controller,
              onQuoteRequest: (_) => quotes++,
              onCopyQuoteRequest: (_) {},
              onCopyToast: null,
              child: const Padding(
                padding: EdgeInsets.only(top: 30),
                child: InlineSpanText(
                  inlines: [TextRun('alpha beta gamma delta')],
                  baseStyle: TextStyle(fontSize: 20),
                  documentOrder: 0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    try {
      await tester.longPressAt(
        tester.getTopLeft(findRenderedText('alpha beta gamma delta')) +
            const Offset(12, 12),
      );
      await tester.pumpAndSettle();
      expect(controller.selection, isNotNull);
      final toolbar = find.byType(TextSelectionToolbar);
      expect(toolbar, findsOneWidget);
      final overlay = tester.state<OverlayState>(find.byType(Overlay).first);
      // 通过真实渲染顺序检查：同一 Overlay 中菜单必须最后绘制。
      final render = overlay.context.findRenderObject()!;
      final ordered = <RenderObject>[];
      void walk(RenderObject node) {
        ordered.add(node);
        node.visitChildren(walk);
      }

      walk(render);
      final menuRender = tester.renderObject(toolbar);
      final handles = find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector &&
            widget.onPanStart != null &&
            widget.onPanUpdate != null,
      );
      expect(handles, findsAtLeastNWidgets(2));
      for (final handle in handles.evaluate()) {
        final handleRender = handle.findRenderObject();
        if (handleRender != null && ordered.contains(handleRender)) {
          expect(
            ordered.indexOf(menuRender),
            greaterThan(ordered.indexOf(handleRender)),
          );
        }
      }
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('引用'));
      await tester.pump();
      expect(quotes, 1);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(Duration.zero);
      controller.dispose();
    }
  });
}
