import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  const image = ImageRun(src: 'image.png', width: 100, height: 80);
  for (final after in [false, true]) {
    test('图${after ? '后' : '前'}已有段落，继续输入不制造空段', () {
      final state = EditorState(
        blocks: [
          TextBlock(
            id: 'before',
            content: EditableTextContent(text: '前文'),
          ),
          TextBlock(
            id: 'image',
            content: EditableTextContent.fromInlines(const [image]),
          ),
          TextBlock(
            id: 'after',
            content: EditableTextContent(text: '后文'),
          ),
        ],
      );
      addTearDown(state.dispose);
      state.placeCaretBesideObject('image', atomOffset: 0, after: after);
      expect(state.blocks.length, 3);
      expect(state.selection!.extent.blockId, after ? 'after' : 'before');
      expect(state.selection!.extent.offset, after ? 0 : 2);
    });

    test('文档只有图片时${after ? '后' : '前'}方输入创建段落，并可撤销', () {
      final state = EditorState(
        blocks: [
          TextBlock(
            id: 'image',
            content: EditableTextContent.fromInlines(const [image]),
          ),
        ],
      );
      addTearDown(state.dispose);
      state.placeCaretBesideObject('image', atomOffset: 0, after: after);
      expect(state.blocks.length, 2);
      expect(
        state.textBlockById(state.selection!.extent.blockId)!.content.text,
        isEmpty,
      );
      expect(
        (state.blocks[after ? 0 : 1] as TextBlock).content.atoms.values.single,
        image,
      );
      state.undo();
      expect(state.blocks.length, 1);
      expect(
        (state.blocks.single as TextBlock).content.atoms.values.single,
        image,
      );
    });
  }

  test('行内图片两侧有文字时，继续输入留在同段', () {
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'p',
          content: EditableTextContent.fromInlines(const [
            TextRun('前'),
            image,
            TextRun('后'),
          ]),
        ),
      ],
    );
    addTearDown(state.dispose);
    state.placeCaretBesideObject('p', atomOffset: 1, after: false);
    expect(state.selection!.extent.offset, 1);
    state.placeCaretBesideObject('p', atomOffset: 1, after: true);
    expect(state.selection!.extent.offset, 2);
    expect(state.blocks.length, 1);
  });
}
