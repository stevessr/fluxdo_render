import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

SemanticNode p(String value, [Map<String, dynamic> attrs = const {}]) =>
    SemanticNode(
      'paragraph',
      attrs: attrs,
      content: value.isEmpty ? [] : [SemanticNode('text', text: value)],
    );
void caret(EditorState editor, int index, int offset) => editor.updateSelection(
  EditorSelection.collapsed(
    EditorPosition(blockId: editor.blocks[index].id, offset: offset),
  ),
);
void main() {
  test('callout壳标题更新保留扩展属性且warning类型不回退', () {
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'callout',
          attrs: {'typeRaw': 'warning', 'plugin': 4},
          content: [p('甲')],
        ),
        p('乙'),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final e = session.editor;
    final f = (e.blocks.first as TextBlock).containers.single as CalloutFrame;
    e.updateContainerFrame(
      f.groupId,
      CalloutFrame(
        groupId: f.groupId,
        kind: f.kind,
        typeRaw: f.typeRaw,
        title: '新标题',
      ),
    );
    expect(session.tree.content.first.attrs, {
      'typeRaw': 'warning',
      'plugin': 4,
      'title': '新标题',
    });
    e.undo();
    expect(session.tree, same(source));
  });

  test('同列表局部ordered切换与深层缩进实际树一致', () {
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [p('甲'), p('乙'), p('丙')]),
    );
    addTearDown(session.dispose);
    final e = session.editor;
    e.selectAll();
    e.toggleList(ordered: false);
    caret(e, 1, 0);
    e.toggleList(ordered: true);
    expect(session.tree.content.map((n) => n.type), [
      'bullet_list',
      'ordered_list',
      'bullet_list',
    ]);
    e.undo();
    caret(e, 1, 0);
    e.indentListItem();
    caret(e, 2, 0);
    e.indentListItem();
    e.indentListItem();
    expect((e.blocks.last as TextBlock).depth, 2);
    e.outdentListItem();
    e.outdentListItem();
    expect((e.blocks.last as TextBlock).depth, 0);
  });

  test('对象整选替换可信片段与撤销', () {
    final island = SemanticNode('horizontal_rule');
    final source = SemanticNode('doc', content: [p('甲'), island, p('乙')]);
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final id = session.editor.blocks[1].id;
    session.insertFragmentAtSelection(
      SemanticNode('doc', content: [p('新')]),
      selection: EditorSelection(
        base: EditorPosition(blockId: id, offset: 0),
        extent: EditorPosition(blockId: id, offset: 1),
      ),
    );
    expect(
      session.tree.content.any((n) => n.type == 'horizontal_rule'),
      isFalse,
    );
    expect(session.tree.textContent, contains('新'));
    session.editor.undo();
    expect(session.tree, same(source));
  });

  test('局部列表类型切换不吞并相邻列表实例', () {
    SemanticNode list(String label) => SemanticNode(
      'bullet_list',
      attrs: {'plugin': label},
      content: [
        SemanticNode('list_item', content: [p(label)]),
      ],
    );
    final a = list('甲'), b = list('乙');
    final session = SemanticEditorSession(SemanticNode('doc', content: [a, b]));
    addTearDown(session.dispose);
    caret(session.editor, 0, 0);
    session.editor.toggleList(ordered: true);
    expect(session.tree.content.first.type, 'ordered_list');
    expect(session.tree.content.last, same(b));
  });

  test('粘贴换行片段与跨块替换保留未删文本来源', () {
    final left = SemanticNode('text', text: '甲乙', attrs: {'origin': 'left'});
    final right = SemanticNode('text', text: '丙丁', attrs: {'origin': 'right'});
    final session = SemanticEditorSession(
      SemanticNode(
        'doc',
        content: [
          SemanticNode('paragraph', content: [left]),
          SemanticNode('paragraph', content: [right]),
        ],
      ),
    );
    addTearDown(session.dispose);
    final e = session.editor;
    e.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: e.blocks.first.id, offset: 1),
        extent: EditorPosition(blockId: e.blocks.last.id, offset: 1),
      ),
    );
    e.deleteSelection();
    expect(session.tree.content.single.content.map((n) => n.attrs['origin']), [
      'left',
      'right',
    ]);
    e.undo();
    caret(e, 0, 1);
    e.pastePlainText('一\n\n二');
    expect(session.tree.content.map((n) => n.textContent), ['甲一', '二乙', '丙丁']);
    expect(session.tree.content[1].content.last.attrs, {'origin': 'left'});
  });

  test('日常格式命令与撤销保留块扩展属性', () {
    final source = SemanticNode(
      'doc',
      content: [
        p('甲', {'plugin': 1}),
        p('乙'),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final e = session.editor;
    caret(e, 0, 0);
    for (final command in <void Function()>[
      () => e.toggleHeading(2),
      () => e.toggleList(ordered: false),
      () => e.toggleList(ordered: true),
      e.toggleQuote,
      () => e.wrapInContainer(DetailsFrame(groupId: 'details', summary: '标题')),
      () => e.wrapInContainer(SpoilerFrame(groupId: 'spoiler')),
      () => e.wrapInContainer(
        CalloutFrame(
          groupId: 'callout',
          kind: CalloutKind.note,
          typeRaw: 'note',
        ),
      ),
    ]) {
      command();
      expect(
        (e.documentBindingState as SemanticEditorProjection)
            .sources[e.blocks.first.id]!
            .attrs['plugin'],
        1,
      );
      e.undo();
      expect(identical(session.tree, source), isTrue);
    }
  });
  test('列表缩进反缩进和跨块删除可撤销', () {
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [p('甲'), p('乙')]),
    );
    addTearDown(session.dispose);
    final e = session.editor;
    e.selectAll();
    e.toggleList(ordered: false);
    caret(e, 1, 0);
    e.indentListItem();
    expect((e.blocks[1] as TextBlock).depth, 1);
    e.outdentListItem();
    expect((e.blocks[1] as TextBlock).depth, 0);
    e.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: e.blocks[0].id, offset: 0),
        extent: EditorPosition(blockId: e.blocks[1].id, offset: 1),
      ),
    );
    e.deleteSelection();
    expect(e.blocks.length, 1);
    e.undo();
    expect(e.blocks.length, 2);
  });
  test('可信片段任意caret保留text属性和一键撤销', () {
    final source = SemanticNode(
      'doc',
      content: [
        p('甲乙', {'block': 1}),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    caret(session.editor, 0, 1);
    final inserted = SemanticNode('text', text: '中', attrs: {'plugin': '粘贴'});
    session.insertFragmentAtSelection(
      SemanticNode(
        'doc',
        content: [
          SemanticNode('paragraph', content: [inserted]),
        ],
      ),
    );
    expect(session.tree.content.single.textContent, '甲中乙');
    expect(session.tree.content.single.content[1], same(inserted));
    expect(session.editor.selection!.extent.offset, 2);
    session.editor.undo();
    expect(session.tree, same(source));
  });
  test('空doc落点晋升、带属性空尾段退格', () {
    final session = SemanticEditorSession(SemanticNode('doc'));
    addTearDown(session.dispose);
    caret(session.editor, 0, 0);
    session.editor.insertText('甲');
    expect(session.tree.textContent, '甲');
    session.insertFragmentAtSelection(
      SemanticNode(
        'doc',
        content: [
          p('', {'plugin': 1}),
        ],
      ),
    );
    caret(session.editor, 1, 0);
    session.editor.backspace();
    expect(session.editor.blocks.first, isA<TextBlock>());
  });
}
