import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  testWidgets('引用中插入孤岛后前后两段容器身份不冲突，撤销重做正常', (tester) async {
    final state = EditorState.fromTexts(['引用前半引用后半']);
    addTearDown(state.dispose);
    final id = state.blocks.first.id;
    state.updateSelection(EditorSelection.collapsed(EditorPosition(blockId: id, offset: 4)));
    state.toggleQuote();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: FluxdoEditor(state: state),
    ))));
    await tester.pump();
    state.pasteBlocks([IslandBlock(id: 'pending', node: const ParagraphNode(id: 'upload', inlines: []))]);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(state.blocks.whereType<TextBlock>().length, 2);
    state.undo();
    await tester.pump();
    expect(tester.takeException(), isNull);
    state.redo();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
