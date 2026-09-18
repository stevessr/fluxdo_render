import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/port_probe/model.dart';
import 'package:fluxdo_render/src/editor/port_probe/parser.dart';
import 'package:fluxdo_render/src/editor/port_probe/serializer.dart';

void main() {
  var root = Directory.current;
  while (!File(
    '${root.path}/tools/editor-port-probe/oracle-fixtures.v1.json',
  ).existsSync()) {
    if (root.parent.path == root.path) {
      throw StateError('找不到真实官方 oracle fixture');
    }
    root = root.parent;
  }
  final fixture =
      jsonDecode(
            File(
              '${root.path}/tools/editor-port-probe/oracle-fixtures.v1.json',
            ).readAsStringSync(),
          )
          as Map;
  test('官方 fixture 有来源和版本', () {
    expect(fixture['version'], 1);
    expect(
      fixture['provenance']['commit'],
      'b3b561e5fad412c038e222499ebe22050b4a8de4',
    );
  });
  for (final item in fixture['cases'] as List) {
    final c = item as Map;
    test('官方结构 ${c['id']}', () {
      expect(c['status'], 'ok');
      final tokens = c['tokens'] as List;
      final before = jsonEncode(tokens);
      final doc = ProbeTokenParser().parseTokens(tokens);
      expect(doc.toJson(), c['doc']);
      expect(jsonEncode(tokens), before, reason: '不得修改官方 tokenizer DTO');
    });
    test('官方序列化及编辑 ${c['id']}', () {
      final doc = ProbeTokenParser().parseTokens(c['tokens'] as List);
      expect(serializeProbe(doc), c['serialized']);
      if (c['edit'] != null) {
        final edited = applyProbeEdit(
          doc,
          Map<String, dynamic>.from(c['edit'] as Map),
        );
        expect(edited.toJson(), c['editedDoc']);
        expect(serializeProbe(edited), c['editedSerialized']);
        expect(doc.toJson(), c['doc'], reason: '编辑不改变原树');
      }
    });
  }
  test('未知 attrs 保留且编辑路径以外共享节点', () {
    final untouched = ProbeNode(
      'heading',
      attrs: {
        'future': {'x': 1},
      },
    );
    final text = ProbeNode('text', text: '甲😀乙', attrs: {'unknown': true});
    final doc = ProbeNode(
      'doc',
      content: [
        ProbeNode('paragraph', content: [text]),
        untouched,
      ],
    );
    final edited = applyProbeEdit(doc, {
      'op': 'replaceText',
      'path': [0, 0],
      'from': 1,
      'to': 3,
      'text': '新',
    });
    expect(edited.content.first.textContent, '甲新乙');
    expect(edited.content.first.content.first.attrs['unknown'], true);
    expect(identical(edited.content[1], untouched), true);
    final patched = applyProbeEdit(edited, {
      'op': 'setAttrs',
      'path': [1],
      'attrs': {'level': 2},
    });
    expect(patched.content[1].attrs, {
      'future': {'x': 1},
      'level': 2,
    });
    expect(
      () => (patched.content[1].attrs['future'] as Map)['x'] = 2,
      throwsUnsupportedError,
    );
  });
  test('默认属性归一化与 heading marks', () {
    final node = ProbeSchema().fromJson({
      'type': 'heading',
      'content': [
        {
          'type': 'text',
          'text': 'x',
          'marks': [
            {
              'type': 'link',
              'attrs': {'href': '/x'},
            },
            {'type': 'code'},
          ],
        },
      ],
    });
    expect(node.attrs['level'], 1);
    expect(node.content.single.marks.first.attrs['title'], null);
    expect(
      () => ProbeSchema().create('heading', content: [ProbeNode('hard_break')]),
      throwsA(isA<ProbeUnsupported>()),
    );
  });
  test('非法 schema/token/path 明确失败', () {
    expect(
      () => applyProbeEdit(ProbeNode('heading'), {
        'op': 'setAttrs',
        'path': [],
        'attrs': {'future': 1},
      }),
      throwsA(isA<ProbeUnsupported>()),
    );
    expect(
      () => ProbeTokenParser().parseTokens([
        {'type': 'table_open'},
      ]),
      throwsA(isA<ProbeUnsupported>()),
    );
    expect(
      () =>
          ProbeSchema().create('paragraph', content: [ProbeNode('paragraph')]),
      throwsA(isA<ProbeUnsupported>()),
    );
    expect(
      () => ProbeSchema().create('text', text: ''),
      throwsA(isA<ProbeUnsupported>()),
    );
    expect(
      () =>
          applyProbeEdit(ProbeNode('doc', content: [ProbeNode('paragraph')]), {
            'op': 'setAttrs',
            'path': [2],
            'attrs': {},
          }),
      throwsA(isA<ProbeUnsupported>()),
    );
  });
}
