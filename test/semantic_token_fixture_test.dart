import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import 'helpers/semantic_token_fixture.dart';
import 'helpers/discourse_token_node.dart';
import 'package:fluxdo_render/src/editor/model/poll_codec.dart';

void main() {
  test('合法投票根的单字段畸形变异全部拒绝', () {
    final valid = <Map<String, dynamic>>[
      {'type': 'poll_open', 'nesting': 1, 'attrs': {'class': 'poll'}},
      {'type': 'inline', 'nesting': 0, 'children': [{'type': 'text', 'nesting': 0, 'content': '模拟'}]},
      {'type': 'poll_close', 'nesting': -1, 'attrs': null},
    ];
    expect(importSemanticPollTokenNode(valid), isNotNull);
    for (final variant in <(int, String, Object)>[
      (1, 'children', 42), (2, 'attrs', 42), (1, 'nesting', 1),
    ]) {
      final mutated = (jsonDecode(jsonEncode(valid)) as List).cast<Map<String, dynamic>>();
      mutated[variant.$1][variant.$2] = variant.$3;
      expect(importSemanticPollTokenNode(mutated), isNull);
    }
  });

  test('poll 独立适配器安全拒绝畸形 token 与错配闭合', () {
    for (final tokens in <List<dynamic>>[
      [42],
      [{'type': 'poll_open', 'nesting': 1}, {'type': 'poll_close', 'nesting': -1, 'attrs': 42}],
      [{'type': 'poll_open', 'nesting': 1, 'attrs': [[42]]}, {'type': 'poll_close', 'nesting': -1}],
      [{'type': 'poll_open', 'nesting': 1}, {'type': 'strong_open', 'nesting': 1}, {'type': 'em_close', 'nesting': -1}, {'type': 'poll_close', 'nesting': -1}],
      [{'type': 'poll_open', 'nesting': 1}, {'type': 'unknown', 'nesting': 0}, {'type': 'poll_close', 'nesting': -1}],
    ]) {
      expect(importSemanticPollTokenNode(tokens), isNull);
    }
  });
  final fixtures =
      jsonDecode(File('test/fixtures/editor_tokens.json').readAsStringSync())
          as Map<String, dynamic>;
  for (final name in [
    'basic',
    'image',
    'details',
    'grid',
    'quote',
    'spoiler',
    'date',
    'emoji',
    'mention',
    'poll',
    'html',
    'raw',
    'fence',
  ]) {
    test('真实 bundle mock DTO 导入 $name', () async {
      final dto = Map<String, dynamic>.from(fixtures[name] as Map);
      final document = parseSemanticFixture(dto);
      final back = serializeSemanticFixture(document);
      expect(back, isNotEmpty);
      expect((await parse(back))['cooked'], dto['cooked'], reason: '完整 mock cooked 不得丢失结构和属性');
    });
  }
  test('图片原尺寸和缩放分开存储', () {
    final dto = Map<String, dynamic>.from(fixtures['image'] as Map);
    final document = parseSemanticFixture(dto);
    final node = document.content.single.content.single;
    expect(node.type, 'image');
    expect(node.attrs['origWidth'], 640);
    expect(node.attrs['width'], 320);
    expect(node.attrs['scale'], 50);
    expect(node.attrs['src'], 'upload://mockPicture.png');
  });
  test('未知无来源 token 明确拒绝', () {
    expect(() => parseSemanticFixture({
      'version': 1,
      'tokens': [
        {'type': 'unknown', 'nesting': 0},
      ],
    }), throwsA(isA<SemanticCodecUnsupported>()));
  });
  test('结构化投票不依赖根级源码范围', () {
    final dto =
        jsonDecode(jsonEncode(fixtures['poll'])) as Map<String, dynamic>;
    final first = (dto['tokens'] as List).first as Map;
    (first['meta']['fluxdoSource'] as Map)['root'] = false;
    final document = parseSemanticFixture(dto);
    expect(document.content.single.type, 'poll');
  });
  test('grid未知块不得静默丢弃', () {
    final dto =
        jsonDecode(jsonEncode(fixtures['grid'])) as Map<String, dynamic>;
    final tokens = dto['tokens'] as List;
    tokens.insert(1, {'type': 'unknown_block', 'nesting': 0});
    // 不再满足可靠 source tokenCount，必须整个拒绝而非只保图片。
    expect(() => parseSemanticFixture(dto), throwsA(isA<SemanticCodecUnsupported>()));
  });
  test('投票保持结构化节点与完整Markdown导出', () {
    final dto = Map<String, dynamic>.from(fixtures['poll'] as Map);
    final document = parseSemanticFixture(dto);
    final node = document.content.single;
    expect(node.attrs['rawHtml'], contains('data-poll-option-id'));
    expect(serializeSemanticFixture(document), dto['raw']);
  });
  test('未知版本明确拒绝', () {
    expect(
      () => parseSemanticFixture({'version': 2, 'tokens': []}),
      throwsA(isA<SemanticCodecUnsupported>()),
    );
  });
  test('投票无源码映射仍可从结构化数据导出闭合标签', () {
    final dto = Map<String, dynamic>.from(fixtures['poll'] as Map);
    final first = (dto['tokens'] as List).first as Map;
    first['meta'] = null;
    final document = parseSemanticFixture(dto);
    expect(document.content.single.type, 'poll');
    expect(serializeSemanticFixture(document), endsWith('[/poll]'));
  });
}
