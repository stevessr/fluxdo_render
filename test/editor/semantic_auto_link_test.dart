import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/semantic_editor.dart';

void main() {
  for (final markup in ['linkify', 'bare']) {
    test('$markup 自动链接逐字编辑时同步目标、保留来源并可撤销', () {
      const url = 'https://example.com/path';
      final link = SemanticNode(
        'text',
        text: url,
        attrs: {'source': 7},
        marks: [
          SemanticMark('link', {'href': url, 'markup': markup, 'extension': 9}),
        ],
      );
      final source = SemanticNode(
        'doc',
        content: [
          SemanticNode('paragraph', content: [link]),
        ],
      );
      final session = SemanticEditorSession(source);
      addTearDown(session.dispose);
      final editor = session.editor;
      final block = editor.blocks.single as TextBlock;
      editor.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: block.id, offset: url.length - 1),
        ),
      );
      editor.insertText('new');
      const updatedUrl = 'https://example.com/patnewh';
      final updated = session.tree.content.single.content.single;
      expect(updated.text, updatedUrl);
      expect(updated.attrs, link.attrs);
      expect(updated.marks.single.attrs, {
        'href': updatedUrl,
        'markup': markup,
        'extension': 9,
      });
      expect(
        const SemanticDocumentCodec().serialize(session.exportTree()),
        updatedUrl,
      );
      editor.undo();
      expect(session.tree, same(source));
      editor.redo();
      expect(
        const SemanticDocumentCodec().serialize(session.exportTree()),
        updatedUrl,
      );
    });
  }
}
