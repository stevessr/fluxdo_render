import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final reversed in [false, true]) {
    for (final replacement in ['b', 'beta', '']) {
      test('跨段 IME 替换保留完整输入且一次撤销 reversed=$reversed text=$replacement', () {
        final state = EditorState.fromTexts([
          'alpha beta gamma',
          'second delta epsilon',
          'tail',
        ]);
        final from = EditorPosition(blockId: state.blocks.first.id, offset: 6);
        final to = EditorPosition(blockId: state.blocks[1].id, offset: 12);
        state.updateSelection(
          EditorSelection(
            base: reversed ? to : from,
            extent: reversed ? from : to,
          ),
        );
        final before = state.blocks;
        final ime = EditorImeClient(state: state);
        addTearDown(() {
          ime.detach();
          state.dispose();
        });
        ime.syncFromState(show: false);
        expect(ime.currentTextEditingValue!.text, ' beta gamma\nsecond delta');
        ime.updateEditingValue(
          TextEditingValue(
            text: ' $replacement',
            selection: TextSelection.collapsed(offset: replacement.length + 1),
          ),
        );
        expect(state.blocks.whereType<TextBlock>().map((b) => b.content.text), [
          'alpha $replacement epsilon',
          'tail',
        ]);
        state.undo();
        expect(state.blocks, before);
        expect(state.canUndo, isFalse);
      });
    }
  }

  test('跨段选择后中文组词仍是一次输入事务', () {
    final state = EditorState.fromTexts([
      'alpha beta gamma',
      'second delta epsilon',
    ]);
    state.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: state.blocks.first.id, offset: 6),
        extent: EditorPosition(blockId: state.blocks.last.id, offset: 12),
      ),
    );
    final before = state.blocks;
    final ime = EditorImeClient(state: state);
    addTearDown(() {
      ime.detach();
      state.dispose();
    });
    ime.syncFromState(show: false);
    ime.updateEditingValue(
      const TextEditingValue(
        text: ' n',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 1, end: 2),
      ),
    );
    expect(state.composing, const TextRange(start: 6, end: 7));
    expect(ime.currentTextEditingValue!.text, ' alpha n epsilon');
    ime.updateEditingValue(
      const TextEditingValue(
        text: ' alpha 你 epsilon',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    expect(
      state.blocks.whereType<TextBlock>().single.content.text,
      'alpha 你 epsilon',
    );
    expect(state.hasComposing, isFalse);
    state.undo();
    expect(state.blocks, before);
    expect(state.canUndo, isFalse);
  });
}
