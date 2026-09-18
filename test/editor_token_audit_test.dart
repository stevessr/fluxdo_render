// 只读审计：真实 bundle 夹具贯穿导入、编辑模型及导出。
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/semantic_token_fixture.dart';

void main() {
  final fixtures = jsonDecode(File('test/fixtures/audit_token_matrix.json').readAsStringSync()) as Map<String, dynamic>;
  for (final entry in fixtures.entries) {
    test('审计 ${entry.key}', () async {
      final dto = Map<String, dynamic>.from(entry.value as Map);
      final document = parseSemanticFixture(dto);
      final back = serializeSemanticFixture(document);
      final cooked = await Process.run('node', ['-e', r"""
const fs = require('fs');
eval(fs.readFileSync('../../assets/cook/discourse-cook.js','utf8'));
__fluxdoCook.init(JSON.stringify({siteSettings:{enable_markdown_linkify:true,enable_mentions:true,enable_emoji:true,emoji_set:'twitter',poll_enabled:true,poll_maximum_options:30,spoiler_enabled:true,discourse_local_dates_enabled:true,enable_markdown_footnotes:true,discourse_math_enabled:true,discourse_math_enable_asciimath:true,discourse_math_provider:'mathjax'}}));
process.stdout.write(__fluxdoCook.cook(JSON.parse(process.argv[1])));
""", jsonEncode(back)]);
      expect(cooked.exitCode, 0, reason: '${cooked.stderr}');
      expect(cooked.stdout, dto['cooked'], reason: '完整 cooked 必须守恒');

      if (entry.key == 'mathAscii') {
        expect(back, dto['raw'], reason: '不能把 AsciiMath 改写为 TeX');
      }

      final edited = appendFixtureText(document, ' 审计追加');
      final afterEdit = serializeSemanticFixture(edited);
      expect(afterEdit, isNotEmpty);
      print(jsonEncode({'case': entry.key, 'raw': dto['raw'], 'back': back, 'afterEdit': afterEdit}));
    });
  }
}
