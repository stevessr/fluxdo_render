import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/hit_tester.dart';
import 'package:fluxdo_render/src/selection/selection_data.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';
import 'package:fluxdo_render/src/selection/selection_gesture_layer.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

import '../test_text_finders.dart';

void main() {
  Widget host(SelectionController c, List<InlineNode> inlines) {
    return MaterialApp(
      home: Scaffold(
        body: SelectionScope(
          controller: c,
          child: SelectionGestureLayer(
            controller: c,
            onSelectionChanged: (_, {bool fromTouch = false}) {},
            child: InlineSpanText(
              inlines: inlines,
              baseStyle: const TextStyle(fontSize: 20),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renderLengthOf 返回块渲染长度', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [TextRun('Hello world')]));
    await tester.pumpAndSettle();
    final id = c.registry.liveHandles.first.id;
    expect(SelectionHitTester(c.registry).renderLengthOf(id), 11);
    // 不存在的块返回 null
    expect(SelectionHitTester(c.registry).renderLengthOf(const SelectableBlockId(999)),
        isNull);
  });

  testWidgets('鼠标单击拖拽:起点折叠 → 拖拽扩展 → 选中', (tester) async {
    final c = SelectionController(SelectionRegistry());
    SelectionData? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: c,
            child: SelectionGestureLayer(
              controller: c,
              onSelectionChanged: (d, {bool fromTouch = false}) => result = d,
              child: InlineSpanText(
                inlines: const [TextRun('Hello world selection test')],
                baseStyle: const TextStyle(fontSize: 20),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final para = textGeometryAt(tester).renderBox;
    final topLeft = para.localToGlobal(Offset.zero);
    final start = topLeft + const Offset(5, 8);
    final end = topLeft + Offset(para.size.width - 5, 8);

    // 鼠标按下拖拽(PointerDeviceKind.mouse)
    final g = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await g.moveTo(end);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(c.registry.length, greaterThan(0));
    // 拖拽后应有非折叠选区
    final sel = c.selection;
    expect(sel, isNotNull);
    expect(sel!.isCollapsed, isFalse, reason: '鼠标拖拽应产生非折叠选区');
    expect(result, isNotNull, reason: '松手应导出 SelectionData');
  });

  testWidgets('鼠标双击选词', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [TextRun('Hello world')]));
    await tester.pumpAndSettle();
    final para = textGeometryAt(tester).renderBox;
    final p = para.localToGlobal(Offset.zero) + const Offset(10, 8);

    // 双击(consecutiveTapCount=2 → 选词)
    final g1 = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
    await g1.up();
    await tester.pump(const Duration(milliseconds: 50));
    final g2 = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
    await g2.up();
    await tester.pumpAndSettle();

    final sel = c.selection;
    expect(sel, isNotNull);
    // 选中了一个词(非折叠)
    expect(sel!.isCollapsed, isFalse, reason: '双击应选词');
  });

  testWidgets('双击拖拽按词扩选，不误选整段', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [
      TextRun('AAAAA BBBBB CCCCC DDDDD EEEEE FFFFF GGGGG'),
    ]));
    await tester.pumpAndSettle();
    final para = textGeometryAt(tester).renderBox;
    final o = para.localToGlobal(Offset.zero);
    final mid = o + Offset(para.size.width * 0.4, 8);
    final right = o + Offset(para.size.width * 0.7, 8);

    // 第二击按下后拖动，应从命中的词开始扩展，而不是误选整段。
    final g1 = await tester.startGesture(mid, kind: PointerDeviceKind.mouse);
    await g1.up();
    await tester.pump(const Duration(milliseconds: 40));
    final g2 = await tester.startGesture(mid, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 20));
    await g2.moveTo(right);
    await tester.pump();
    await g2.up();
    await tester.pumpAndSettle();

    final sel = c.selection;
    expect(sel, isNotNull);
    // base 不应是段首 0(那意味着整段);应从拖拽起点附近开始。
    final lo = sel!.base.renderOffset < sel.extent.renderOffset
        ? sel.base.renderOffset
        : sel.extent.renderOffset;
    expect(lo, greaterThan(0),
        reason: '以命中的词为起点，不能误选整段');
  });
}
