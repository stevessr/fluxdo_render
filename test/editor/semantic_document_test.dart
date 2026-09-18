import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/document.dart';

void main() {
  test('完整 JSON 无损保留未知属性与脚注引用，不填充实验默认值', () {
    final json = <String, dynamic>{
      'type': 'doc',
      'attrs': {
        '未知': [
          true,
          null,
          {'数值': 2},
        ],
      },
      'content': [
        {
          'type': 'footnote_ref',
          'attrs': {'id': 'a', '引用': true},
        },
        {
          'type': 'text',
          'text': '正文',
          'marks': [
            {
              'type': 'link',
              'attrs': {'href': '/x', '未知': false},
            },
          ],
        },
      ],
    };
    final node = SemanticNode.fromJson(json);
    expect(node.toJson(), json);
    expect(node.content.first.nodeSize, 1);
    expect(node.content.last.marks.single.attrs.containsKey('title'), false);
  });

  test('输入与所有公开集合均不可变', () {
    final values = <dynamic>[
      {'x': 1},
    ];
    final attrs = <String, dynamic>{'values': values};
    final children = [SemanticNode('paragraph')];
    final marks = [SemanticMark('custom', attrs)];
    final node = SemanticNode(
      'doc',
      attrs: attrs,
      content: children,
      marks: marks,
    );
    values.clear();
    children.clear();
    marks.clear();
    expect(node.content, hasLength(1));
    expect(node.marks, hasLength(1));
    expect(node.attrs['values'], hasLength(1));
    expect(() => node.attrs['x'] = 1, throwsUnsupportedError);
    expect(
      () => (node.attrs['values'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => (node.attrs['values'][0] as Map)['x'] = 2,
      throwsUnsupportedError,
    );
    expect(() => node.content.clear(), throwsUnsupportedError);
    expect(() => node.marks.clear(), throwsUnsupportedError);
    expect(() => node.marks.single.attrs.clear(), throwsUnsupportedError);
  });

  test('复制支持全部字段与显式清空文本', () {
    final source = SemanticNode(
      'text',
      text: '😀',
      marks: [SemanticMark('em')],
    );
    expect(source.nodeSize, 2);
    expect(source.copy().toJson(), source.toJson());
    final result = source.copyWith(type: 'paragraph', text: null, marks: []);
    expect(result.text, isNull);
    expect(result.nodeSize, 2);
    expect(result.marks, isEmpty);
    expect(source.text, '😀');
    expect(SemanticMark('em').copy(type: 'strong').type, 'strong');
  });

  test('标记比较忽略属性键顺序，保留标记顺序和嵌套差异', () {
    final a = SemanticMark('link', {
      'href': '/x',
      'extra': [
        1,
        {'a': true},
      ],
    });
    final b = SemanticMark('link', {
      'extra': [
        1,
        {'a': true},
      ],
      'href': '/x',
    });
    expect(sameSemanticMarks([a], [b]), true);
    expect(
      sameSemanticMarks(
        [a],
        [
          b.copy(attrs: {'href': '/y'}),
        ],
      ),
      false,
    );
    expect(
      sameSemanticMarks([a, SemanticMark('em')], [SemanticMark('em'), b]),
      false,
    );
  });
}
