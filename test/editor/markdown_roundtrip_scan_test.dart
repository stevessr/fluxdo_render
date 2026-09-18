/// 全 fixture 往返扫描:cooked → parse → blockNodesToDoc → docToMarkdown。
///
/// 不是逐字节等价断言(markdown 表达同一结构写法多样,且 fixture 是
/// cooked 不是 raw),是**编辑已有帖子链路的保底守护**:
/// 1. 全链路不抛异常;
/// 2. 可序列化岛(islandSerializable)不产空串(空串=内容凭空蒸发);
/// 3. 文本内容守恒抽查:fixture 里的中文正文子串在序列化产物里仍然在。
///
/// 语义级等价(serialize → 再 cook → cooked 结构对比)由主项目
/// semantic_composer_codec 的导入门禁在运行时兜底(cook 引擎在 JS bundle,
/// 子包测试环境跑不了)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editor_block.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

import '../fixtures/_meta/fixture_loader.dart' as loader;

void main() {
  final fixtures = loader.loadAll();

  test('fixture 目录非空(路径探测自检)', () {
    expect(fixtures, isNotEmpty);
  });

  group('全 fixture 往返扫描', () {
    for (final f in fixtures) {
      test(f.name, () {
        final parser = ParagraphParser();
        final nodes = parser.parse(f.html);
        var n = 0;
        final doc = blockNodesToDoc(nodes, () => 'e_${n++}');

        // 1. 序列化不抛异常
        final md = docToMarkdown(doc);

        // 2. 可序列化岛不产空串。BlankLineNode 本身就是空,跳过。
        var hasUnserializable = false;
        for (final block in doc) {
          if (block is! IslandBlock) continue;
          final node = block.node;
          if (node is BlankLineNode) continue;
          if (!islandSerializable(node)) {
            hasUnserializable = true;
            continue;
          }
          final s = serializeIslandNode(node);
          expect(
            s,
            isNotEmpty,
            reason: '可序列化岛 ${node.runtimeType} 序列化为空 '
                '(fixture=${f.name})——内容会凭空蒸发',
          );
        }

        // 3. 文本守恒抽查:cooked 里的中文连续段(≥4 字)应该在 markdown
        // 里保留。含不可序列化岛(poll/chat/policy)的 fixture 跳过 ——
        // 这些岛正文注定丢,靠主项目导入门禁拦整帖,不是 serializer 的责任。
        if (!hasUnserializable) {
          final paraTexts = RegExp(r'<p>([^<]{4,})</p>')
              .allMatches(f.html)
              .map((m) => m.group(1)!.trim())
              .where((s) => RegExp(r'[一-鿿]{4,}').hasMatch(s))
              .take(3);
          for (final t in paraTexts) {
            // 序列化会转义 markdown 元字符,对抽样文本做同口径转义后比对
            // 太脆;改为抽"无元字符的纯中文段"直接子串断言。
            if (RegExp(r'^[一-鿿,。:;!?、0-9a-zA-Z\s]+$').hasMatch(t)) {
              expect(
                md.contains(t),
                isTrue,
                reason: '正文文本 "$t" 在序列化产物中丢失(fixture=${f.name})',
              );
            }
          }
        }
      });
    }
  });
}
