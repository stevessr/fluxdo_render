import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  test('文本块操作覆盖全文，删除和撤销不影响相邻块', () {
    final state = EditorState.fromTexts(['第一段完整内容', '保留下一段']);
    addTearDown(state.dispose);
    final target = EditorBlockTarget(state.blocks.first.id);
    final object = resolveEditorObject(state, target)!;
    expect(object.selection.extent.offset, '第一段完整内容'.length);
    expect(object.markdown, '第一段完整内容');
    expect(deleteEditorObject(state, target), isTrue);
    expect((state.blocks.single as TextBlock).content.text, '保留下一段');
    state.undo();
    expect((state.blocks.first as TextBlock).content.text, '第一段完整内容');
  });

  test('删除唯一空段仍留下可输入文档，删除可撤销', () {
    final state = EditorState.fromTexts(['']);
    addTearDown(state.dispose);
    final oldId = state.blocks.first.id;
    deleteEditorObject(state, EditorBlockTarget(oldId));
    expect(state.blocks.single, isA<TextBlock>());
    expect(state.selection!.isCollapsed, isTrue);
    state.undo();
    expect(state.blocks.single.id, oldId);
  });

  const quote = QuoteFrame(groupId: 'outer');
  const details = DetailsFrame(groupId: 'details', summary: '详情');
  EditorState nested() => EditorState(
    blocks: [
      TextBlock(
        id: 'a',
        content: EditableTextContent(text: '外层前文'),
        containers: const [quote],
      ),
      TextBlock(
        id: 'b',
        content: EditableTextContent(text: '内层第一段'),
        containers: const [quote, details],
      ),
      TextBlock(
        id: 'c',
        content: EditableTextContent(text: '内层第二段'),
        containers: const [quote, details],
      ),
      TextBlock(
        id: 'd',
        content: EditableTextContent(text: '外层后文'),
        containers: const [quote],
      ),
    ],
  );

  test('容器解析覆盖连续子块，复制不带外层容器', () {
    final state = nested();
    addTearDown(state.dispose);
    final object = resolveEditorObject(
      state,
      const EditorContainerTarget('c', 'details'),
    )!;
    expect(object.blocks.map((block) => block.id), ['b', 'c']);
    expect(object.markdown, contains('[details="详情"]'));
    expect(object.markdown, isNot(contains('> ')));
    expect(object.selection.base.blockId, 'b');
    expect(object.selection.extent.blockId, 'c');
    deleteEditorObject(state, object.target);
    expect(state.blocks.map((block) => block.id), ['a', 'd']);
    state.undo();
    expect(state.blocks.length, 4);
  });

  test('容器前后继续输入落在容器外、父容器内', () {
    final state = nested();
    addTearDown(state.dispose);
    const target = EditorContainerTarget('b', 'details');
    placeCaretBesideEditorObject(state, target, after: false);
    expect(state.selection!.extent.blockId, 'a');
    placeCaretBesideEditorObject(state, target, after: true);
    expect(state.selection!.extent.blockId, 'd');
    expect(state.blocks.length, 4);
  });

  test('移除容器保留文字和外层，撤销恢复原结构', () {
    final state = nested();
    addTearDown(state.dispose);
    unwrapEditorContainer(state, const EditorContainerTarget('b', 'details'));
    expect(state.blocks.length, 4);
    expect((state.blocks[1] as TextBlock).containers, [quote]);
    expect((state.blocks[2] as TextBlock).content.text, '内层第二段');
    state.undo();
    expect((state.blocks[1] as TextBlock).containers, [quote, details]);
  });

  test('相同 groupId 的不连续容器不会跨过普通段落一起删除', () {
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'a',
          content: EditableTextContent(text: '一'),
          containers: const [quote],
        ),
        TextBlock(
          id: 'b',
          content: EditableTextContent(text: '间隔'),
        ),
        TextBlock(
          id: 'c',
          content: EditableTextContent(text: '二'),
          containers: const [quote],
        ),
      ],
    );
    addTearDown(state.dispose);
    deleteEditorObject(state, const EditorContainerTarget('a', 'outer'));
    expect(state.blocks.map((block) => block.id), ['b', 'c']);
  });

  test('网格子图复制与删除只作用于子图，过期目标不会误删其他图片', () {
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'text',
          content: EditableTextContent(text: '保留'),
        ),
        const IslandBlock(
          id: 'grid',
          node: ImageGridNode(
            id: 'g',
            images: [
              ImageRun(src: 'a.png', alt: 'A'),
              ImageRun(src: 'b.png', alt: 'B'),
            ],
          ),
        ),
      ],
    );
    addTearDown(state.dispose);
    const target = EditorGridImageTarget('grid', 0, 'a.png');
    expect(resolveEditorObject(state, target)!.markdown, '![A](a.png)');
    deleteEditorObject(state, target);
    expect(resolveEditorObject(state, target), isNull);
    expect(deleteEditorObject(state, target), isFalse);
    expect(
      ((state.blocks[1] as IslandBlock).node as ImageGridNode)
          .images
          .single
          .src,
      'b.png',
    );
    state.undo();
    expect(
      ((state.blocks[1] as IslandBlock).node as ImageGridNode).images.length,
      2,
    );
  });
}
