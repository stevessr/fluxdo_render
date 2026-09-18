import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import '../helpers/semantic_token_fixture.dart';

void main() {
  final fixtures = jsonDecode(File('test/fixtures/audit_token_matrix.json').readAsStringSync()) as Map;
  fixtures.addAll(jsonDecode(File('test/fixtures/link_list_tokens.json').readAsStringSync()) as Map);
  SemanticNode load(String name) => parseSemanticFixture(Map<String, dynamic>.from(fixtures[name] as Map));
  SemanticNode prepend(SemanticNode doc) => doc.copyWith(content: [
    doc.content.single.copyWith(content: [SemanticNode('text', text: '前 '), ...doc.content.single.content]),
  ]);
  for (final name in ['angle', 'email', 'original', 'titledAttachment']) {
    test('真实链接属性及写法往返 $name', () {
      final doc = load(name);
      expect(serializeSemanticFixture(doc), fixtures[name]['raw']);
      expect(serializeSemanticFixture(prepend(doc)), '前 ${fixtures[name]['raw']}');
    });
  }
  test('父项切换后嵌套列表重新起号', () {
    final doc = load('parents');
    expect(serializeSemanticFixture(doc), '* mock\n\n  3. child\n  4. next\n\n* other\n\n  7. child\n  8. next');
    final root = doc.content.single;
    expect(root.content.map((item) => item.content.last.attrs['order']), [3, 7]);
  });
  test('真实 attachment token 保留来源及附件模型，编辑相邻正文不丢属性', () {
    final doc = load('attachment');
    final link = doc.content.single.content.single.marks.single;
    expect(link.attrs['attachment'], isTrue);
    expect(link.attrs['data-orig-href'], 'upload://mock.pdf');
    expect(doc.content.single.content.single.text, 'mock');
    expect(serializeSemanticFixture(doc), fixtures['attachment']['raw']);
    expect(serializeSemanticFixture(prepend(doc)), '前 [mock|attachment](upload://mock.pdf)');
  });
  test('真实标题链接保留模型而非整块源码回退', () {
    final doc = load('linkTitle');
    expect(serializeSemanticFixture(doc), fixtures['linkTitle']['raw']);
    expect(doc.content.single.content.single.marks.single.attrs['title'], 'title');
  });
  test('真实嵌套列表起号进入模型并在模型编辑后继续递增', () {
    final doc = load('nestedList');
    final root = doc.content.single;
    final item = root.content.single;
    final nested = item.content.last;
    expect(nested.attrs['order'], 3);
    final first = nested.content.first;
    final paragraph = first.content.single;
    final changed = first.copyWith(content: [paragraph.copyWith(content: [SemanticNode('text', text: '改'), ...paragraph.content])]);
    SemanticNode rebuild(int order) => doc.copyWith(content: [root.copyWith(content: [item.copyWith(content: [item.content.first, nested.copyWith(attrs: {...nested.attrs, 'order': order}, content: [changed, ...nested.content.skip(1)])])])]);
    expect(serializeSemanticFixture(rebuild(3)), '* mock\n\n  3. 改nested\n  4. second');
    expect(serializeSemanticFixture(rebuild(12)), '* mock\n\n  12. 改nested\n  13. second');
    expect(rebuild(12).content.single.content.single.content.last.attrs['order'], 12);
  });
}
