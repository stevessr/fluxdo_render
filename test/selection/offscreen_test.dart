/// 跨视口稳定选区的「双赢」核心验证 —— 块滚出视口被回收(无 live 句柄)后,
/// 选区区间 + 复制仍走**逻辑块表 projection**,完整不丢。
///
/// 这是把选区从「逐块 live 几何」改成「逻辑文档模型 + 按需可见几何」后,
/// 对齐 Flutter SelectionArea / CodeMirror state.doc 行为的关键回归。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/projection.dart';
import 'package:fluxdo_render/src/selection/selection_exporter.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';
import 'package:fluxdo_render/src/selection/selection_range.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

void main() {
  // 纯文本块的 projection 快照(模拟 flatten 产出)。
  RenderTextProjection proj(String s) => RenderTextProjection([
        ProjectionEntry(
          renderStart: 0,
          renderLen: s.length,
          logicalText: s,
          kind: ProjectionKind.text,
        ),
      ]);

  group('逻辑块表(回收块)', () {
    test('全部块无 live 句柄(全回收)→ expandSelection + 复制仍完整', () {
      final reg = SelectionRegistry();
      // 只有逻辑块表(像被全部回收),没有任何 live 句柄。
      reg.updateLogical(const SelectableBlockId(0), proj('AAA'));
      reg.updateLogical(const SelectableBlockId(1), proj('BBB'));
      reg.updateLogical(const SelectableBlockId(2), proj('CCC'));

      final sel = DocumentSelection(
        base: const DocumentPosition(
            blockId: SelectableBlockId(0), renderOffset: 1),
        extent: const DocumentPosition(
            blockId: SelectableBlockId(2), renderOffset: 2),
      );

      final ranges = expandSelection(reg, sel);
      expect(ranges.length, 3, reason: '中间回收块也要在区间里');
      expect((ranges[0].start, ranges[0].end), (1, 3)); // 首块截断
      expect((ranges[1].start, ranges[1].end), (0, 3)); // 中间整段
      expect((ranges[2].start, ranges[2].end), (0, 2)); // 末块截断

      final data = SelectionExporter(reg).export(sel);
      expect(data, isNotNull);
      // 复制走逻辑 projection,与是否 mount 无关 → 完整。
      expect(data!.plainText, 'AA\nBBB\nCC');
    });

    test('跨 chunk 文档序(chunkIndex, docOrder)排序正确', () {
      final reg = SelectionRegistry();
      // 乱序写入,跨 2 个 chunk。
      reg.updateLogical(const SelectableBlockId(1, chunkIndex: 1), proj('D'));
      reg.updateLogical(const SelectableBlockId(0), proj('A'));
      reg.updateLogical(const SelectableBlockId(0, chunkIndex: 1), proj('C'));
      reg.updateLogical(const SelectableBlockId(1), proj('B'));

      final order = reg.orderedBlocks();
      // 期望 (0,0)(0,1)(1,0)(1,1) → A B C D
      expect([for (final b in order) b.projection.projectAll()],
          ['A', 'B', 'C', 'D']);

      // 选区从 chunk0 首到 chunk1 末,复制要按文档序拼全部。
      final sel = DocumentSelection(
        base: const DocumentPosition(
            blockId: SelectableBlockId(0), renderOffset: 0),
        extent: const DocumentPosition(
            blockId: SelectableBlockId(1, chunkIndex: 1), renderOffset: 1),
      );
      final data = SelectionExporter(reg).export(sel);
      expect(data!.plainText, 'A\nB\nC\nD');
    });
  });

  testWidgets('中间段落被回收(widget 移除)后,跨段复制仍含中间段', (tester) async {
    final c = SelectionController(SelectionRegistry());

    Widget host(List<(String, int)> paras) => MaterialApp(
          home: Scaffold(
            body: SelectionScope(
              controller: c,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (text, order) in paras)
                    InlineSpanText(
                      key: ValueKey(order),
                      inlines: [TextRun(text)],
                      baseStyle: const TextStyle(fontSize: 16),
                      documentOrder: order,
                    ),
                ],
              ),
            ),
          ),
        );

    await tester.pumpWidget(host([('AAA', 0), ('BBB', 1), ('CCC', 2)]));
    await tester.pumpAndSettle();

    final sel = DocumentSelection(
      base: const DocumentPosition(
          blockId: SelectableBlockId(0), renderOffset: 0),
      extent: const DocumentPosition(
          blockId: SelectableBlockId(2), renderOffset: 3),
    );
    c.selection = sel;
    expect(SelectionExporter(c.registry).export(sel)!.plainText, 'AAA\nBBB\nCCC');

    // 移除中间段(模拟 sliver 把它回收)—— live 句柄注销,逻辑块表保留。
    await tester.pumpWidget(host([('AAA', 0), ('CCC', 2)]));
    await tester.pumpAndSettle();
    expect(c.registry.liveLength, 2, reason: '中间段 live 句柄已摘');

    // 选区不变,复制仍含被回收的中间段(走逻辑块表)。
    final data = SelectionExporter(c.registry).export(sel);
    expect(data!.plainText, 'AAA\nBBB\nCCC',
        reason: '回收的中间块靠逻辑 projection 复制完整');
  });
}
