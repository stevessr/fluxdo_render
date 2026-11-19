import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/selection_gesture_layer.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

/// 守护:命中测试用框架真实 hit-test(从当前手势层 RenderObject 往下),命中
/// 到点下真实可见的块,不会因别的块几何陈旧而串块。框架 hit-test 天然排除
/// 离屏/被裁剪块 —— 修复「窗口尺寸变化后划词跳到完全另一段」。
void main() {
  testWidgets('点第二块返回第二块,不串到第一块', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: c,
            child: SelectionGestureLayer(
              controller: c,
              onSelectionChanged: (_, {bool fromTouch = false}) {},
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InlineSpanText(
                    inlines: [TextRun('Block one AAAA AAAA')],
                    baseStyle: TextStyle(fontSize: 20),
                    documentOrder: 0,
                  ),
                  InlineSpanText(
                    inlines: [TextRun('Block two BBBB BBBB')],
                    baseStyle: TextStyle(fontSize: 20),
                    documentOrder: 1,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 第二块的中左位置(避开第一块)。
    final boxes = find.byType(InlineSpanText);
    expect(boxes, findsNWidgets(2));
    final r2 = tester.getRect(boxes.at(1));
    final pt = Offset(r2.left + 8, r2.center.dy);

    // 双击第二块选词。
    final g1 = await tester.startGesture(pt, kind: PointerDeviceKind.mouse);
    await g1.up();
    await tester.pump(const Duration(milliseconds: 50));
    final g2 = await tester.startGesture(pt, kind: PointerDeviceKind.mouse);
    await g2.up();
    await tester.pumpAndSettle();

    final sel = c.selection;
    expect(sel, isNotNull);
    expect(sel!.isCollapsed, isFalse);
    expect(sel.base.blockId.docOrder, 1,
        reason: '点第二块应命中第二块(docOrder=1),不串到第一块');
  });
}
