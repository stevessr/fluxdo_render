import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/port_probe/model.dart';
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
  test('官方 repeat 正无穷不终止，探针明确拒绝；HTML 非字符串值不强转', () {
    expect(
      () => serializeProbe(
        ProbeNode(
          'doc',
          content: [
            ProbeNode('heading', attrs: {'level': 'Infinity'}),
          ],
        ),
      ),
      throwsA(isA<ProbeUnsupported>()),
    );
    expect(
      () => serializeProbe(
        ProbeNode(
          'doc',
          content: [
            ProbeNode(
              'html_inline',
              attrs: {
                'tag': 'small',
                'htmlAttrs': {'x': false},
              },
            ),
          ],
        ),
      ),
      throwsA(isA<ProbeUnsupported>()),
    );
  });
  final oracle =
      jsonDecode(
            File(
              '${root.path}/tools/editor-port-probe/oracle-fixtures.v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final value in oracle['cases'] as List) {
    final c = value as Map<String, dynamic>;
    if (c['status'] != 'ok') continue;
    test('独立 serializer：${c['id']}，逐字符含尾换行', () {
      final doc = ProbeNode.fromJson(c['doc'] as Map<String, dynamic>);
      expect(doc.toJson(), c['doc']);
      expect(serializeProbe(doc), c['serialized']);
      if (c['edit'] != null) {
        final edited = applyProbeEdit(doc, c['edit'] as Map<String, dynamic>);
        expect(edited.toJson(), c['editedDoc']);
        expect(serializeProbe(edited), c['editedSerialized']);
        expect(doc.toJson(), c['doc'], reason: '编辑不得修改原始树');
      }
    });
  }
}
