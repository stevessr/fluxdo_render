import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';

SemanticNode para(
  String text, {
  String type = 'paragraph',
  Map<String, dynamic> attrs = const {},
}) => SemanticNode(
  type,
  attrs: attrs,
  content: [
    SemanticNode('text', text: text, attrs: {'inline': 7}),
  ],
);
void caret(EditorState editor, int index, int offset) => editor.updateSelection(
  EditorSelection.collapsed(
    EditorPosition(blockId: editor.blocks[index].id, offset: offset),
  ),
);
void main() {
  test('链接内部真实 split 保留两段 title、未知属性和 mark，撤销还原', () {
    final mark = SemanticMark('link', {
      'href': '/local',
      'title': '标题',
      'unknown': {'x': 1},
    });
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          attrs: {'block': 2},
          content: [
            SemanticNode(
              'text',
              text: '链接文字',
              attrs: {'inline': 3},
              marks: [mark],
            ),
          ],
        ),
      ],
    );
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    caret(s.editor, 0, 2);
    s.editor.splitBlock();
    expect(s.tree.content.map((n) => n.textContent), ['链接', '文字']);
    for (final n in s.tree.content) {
      expect(n.attrs, source.content.single.attrs);
      expect(n.content.single.attrs, {'inline': 3});
      expect(n.content.single.marks.single, same(mark));
    }
    s.editor.undo();
    expect(s.tree.toJson(), source.toJson());
  });

  test('带冲突属性空尾段显式merge保留左块属性且undo恢复右块', () {
    final source = SemanticNode(
      'doc',
      content: [
        para('a', attrs: {'x': 1}),
        SemanticNode('paragraph', attrs: {'x': 2}),
      ],
    );
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    caret(s.editor, 1, 0);
    s.editor.mergeWithPrevious(s.editor.blocks.last.id);
    expect(s.tree.content.single.attrs, {'x': 1});
    s.editor.undo();
    expect(s.tree, same(source));
  });
  test('真实 split、输入、backspace、undo 保留来源属性及未改 opaque 身份', () {
    final opaque = SemanticNode('plugin', attrs: {'x': 9});
    final source = SemanticNode(
      'doc',
      attrs: {'doc': 1},
      content: [
        para('甲乙', attrs: {'custom': 2}),
        opaque,
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final editor = session.editor;
    caret(editor, 0, 1);
    editor.splitBlock();
    expect(session.tree.content.map((n) => n.type), [
      'paragraph',
      'paragraph',
      'plugin',
    ]);
    expect(session.tree.content[1].attrs, {'custom': 2});
    expect(session.tree.content[1].content.first.attrs, {'inline': 7});
    expect(session.tree.content.last, same(opaque));
    editor.imeReplace(editor.blocks[1].id, 0, 0, '新', caretOffset: 1);
    expect(session.tree.content[1].textContent, '新乙');
    caret(editor, 1, 0);
    editor.backspace();
    expect(session.tree.content.first.textContent, '甲新乙');
    expect(session.tree.content.first.attrs, {'custom': 2});
    editor.undo();
    expect(session.tree.content.length, 3);
    expect(session.tree.content.last, same(opaque));
  });
  test('标题中部与尾部分裂，容器同父段落分裂保留容器 attrs', () {
    for (final offset in [1, 2]) {
      final s = SemanticEditorSession(
        SemanticNode(
          'doc',
          content: [
            para('甲乙', type: 'heading', attrs: {'level': 2, 'extra': 8}),
          ],
        ),
      );
      caret(s.editor, 0, offset);
      s.editor.splitBlock();
      expect(s.tree.content[1].type, offset == 2 ? 'paragraph' : 'heading');
      expect(s.tree.content[1].attrs['extra'], 8);
      s.dispose();
    }
    final quote = SemanticNode(
      'blockquote',
      attrs: {'quote': true},
      content: [para('甲乙')],
    );
    final s = SemanticEditorSession(SemanticNode('doc', content: [quote]));
    addTearDown(s.dispose);
    caret(s.editor, 0, 1);
    s.editor.splitBlock();
    expect(s.tree.content.single.attrs, quote.attrs);
    expect(s.tree.content.single.content.length, 2);
    s.editor.undo();
    expect(s.tree.content.single, same(quote));
  });
  test('真实 replaceBlockRange 顶层重排、删除与新增空段，undo 回原快照', () {
    final a = para('甲', attrs: {'a': 1}), b = para('乙', attrs: {'b': 2});
    final s = SemanticEditorSession(SemanticNode('doc', content: [a, b]));
    addTearDown(s.dispose);
    s.editor.replaceBlockRange(0, 1, s.editor.blocks.reversed.toList());
    expect(s.tree.content, [b, a]);
    s.editor.replaceBlockRange(1, 1, []);
    expect(s.tree.content, [b]);
    final first = s.editor.blocks.first;
    s.editor.replaceBlockRange(0, 0, [
      first,
      TextBlock(id: 'new_empty', content: EditableTextContent.empty),
    ]);
    expect(s.tree.content.last.attrs, isEmpty);
    s.editor.undo();
    expect(s.tree.content, [b]);
  });
  test('未知块 attrs 冲突合并以及列表 split 前置拒绝', () {
    final p = SemanticEditorProjection.project(
      SemanticNode(
        'doc',
        content: [
          para('甲', attrs: {'x': 1}),
          para('乙', attrs: {'x': 2}),
        ],
      ),
    );
    final a = p.blocks[0] as TextBlock, b = p.blocks[1] as TextBlock;
    expect(
      () => p.synchronize([a.copyWith(content: a.content.concat(b.content))]),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
    final list = SemanticEditorProjection.project(
      SemanticNode(
        'doc',
        content: [
          SemanticNode(
            'bullet_list',
            content: [
              SemanticNode('list_item', content: [para('甲乙')]),
            ],
          ),
        ],
      ),
    );
    final item = list.blocks.single as TextBlock;
    expect(
      () => list.synchronize([
        item.copyWith(content: item.content.slice(0, 1)),
        TextBlock(
          id: 'new',
          kind: item.kind,
          content: item.content.slice(1, 2),
        ),
      ]),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
  });
}
