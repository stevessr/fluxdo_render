import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/widget/editor_table_grid.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show TableNode;

void main() {
  testWidgets('最小表格保护、空白判定及提交失败保留输入', (tester) async {
    final node = ParagraphParser()
        .parse('<table><tr><td></td></tr></table>')
        .whereType<TableNode>()
        .single;
    EditorTableContext? current;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorTableGrid(
            node: node,
            autoEdit: true,
            onChanged: (_) {},
            onNodeChanged: (_) => fail('提交失败不得修改结构'),
            commitEditing: (_) async => false,
            onEditingContextChanged: (value) => current = value,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(current!.rowHasContent, isFalse);
    expect(current!.columnHasContent, isFalse);
    expect(current!.enabled(EditorTableAction.deleteRow), isFalse);
    expect(current!.enabled(EditorTableAction.deleteColumn), isFalse);
    expect(
      await current!.execute(EditorTableAction.deleteRow),
      EditorTableActionResult.unavailable,
    );
    await tester.enterText(find.byType(EditableText), '未提交文字');
    await tester.pump();
    await tester.pump();
    expect(current!.rowHasContent, isTrue);
    final result = current!.execute(EditorTableAction.rowAfter);
    await tester.pump();
    await tester.pump();
    expect(await result, EditorTableActionResult.failed);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '未提交文字',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final action in EditorTableAction.values) {
    testWidgets('表格结构动作 ${action.name} 保留焦点并拒绝过期命令', (tester) async {
      var node = ParagraphParser()
          .parse(
            '<table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table>',
          )
          .whereType<TableNode>()
          .single;
      EditorTableContext? current;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, rebuild) => EditorTableGrid(
                node: node,
                onChanged: (_) {},
                onNodeChanged: (next) => rebuild(() => node = next),
                commitEditing: (_) async => true,
                onEditingContextChanged: (value) => current = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.pump();
      final old = current!;
      expect(old.rowHasContent, isTrue);
      expect(old.columnHasContent, isTrue);
      final result = old.execute(action);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(await result, EditorTableActionResult.success);
      expect(node.rows.length, switch (action) {
        EditorTableAction.rowBefore || EditorTableAction.rowAfter => 3,
        EditorTableAction.deleteRow => 1,
        _ => 2,
      });
      expect(node.columnCount, switch (action) {
        EditorTableAction.columnBefore || EditorTableAction.columnAfter => 3,
        EditorTableAction.deleteColumn => 1,
        _ => 2,
      });
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(await old.execute(action), EditorTableActionResult.stale);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
