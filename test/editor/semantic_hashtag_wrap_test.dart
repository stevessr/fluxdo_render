import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show LinkRun, TextRun;
import 'package:fluxdo_render/src/editor/semantic_editor/document_codec.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

void main() {
  test('hashtag 替换保留未知属性，撤销恢复原树', () {
    final atom = SemanticNode('hashtag', attrs: {
      'ref': 'mock', 'href': '', 'unknown': {'keep': true},
    });
    final tree = SemanticNode('doc', content: [
      SemanticNode('paragraph', content: [atom]),
    ]);
    final session = SemanticEditorSession(tree);
    addTearDown(session.dispose);
    final block = session.editor.blocks.whereType<TextBlock>().single;
    session.editor.replaceAtomAt(block.id, 0, const LinkRun(
      href: '', hashtagRef: 'changed', children: [TextRun('#changed')],
    ));
    final changed = session.tree.content.single.content.single;
    expect(changed.attrs['unknown'], {'keep': true});
    expect(const SemanticDocumentCodec().serialize(session.tree), '#changed');
    session.editor.undo();
    expect(session.tree, same(tree));
  });

  test('旧 bbcode div wrap 与嵌套 wrap token 保留属性和正文', () {
    Map<String, dynamic> token(String type, {String tag = '',
        List<List<String>>? attrs, String content = ''}) => {
      'type': type, 'tag': tag, 'attrs': attrs, 'content': content,
    };
    final tree = const SemanticDocumentCodec().parseTokens([
      token('bbcode_open', tag: 'div', attrs: [
        ['class', 'd-wrap'], ['data-data-mock', 'x'], ['unknown', 'keep'],
      ]),
      token('wrap_open', tag: 'div', attrs: [['class', 'd-wrap']]),
      token('paragraph_open'), token('text', content: '正文'),
      token('paragraph_close'), token('wrap_close', tag: 'div'),
      token('bbcode_close', tag: 'div'),
    ]);
    expect(tree.content.single.attrs['unknown'], 'keep');
    expect(tree.content.single.content.single.type, 'wrap');
    expect(const SemanticDocumentCodec().serialize(tree),
      contains('[wrap data-mock="x"]\n[wrap]\n正文'));
    final session = SemanticEditorSession(tree);
    addTearDown(session.dispose);
    expect(session.editor.blocks.whereType<TextBlock>().single.content.text, '正文');
  });
}
