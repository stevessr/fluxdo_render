import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  late EditorState state;
  setUp(() {
    state = EditorState(
      blocks: [
        const IslandBlock(
          id: 'grid',
          node: ImageGridNode(
            id: 'node',
            images: [ImageRun(src: 'a')],
          ),
        ),
        TextBlock(
          id: 'text',
          content: EditableTextContent(text: 'body'),
        ),
      ],
    );
    state.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'text', offset: 2),
      ),
    );
  });
  tearDown(() => state.dispose());

  test('图片组切换、添加、撤销不产生光标跟随请求', () {
    final key = state.caretRevealKey;
    setImageGridMode(state, 'grid', ImageGridMode.carousel);
    expect(state.caretRevealKey, key);
    appendImagesToGrid(state, 'grid', [const ImageRun(src: 'b')]);
    expect(state.caretRevealKey, key);
    state.undo();
    expect(state.caretRevealKey, key);
    state.undo();
    expect(state.caretRevealKey, key);
  });

  test('选区不动但所在段落内容变化仍需跟随', () {
    final key = state.caretRevealKey;
    final selection = state.selection;
    state.replaceBlockRange(1, 1, [
      TextBlock(
        id: 'text',
        content: EditableTextContent(text: 'changed'),
      ),
    ]);
    expect(state.selection, selection);
    expect(state.caretRevealKey, isNot(key));
  });

  test('移动光标与继续输入仍需跟随', () {
    final key = state.caretRevealKey;
    state.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'text', offset: 3),
      ),
    );
    expect(state.caretRevealKey, isNot(key));
    final moved = state.caretRevealKey;
    state.insertText('x');
    expect(state.caretRevealKey, isNot(moved));
  });
}
