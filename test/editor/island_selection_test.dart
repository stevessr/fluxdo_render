/// onIslandSelected:岛整选态上抛(onebox 工具条锚定数据)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show CodeBlockNode;

void main() {
  testWidgets('岛整选上抛 island+rect;取消/移动选区上抛 null',
      (tester) async {
    final events = <IslandSelection?>[];
    final state = EditorState(blocks: [
      TextBlock(id: 'e_0', content: EditableTextContent(text: 'hello')),
      const IslandBlock(
        id: 'e_isl',
        node: CodeBlockNode(id: 'b_0', code: 'x', language: null),
      ),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(
          state: state,
          autofocus: true,
          onIslandSelected: events.add,
        ),
      ),
    ));
    await tester.pump();

    // 整选岛
    state.updateSelection(const EditorSelection(
      base: EditorPosition(blockId: 'e_isl', offset: 0),
      extent: EditorPosition(blockId: 'e_isl', offset: 1),
    ));
    await tester.pump();
    await tester.pump();
    final sel = events.whereType<IslandSelection>().last;
    expect(sel.island.id, 'e_isl');
    expect(sel.globalRect.height, greaterThan(0));

    // 移到文本 → null
    state.updateSelection(const EditorSelection.collapsed(
      EditorPosition(blockId: 'e_0', offset: 2),
    ));
    await tester.pump();
    await tester.pump();
    expect(events.last, isNull);
  });
}
