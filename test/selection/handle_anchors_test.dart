import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/selection_exporter.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

void main() {
  Future<SelectionController> mount(
      WidgetTester tester, List<List<InlineNode>> paras) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: SelectionScope(
                controller: c,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < paras.length; i++)
                      InlineSpanText(
                        inlines: paras[i],
                        baseStyle: const TextStyle(fontSize: 16),
                        documentOrder: i,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  SelectableBlockId blk(SelectionController c, int i) =>
      c.registry.orderedBlocks()[i].id;

  testWidgets('endpointAnchors:start 在首,end 在尾,start.dx < end.dx(单行)',
      (tester) async {
    final c = await mount(tester, const [
      [TextRun('Hello world selection')],
    ]);
    final id = blk(c, 0);
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: id, renderOffset: 2),
      extent: DocumentPosition(blockId: id, renderOffset: 8),
    );
    final a = SelectionExporter(c.registry).endpointAnchors(c.selection);
    expect(a, isNotNull);
    expect(a!.start.dx, lessThan(a.end.dx), reason: '单行 start 在 end 左侧');
    expect(a.startLineHeight, greaterThan(0));
  });

  testWidgets('endpointAnchors:折叠/空选区返回 null', (tester) async {
    final c = await mount(tester, const [
      [TextRun('abc')],
    ]);
    expect(SelectionExporter(c.registry).endpointAnchors(null), isNull);
    final id = blk(c, 0);
    c.selection = DocumentSelection.collapsed(
        DocumentPosition(blockId: id, renderOffset: 1));
    expect(SelectionExporter(c.registry).endpointAnchors(c.selection), isNull);
  });

  testWidgets('orderedEndpoints:正向选区 visualStart=base', (tester) async {
    final c = await mount(tester, const [
      [TextRun('abcdef')],
    ]);
    final id = blk(c, 0);
    final base = DocumentPosition(blockId: id, renderOffset: 1);
    final ext = DocumentPosition(blockId: id, renderOffset: 4);
    c.selection = DocumentSelection(base: base, extent: ext);
    final e = SelectionExporter(c.registry).orderedEndpoints(c.selection);
    expect(e!.visualStart.renderOffset, 1);
    expect(e.visualEnd.renderOffset, 4);
  });

  testWidgets('orderedEndpoints:反向选区(base 在后)归一', (tester) async {
    final c = await mount(tester, const [
      [TextRun('abcdef')],
    ]);
    final id = blk(c, 0);
    // base 在后(4),extent 在前(1)
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: id, renderOffset: 4),
      extent: DocumentPosition(blockId: id, renderOffset: 1),
    );
    final e = SelectionExporter(c.registry).orderedEndpoints(c.selection);
    expect(e!.visualStart.renderOffset, 1, reason: '视觉序最前 = 1');
    expect(e.visualEnd.renderOffset, 4);
  });

  testWidgets('endpointAnchors:跨段 end 在第二段(end.dy > start.dy)',
      (tester) async {
    final c = await mount(tester, const [
      [TextRun('第一段文字')],
      [TextRun('第二段文字')],
    ]);
    final b0 = blk(c, 0);
    final b1 = blk(c, 1);
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: b0, renderOffset: 1),
      extent: DocumentPosition(blockId: b1, renderOffset: 3),
    );
    final a = SelectionExporter(c.registry).endpointAnchors(c.selection);
    expect(a, isNotNull);
    expect(a!.end.dy, greaterThan(a.start.dy), reason: '跨段 end 在下方段');
  });
}
