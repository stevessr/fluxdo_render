import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/hit_tester.dart';
import 'package:fluxdo_render/src/selection/selection_data.dart';
import 'package:fluxdo_render/src/selection/selection_exporter.dart';
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
          child: InlineSpanText(
            inlines: inlines,
            baseStyle: const TextStyle(fontSize: 20),
            emojiImageBuilder: (ctx, emoji, size) =>
                SizedBox(width: size, height: size),
          ),
        ),
      ),
    );
  }

  testWidgets('命中:点段落中部返回该块内合法 renderOffset', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [TextRun('Hello world selection')]));
    await tester.pumpAndSettle();

    final para = textGeometryAt(tester).renderBox;
    final rect = para.localToGlobal(Offset.zero) & para.size;
    final hit = SelectionHitTester(c.registry);
    final pos = hit.positionAt(rect.center);
    expect(pos, isNotNull);
    expect(pos!.renderOffset, greaterThan(0));
    expect(pos.renderOffset, lessThanOrEqualTo('Hello world selection'.length));
  });

  testWidgets('命中兜底:点段落下方空白仍夹到块内', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [TextRun('abc')]));
    await tester.pumpAndSettle();
    final para = textGeometryAt(tester).renderBox;
    final rect = para.localToGlobal(Offset.zero) & para.size;
    final hit = SelectionHitTester(c.registry);
    // 点块下方 500px 空白
    final pos = hit.positionAt(Offset(rect.center.dx, rect.bottom + 500));
    expect(pos, isNotNull);
  });

  testWidgets('选词边界:落在单词中间选中整词', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [TextRun('Hello world')]));
    await tester.pumpAndSettle();
    final para = textGeometryAt(tester).renderBox;
    final hit = SelectionHitTester(c.registry);
    // 第一个块,renderOffset 1(在 "Hello" 内)
    final blockId = c.registry.liveHandles.first.id;
    final wb = hit.wordBoundaryAt(
        DocumentPosition(blockId: blockId, renderOffset: 1));
    expect(wb, isNotNull);
    expect(wb!.start, 0);
    expect(wb.end, 5); // "Hello"
    para.toString(); // keep ref
  });

  testWidgets('导出:单段落选区 plainText 正确', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [TextRun('Hello world')]));
    await tester.pumpAndSettle();
    final blockId = c.registry.liveHandles.first.id;
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: blockId, renderOffset: 0),
      extent: DocumentPosition(blockId: blockId, renderOffset: 5),
    );
    final data = SelectionExporter(c.registry).export(c.selection);
    expect(data, isNotNull);
    expect(data!.plainText, 'Hello');
    expect(data.globalRects, isNotEmpty);
    expect(data.globalBounds.width, greaterThan(0));
  });

  testWidgets('导出:含 emoji 选区投影 :name:', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [
      TextRun('Hi'),
      EmojiRun(name: 'heart', url: 'x'),
      TextRun('yo'),
    ]));
    await tester.pumpAndSettle();
    final blockId = c.registry.liveHandles.first.id;
    // 全选 Hi￼yo → 渲染偏移 0..5
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: blockId, renderOffset: 0),
      extent: DocumentPosition(blockId: blockId, renderOffset: 5),
    );
    final data = SelectionExporter(c.registry).export(c.selection);
    expect(data!.plainText, 'Hi:heart:yo');
  });

  testWidgets('长按起选 → 松手导出 SelectionData', (tester) async {
    final c = SelectionController(SelectionRegistry());
    SelectionData? captured;
    bool callbackFired = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _GestureHost(
            controller: c,
            onResult: (d) {
              callbackFired = true;
              captured = d;
            },
            inlines: const [TextRun('Hello world selection here')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final para = textGeometryAt(tester).renderBox;
    final center = para.localToGlobal(Offset.zero) +
        Offset(para.size.width / 2, para.size.height / 2);
    // 长按起选(选词)
    final g = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600)); // 触发 longPress
    await g.up();
    await tester.pumpAndSettle();

    expect(callbackFired, isTrue);
    expect(captured, isNotNull);
    expect(captured!.plainText.trim().isNotEmpty, isTrue);
  });

  testWidgets('复制文本构造正确(普通选区直接 plainText)', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [TextRun('CopyMe text')]));
    await tester.pumpAndSettle();
    final blockId = c.registry.liveHandles.first.id;
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: blockId, renderOffset: 0),
      extent: DocumentPosition(blockId: blockId, renderOffset: 6),
    );
    final data = SelectionExporter(c.registry).export(c.selection);
    expect(data, isNotNull);
    // 普通选区复制 = plainText 原样(toolbar 内 Clipboard.setData 用它)
    expect(data!.plainText, 'CopyMe');
    expect(data.code, isNull); // 非代码块,无 language 包裹
  });
}

class _GestureHost extends StatelessWidget {
  const _GestureHost({
    required this.controller,
    required this.onResult,
    required this.inlines,
  });
  final SelectionController controller;
  final void Function(SelectionData?) onResult;
  final List<InlineNode> inlines;

  @override
  Widget build(BuildContext context) {
    return SelectionScope(
      controller: controller,
      child: SelectionGestureLayer(
        controller: controller,
        onSelectionChanged: (data, {bool fromTouch = false}) => onResult(data),
        child: InlineSpanText(
          inlines: inlines,
          baseStyle: const TextStyle(fontSize: 20),
        ),
      ),
    );
  }
}
