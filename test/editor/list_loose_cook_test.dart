// 使用真实 Discourse bundle 比较完整 HTML，不以导出字符串代替语义验证。
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/semantic_editor.dart';
import '../helpers/semantic_token_fixture.dart';
import '../helpers/discourse_token_node.dart';

void main() {
  final cases = <String>[
    '* mock\n\n  3. nested\n  4. second',
    '- mock\n  - nested\n  - second\n- tail',
    '- mock\n\n- second',
    '9. mock\n\n   3. nested\n   4. second\n\n10. tail',
    '12. mock\n\n    - nested\n    - second',
    '12. mock\n    - nested\n    - second',
    '- mock\n\n  12. nested\n\n      - deep\n      - next\n\n  13. second',
    '- mock\n  - nested\n\n    - deep\n\n    - next\n  - second',
    '- mock\n\n  3. child\n  4. next\n\n- other\n\n  7. child\n  8. next',
    '99. mock\n\n    - nested\n\n100. second\n\n     7. child\n     8. next',
  ];
  for (var i = 0; i < cases.length; i++) {
    test('真实松紧列表矩阵 $i：导入、重建、编辑', () async {
      final raw = cases[i];
      final dto = await parse(raw);
      final doc = parseSemanticFixture(dto);
      expect(doc.content.single.type, anyOf('bullet_list', 'ordered_list'),
          reason: '列表必须结构化可编辑，不能整篇源码回退');
      expect((await parse(serializeSemanticFixture(doc)))['cooked'], dto['cooked']);
      final rebuilt = SemanticNode.fromJson(doc.toJson());
      expect((await parse(serializeSemanticFixture(rebuilt)))['cooked'], dto['cooked']);
      final edited = appendFixtureText(doc, '改');
      expect((await parse(serializeSemanticFixture(edited)))['cooked'],
          (await parse(raw.replaceFirst('mock', 'mock改')))['cooked']);
    });
  }
}
