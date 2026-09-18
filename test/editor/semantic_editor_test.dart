import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';

SemanticNode paragraph(String text) =>
    SemanticNode('paragraph', content: [SemanticNode('text', text: text)]);
void main() {
  for (final soft in [null, false, true]) {
    test('正式换行 soft=$soft 可编辑、切分并撤销且保留来源属性', () {
      final lineBreak = SemanticNode(
        'hard_break',
        attrs: {'plugin': '换行来源', if (soft != null) 'soft': soft},
        marks: [
          SemanticMark('strong', {'plugin': '强调来源'}),
        ],
      );
      final source = SemanticNode(
        'doc',
        content: [
          SemanticNode(
            'paragraph',
            attrs: {'plugin': '段落'},
            content: [
              SemanticNode('text', text: '甲'),
              lineBreak,
              SemanticNode('text', text: '乙'),
            ],
          ),
        ],
      );
      final session = SemanticEditorSession(source);
      addTearDown(session.dispose);
      expect(session.editor.blocks.single, isA<TextBlock>());
      final block = session.editor.blocks.single as TextBlock;
      expect(block.kind, TextBlockKind.paragraph);
      expect(block.content.text, '甲\n乙');
      expect(block.content.softBreaks, soft == true ? {1} : isEmpty);
      expect(block.content.atoms, isEmpty);
      final projection = SemanticEditorProjection.project(source);
      final projected = projection.blocks.single as TextBlock;
      final toggled = projection.synchronize([
        projected.copyWith(
          content: EditableTextContent(
            text: projected.content.text,
            marks: projected.content.marks,
            softBreaks: soft == true ? {} : {1},
          ),
        ),
      ]);
      expect(toggled.content.single.content[1].attrs, {
        'plugin': '换行来源',
        'soft': soft != true,
      });
      expect(toggled.content.single.content[1].marks.single.attrs, {
        'plugin': '强调来源',
      });
      session.editor.imeReplace(block.id, 2, 3, '丙', caretOffset: 3);
      expect(session.tree.content.single.content.last.text, '丙');
      expect(session.tree.content.single.content[1], same(lineBreak));
      session.editor.undo();
      expect(session.tree, same(source));
      session.editor.updateSelection(
        EditorSelection.collapsed(EditorPosition(blockId: block.id, offset: 2)),
      );
      session.editor.splitBlock();
      expect(session.editor.blocks, hasLength(2));
      expect(session.editor.blocks.every((b) => b is TextBlock), isTrue);
      expect(session.tree.content.first.type, 'paragraph');
      expect(session.tree.content.first.content.last, same(lineBreak));
      session.editor.undo();
      expect(session.tree, same(source));
      session.editor.imeReplace(block.id, 1, 2, '', caretOffset: 1);
      expect(
        session.tree.content.single.content.any((n) => n.type == 'hard_break'),
        isFalse,
      );
      session.editor.undo();
      expect(session.tree, same(source));
    });
  }

  test('新增软硬换行成为正式节点，不继承 text 的扩展属性', () {
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode('text', text: '甲乙', attrs: {'plugin': '文本来源'}),
          ],
        ),
      ],
    );
    final projection = SemanticEditorProjection.project(source);
    final block = projection.blocks.single as TextBlock;
    for (final soft in [false, true]) {
      final tree = projection.synchronize([
        block.copyWith(
          content: EditableTextContent(
            text: '甲\n乙',
            softBreaks: soft ? {1} : {},
          ),
        ),
      ]);
      expect(tree.content.single.type, 'paragraph');
      expect(tree.content.single.content[1].type, 'hard_break');
      expect(tree.content.single.content[1].attrs, {'soft': soft});
      expect(
        (SemanticEditorProjection.project(tree).blocks.single as TextBlock)
            .content,
        EditableTextContent(text: '甲\n乙', softBreaks: soft ? {1} : {}),
      );
    }
  });
  test('IR 物化只改变表示，归一化快照保留链接 title 并同步编辑', () {
    final mark = SemanticMark('link', {
      'href': '/x',
      'title': '隐藏标题',
      'extra': 1,
    });
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode('text', text: '链接', marks: [mark]),
          ],
        ),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    session.editor.mode = EditorMode.ir;
    final id = session.editor.blocks.first.id;
    session.editor.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: id, offset: 1)),
    );
    expect(session.tree.toJson(), source.toJson());
    final literal = (session.editor.blocks.first as TextBlock).content.text;
    expect(literal, contains('[链接]'));
    final offset = literal.indexOf('链') + 1;
    session.editor.imeReplace(id, offset, offset, '新', caretOffset: offset + 1);
    expect(session.tree.content.first.textContent, '链新接');
    expect(
      session.tree.content.first.content.first.marks.first.attrs,
      mark.attrs,
    );
    session.editor.undo();
    expect(session.tree.toJson(), source.toJson());
  });
  test('链接 href 修改仍保留 title 和原未知属性', () {
    final mark = SemanticMark('link', {
      'href': '/old',
      'title': '标题',
      'extra': 3,
    });
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode('text', text: '链接', marks: [mark]),
          ],
        ),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final block = session.editor.blocks.first as TextBlock;
    session.editor.replaceBlockRange(0, 0, [
      block.copyWith(
        content: EditableTextContent(
          text: '链接',
          marks: const [
            MarkSpan(
              start: 0,
              end: 2,
              kind: MarkKind.link,
              attr: '/new',
              isAutoLink: false,
            ),
          ],
        ),
      ),
    ]);
    expect(session.tree.content.first.content.first.marks.first.attrs, {
      'href': '/new',
      'title': '标题',
      'extra': 3,
    });
    session.editor.undo();
    expect(session.tree, same(source));
  });

  test('不能猜测跨不同来源 text attrs 的归属', () {
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode('text', text: '甲', attrs: {'key': 1}),
            SemanticNode('text', text: '乙', attrs: {'key': 2}),
          ],
        ),
      ],
    );
    final projection = SemanticEditorProjection.project(source);
    final block = projection.blocks.first as TextBlock;
    expect(
      () => projection.synchronize([
        block.copyWith(content: EditableTextContent(text: '丙')),
      ]),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
    expect(projection.synchronize(projection.blocks), same(source));
  });
  test('未知属性、链接 title、嵌套与空节点在实际编辑和 undo 中保留', () {
    final link = SemanticMark('link', {
      'href': '/x',
      'title': '原始标题',
      'unknown': {'a': 1},
    });
    final target = SemanticNode(
      'paragraph',
      attrs: {'plugin': true},
      content: [
        SemanticNode(
          'text',
          text: '链接文字',
          attrs: {'textMeta': 8},
          marks: [link],
        ),
      ],
    );
    final opaque = SemanticNode(
      'media_plugin',
      attrs: {
        'payload': [1, 2],
      },
      content: [paragraph('内部')],
    );
    final empty = SemanticNode('blockquote');
    final summary = SemanticNode(
      'summary',
      attrs: {'meta': 1},
      content: [
        SemanticNode('text', text: '摘要', marks: [link]),
      ],
    );
    final source = SemanticNode(
      'doc',
      attrs: {'version': 8},
      content: [
        SemanticNode(
          'details',
          attrs: {'open': true, 'unknown': 9},
          content: [
            summary,
            SemanticNode(
              'quote',
              attrs: {'username': '用户', 'unknown': 7},
              content: [
                SemanticNode(
                  'ordered_list',
                  attrs: {'order': 3, 'tight': false, 'extra': 1},
                  content: [
                    SemanticNode(
                      'list_item',
                      attrs: {'key': 6},
                      content: [
                        target,
                        SemanticNode(
                          'bullet_list',
                          content: [
                            SemanticNode(
                              'list_item',
                              content: [SemanticNode('paragraph')],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
                opaque,
                empty,
              ],
            ),
          ],
        ),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    expect(session.tree, same(source));
    final block = session.editor.blocks.whereType<TextBlock>().first;
    expect(block.isListItem, isTrue);
    session.editor.imeReplace(block.id, 1, 2, '新', caretOffset: 2);
    final details = session.tree.content.first;
    final quote = details.content[1];
    final changed = quote.content.first.content.first.content.first;
    expect(changed.textContent, '链新文字');
    expect(changed.attrs, target.attrs);
    expect(changed.content.first.attrs, target.content.first.attrs);
    expect(changed.content.first.marks.first.toJson(), link.toJson());
    expect(details.content.first, same(summary));
    expect(quote.content[1], same(opaque));
    expect(quote.content[2], same(empty));
    expect(
      quote.content.first.content.first.content[1],
      same(
        source.content.first.content[1].content.first.content.first.content[1],
      ),
    );
    session.editor.undo();
    expect(session.tree, same(source));
    session.editor.redo();
    expect(
      session
          .tree
          .content
          .first
          .content[1]
          .content
          .first
          .content
          .first
          .content
          .first
          .textContent,
      '链新文字',
    );
  });

  test('空段落可以输入，heading 保留未知 attrs', () {
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode('paragraph'),
        SemanticNode(
          'heading',
          attrs: {'level': 2, 'extra': 9},
          content: [SemanticNode('text', text: '标题')],
        ),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    session.editor.imeReplace(
      session.editor.blocks.first.id,
      0,
      0,
      '内容',
      caretOffset: 2,
    );
    expect(session.tree.content.first.textContent, '内容');
    final h = session.editor.blocks.last as TextBlock;
    session.editor.replaceBlockRange(1, 1, [h.copyWith(headingLevel: 3)]);
    expect(session.tree.content.last.attrs, {'level': 3, 'extra': 9});
  });

  test('明确块替换可以改标题并撤销', () {
    final source = SemanticNode('doc', content: [paragraph('一'), paragraph('二')]);
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final blocks = session.editor.blocks;
    session.editor.replaceBlockRange(0, 0, [(blocks.first as TextBlock).asHeading(2)]);
    expect(session.tree.content.first.type, 'heading');
    session.editor.undo();
    expect(session.tree, same(source));
  });

  test('全不透明树的虚拟落点首次输入晋升且不改原岛', () {
    final source = SemanticNode('doc', content: [SemanticNode('unknown', attrs: {'x': 1})]);
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    expect(session.tree, same(source));
    session.editor.imeReplace('semantic_pad', 0, 0, '新', caretOffset: 1);
    expect(session.tree.content.first, same(source.content.first));
    expect(session.tree.content.last.textContent, '新');
    session.editor.undo();
    expect(session.tree, same(source));
  });
}
