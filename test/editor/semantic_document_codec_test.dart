import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/document_codec.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

void main() {
  const codec = SemanticDocumentCodec();
  final fixtures =
      jsonDecode(File('test/fixtures/editor_tokens.json').readAsStringSync())
          as Map;
  for (final name in [
    'basic',
    'image',
    'details',
    'quote',
    'emoji',
    'mention',
  ]) {
    test('正式 tokenizer fixture $name 可序列化并绑定真实编辑会话', () {
      final fixture = fixtures[name] as Map;
      final tree = codec.parseTokens(fixture['tokens'] as List);
      final session = SemanticEditorSession(tree);
      addTearDown(session.dispose);
      expect(codec.serialize(session.tree), isNotEmpty);
      expect(session.tree, same(tree));
    });
  }
  test('脚注未知结构明确拒绝', () {
    expect(
      () => codec.parseTokens([
        {
          'type': 'footnote_ref',
          'meta': {'id': 0},
        },
      ]),
      throwsA(isA<SemanticCodecUnsupported>()),
    );
    expect(
      () => codec.parseTokens([
        {'type': 'table_open'},
      ]),
      throwsA(isA<SemanticCodecUnsupported>()),
    );
  });
  test('未知 HTML、缺失链接地址及错误闭合明确拒绝', () {
    for (final html in ['<unknown>', '<a>', '<kbd></kbd>', '</kbd>']) {
      expect(
        () => codec.parseTokens([
          {'type': 'paragraph_open'},
          {'type': 'html_inline', 'content': html},
          {'type': 'paragraph_close'},
        ]),
        throwsA(isA<SemanticCodecUnsupported>()),
      );
    }
  });
  test('未知属性保留且禁止 JS 怪值', () {
    final tree = codec.parseTokens([
      {
        'type': 'paragraph_open',
        'attrs': [
          [
            'future',
            {'x': 1},
          ],
        ],
      },
      {
        'type': 'text',
        'content': '文字',
        'attrs': [
          ['origin', 'mock'],
        ],
      },
      {'type': 'paragraph_close'},
    ]);
    expect(tree.content.single.attrs['future'], {'x': 1});
    expect(tree.content.single.content.single.attrs['origin'], 'mock');
    expect(
      () => codec.serialize(
        SemanticNode(
          'doc',
          content: [
            SemanticNode('heading', attrs: {'level': '2'}),
          ],
        ),
      ),
      throwsA(isA<SemanticCodecUnsupported>()),
    );
  });
}
