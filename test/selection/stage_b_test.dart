import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/selection_exporter.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_range.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

import '../test_text_finders.dart';

void main() {
  Widget host(SelectionController c, List<List<InlineNode>> paragraphs) {
    return MaterialApp(
      home: Scaffold(
        body: SelectionScope(
          controller: c,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < paragraphs.length; i++)
                InlineSpanText(
                  inlines: paragraphs[i],
                  baseStyle: const TextStyle(fontSize: 16),
                  documentOrder: i,
                  emojiImageBuilder: (ctx, emoji, size) =>
                      SizedBox(width: size, height: size),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // 按视觉序取第 i 个块 id
  SelectableBlockId blockAt(SelectionController c, int i) =>
      c.registry.orderedBlocks()[i].id;

  testWidgets('跨两段选区:plainText 块间加 \\n', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [
      [TextRun('第一段文字')],
      [TextRun('第二段文字')],
    ]));
    await tester.pumpAndSettle();

    final b0 = blockAt(c, 0);
    final b1 = blockAt(c, 1);
    // 从第一段 offset 2 选到第二段 offset 3
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: b0, renderOffset: 2),
      extent: DocumentPosition(blockId: b1, renderOffset: 3),
    );
    final data = SelectionExporter(c.registry).export(c.selection);
    expect(data, isNotNull);
    // 第一段[2:]=段文字 + \n + 第二段[:3]=第二段
    expect(data!.plainText, '段文字\n第二段');
  });

  testWidgets('跨三段:中间段整段选中', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [
      [TextRun('AAA')],
      [TextRun('BBB')],
      [TextRun('CCC')],
    ]));
    await tester.pumpAndSettle();
    final b0 = blockAt(c, 0);
    final b2 = blockAt(c, 2);
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: b0, renderOffset: 1),
      extent: DocumentPosition(blockId: b2, renderOffset: 2),
    );
    final data = SelectionExporter(c.registry).export(c.selection);
    // AA + \n + BBB(整段) + \n + CC
    expect(data!.plainText, 'AA\nBBB\nCC');
  });

  testWidgets('反向选区(base 在后)归一化正确', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [
      [TextRun('上段')],
      [TextRun('下段')],
    ]));
    await tester.pumpAndSettle();
    final b0 = blockAt(c, 0);
    final b1 = blockAt(c, 1);
    // base 在第二段,extent 在第一段(从下往上拖)
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: b1, renderOffset: 2),
      extent: DocumentPosition(blockId: b0, renderOffset: 0),
    );
    final data = SelectionExporter(c.registry).export(c.selection);
    // 归一化后:上段(整) + \n + 下段(整)
    expect(data!.plainText, '上段\n下段');
  });

  testWidgets('跨段含 emoji 投影', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [
      [TextRun('心'), EmojiRun(name: 'heart', url: 'x')],
      [TextRun('好')],
    ]));
    await tester.pumpAndSettle();
    final b0 = blockAt(c, 0);
    final b1 = blockAt(c, 1);
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: b0, renderOffset: 0),
      extent: DocumentPosition(blockId: b1, renderOffset: 1),
    );
    final data = SelectionExporter(c.registry).export(c.selection);
    expect(data!.plainText, '心:heart:\n好');
  });

  testWidgets('expandSelection 端点截断 + 中间整段', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [
      [TextRun('12345')],
      [TextRun('67890')],
      [TextRun('ABCDE')],
    ]));
    await tester.pumpAndSettle();
    final b0 = blockAt(c, 0);
    final b2 = blockAt(c, 2);
    final sel = DocumentSelection(
      base: DocumentPosition(blockId: b0, renderOffset: 3),
      extent: DocumentPosition(blockId: b2, renderOffset: 2),
    );
    final ranges = expandSelection(c.registry, sel);
    expect(ranges.length, 3);
    expect((ranges[0].start, ranges[0].end), (3, 5)); // 首块截断
    expect((ranges[1].start, ranges[1].end), (0, 5)); // 中间整段
    expect((ranges[2].start, ranges[2].end), (0, 2)); // 末块截断
  });

  testWidgets('跨段高亮:每段各有矩形', (tester) async {
    final c = SelectionController(SelectionRegistry());
    await tester.pumpWidget(host(c, const [
      [TextRun('第一段比较长的文字内容')],
      [TextRun('第二段也是文字')],
    ]));
    await tester.pumpAndSettle();
    final b0 = blockAt(c, 0);
    final b1 = blockAt(c, 1);
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: b0, renderOffset: 0),
      extent: DocumentPosition(blockId: b1, renderOffset: 5),
    );
    final data = SelectionExporter(c.registry).export(c.selection);
    // 两段都该贡献高亮矩形
    expect(data!.globalRects.length, greaterThanOrEqualTo(2));
    // 外接框应跨两段(高度 > 单段)
    final para = textGeometryAt(tester).renderBox;
    expect(data.globalBounds.height, greaterThan(para.size.height));
  });
}
