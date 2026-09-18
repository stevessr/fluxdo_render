import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/editor/model/editor_block.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/widget/editor_table_grid.dart';

SemanticNode fixture() => SemanticNode(
  'doc',
  content: [
    SemanticNode(
      'table',
      attrs: {'未知表': 1},
      content: [
        for (var r = 0; r < 2; r++)
          SemanticNode(
            'table_row',
            attrs: {'未知行': r},
            content: [
              for (var c = 0; c < 2; c++)
                SemanticNode(
                  'table_cell',
                  attrs: {
                    'header': false,
                    'style': 'text-align:right',
                    '未知格': '$r-$c',
                  },
                  content: [SemanticNode('text', text: '重复')],
                ),
            ],
          ),
      ],
    ),
  ],
);

void main() {
  test('重复内容行列重排根据来源携带未知属性，撤销恢复', () {
    final source = fixture();
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    final block = s.editor.blocks.whereType<IslandBlock>().single;
    final old = block.node as TableNode;
    s.editor.updateIslandNode(
      block.id,
      TableNode(
        id: old.id,
        columnCount: 2,
        rowSourceIds: old.rowSourceIds.reversed.toList(),
        rows: [for (final row in old.rows.reversed) row.reversed.toList()],
      ),
    );
    expect(s.tree.content.single.content.first.attrs['未知行'], 1);
    expect(
      s.tree.content.single.content.first.content.first.attrs['未知格'],
      '1-1',
    );
    s.editor.undo();
    expect(s.tree.toJson(), source.toJson());
  });

  testWidgets('真实表格按钮增行增列删除及撤销保留未知属性', (tester) async {
    final source = fixture();
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: s.editor,
            builder: (context, _) {
              final block = s.editor.blocks.whereType<IslandBlock>().single;
              return EditorTableGrid(
                node: block.node as TableNode,
                selected: true,
                onChanged: (_) => fail('结构操作不应经过 Markdown'),
                onNodeChanged: (node) =>
                    s.editor.updateIslandNode(block.id, node),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('添加行'));
    await tester.pumpAndSettle();
    expect(s.tree.content.single.content.length, 3);
    expect(s.tree.content.single.content.last.content.length, 2);
    expect(s.tree.content.single.content.last.attrs, isEmpty);
    await tester.tap(find.byTooltip('添加列'));
    await tester.pumpAndSettle();
    expect(s.tree.content.single.content.first.content.length, 3);
    expect(
      s.tree.content.single.content.first.content.first.attrs['未知格'],
      '0-0',
    );
    expect(
      s.tree.content.single.content.first.content.first.attrs['style'],
      'text-align:right',
    );
    final rowHandle = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_RowHandle',
    );
    await tester.tap(rowHandle.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除此行'));
    await tester.pumpAndSettle();
    expect(s.tree.content.single.content.length, 2);
    final colHandle = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ColHandle',
    );
    await tester.tap(colHandle.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除此列'));
    await tester.pumpAndSettle();
    expect(s.tree.toJson(), source.toJson());
    for (var i = 0; i < 4; i++) {
      s.editor.undo();
    }
    await tester.pumpAndSettle();
    expect(s.tree.toJson(), source.toJson());
    expect(tester.takeException(), isNull);
  });
}
