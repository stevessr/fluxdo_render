import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';

void main() {
  for (final type in ['local_date', 'image', 'mention', 'emoji', 'text']) {
    test('$type 的格式 atom 支持旁编辑、格式变化和撤销，保留完整来源', () {
      final mark = SemanticMark(type == 'image' ? 'em' : 'strong', {
        '扩展': type,
      });
      final atom = SemanticNode(
        type,
        text: type == 'text' ? '附件' : null,
        attrs: {
          '扩展': '节点来源',
          if (type == 'local_date') 'date': '2026-05-01',
          if (type == 'image') 'src': 'https://example.com/a.png',
          if (type == 'mention') ...{'username': 'alice', 'href': '/u/alice'},
          if (type == 'emoji') ...{'name': 'smile', 'url': '/smile.png'},
        },
        marks: [
          mark,
          if (type == 'text')
            SemanticMark('link', {
              'href': '/a.zip',
              'attachment': true,
              'filename': 'a.zip',
              '扩展': '链接来源',
            }),
        ],
      );
      final source = SemanticNode(
        'doc',
        content: [
          SemanticNode(
            'paragraph',
            content: [
              SemanticNode('text', text: '甲'),
              atom,
              SemanticNode('text', text: '乙'),
            ],
          ),
        ],
      );
      final session = SemanticEditorSession(source);
      addTearDown(session.dispose);
      final block = session.editor.blocks.single as TextBlock;
      expect(block.content.text, '甲${kAtomChar}乙');
      expect(block.content.marks, hasLength(1));
      expect(block.content.marks.single.start, 1);
      expect(block.content.marks.single.end, 2);
      session.editor.imeReplace(block.id, 2, 3, '丙', caretOffset: 3);
      expect(session.tree.content.single.content[1], same(atom));
      session.editor.undo();
      expect(session.tree, same(source));
      session.editor.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: block.id, offset: 1),
          extent: EditorPosition(blockId: block.id, offset: 2),
        ),
      );
      session.editor.toggleMark(
        type == 'image' ? MarkKind.strong : MarkKind.em,
      );
      final updated = session.tree.content.single.content[1];
      expect(updated.attrs, atom.attrs);
      expect(
        updated.marks.where((m) => m.type == mark.type).single,
        same(mark),
      );
      expect(updated.marks.length, atom.marks.length + 1);
      session.editor.undo();
      expect(session.tree, same(source));
    });
  }

  test('未知或重复 atom 格式不吞，保守投影为不透明块', () {
    for (final marks in [
      [SemanticMark('unknown')],
      [
        SemanticMark('strong'),
        SemanticMark('strong', {'扩展': true}),
      ],
    ]) {
      final projection = SemanticEditorProjection.project(
        SemanticNode(
          'doc',
          content: [
            SemanticNode(
              'paragraph',
              content: [
                SemanticNode(
                  'local_date',
                  attrs: {'date': '2026-05-01'},
                  marks: marks,
                ),
              ],
            ),
          ],
        ),
      );
      expect(projection.blocks.first, isA<IslandBlock>());
    }
  });
}
