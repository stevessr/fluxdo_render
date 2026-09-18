import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// 子包真实 bundle 测试桥接，不实现任何 token 解析。
Future<Map<String, dynamic>> parse(String raw) async {
  final process = await Process.run('node', [
    '-e',
    r'''
const fs = require('fs');
eval(fs.readFileSync('../../assets/cook/discourse-cook.js', 'utf8'));
__fluxdoCook.init(JSON.stringify({siteSettings:{enable_markdown_linkify:true}}));
process.stdout.write(__fluxdoCook.parseForEditor(JSON.parse(process.argv[1])));
''',
    jsonEncode(raw),
  ]);
  expect(process.exitCode, 0, reason: '${process.stderr}');
  return jsonDecode(process.stdout as String) as Map<String, dynamic>;
}
