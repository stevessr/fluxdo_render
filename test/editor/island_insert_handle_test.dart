/// 岛选中态「加段」把手:首块是岛时移动端的加段途径。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show CodeBlockNode;

void main() {
  testWidgets('选中岛出上下把手;点上把手 = 岛前建空段并落光标',
      (tester) async {
    final state = EditorState(blocks: [
      const IslandBlock(
        id: 'e_isl',
        node: CodeBlockNode(id: 'b_0', code: 'x', language: null),
      ),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(30),
          child: FluxdoEditor(state: state, autofocus: true),
        ),
      ),
    ));
    await tester.pump();

    expect(find.byKey(const ValueKey('island-insert-before')), findsNothing,
        reason: '未选中不出把手');

    // 单击整选岛
    await tester.tap(find.byType(EditorIsland));
    await tester.pump();
    expect(find.byKey(const ValueKey('island-insert-before')), findsOneWidget);
    expect(find.byKey(const ValueKey('island-insert-after')), findsOneWidget);

    final blocksBefore = state.blocks.length;
    await tester.tap(find.byKey(const ValueKey('island-insert-before')),
        warnIfMissed: false);
    await tester.pump();

    expect(state.blocks.length, blocksBefore + 1);
    expect(state.blocks.first, isA<TextBlock>(), reason: '岛前建段');
    final sel = state.selection!;
    expect(sel.isCollapsed, isTrue);
    expect(sel.extent.blockId, state.blocks.first.id, reason: '光标落新段');
    expect(sel.extent.offset, 0);
  });

  testWidgets('点下把手 = 岛后建空段', (tester) async {
    final state = EditorState(blocks: [
      TextBlock(id: 'e_0', content: EditableTextContent(text: 'a')),
      const IslandBlock(
        id: 'e_isl',
        node: CodeBlockNode(id: 'b_0', code: 'x', language: null),
      ),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(30),
          child: FluxdoEditor(state: state, autofocus: true),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byType(EditorIsland));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('island-insert-after')),
        warnIfMissed: false);
    await tester.pump();
    final islIdx = state.indexOfBlock('e_isl');
    expect(state.blocks[islIdx + 1], isA<TextBlock>());
    expect(state.selection!.extent.blockId, state.blocks[islIdx + 1].id);
  });
}
