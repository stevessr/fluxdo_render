/// poll 岛序列化测试:cooked div.poll → PollNode → [poll] BBCode 重建。
///
/// cooked 样例全部来自 cook bundle 实测输出(assets/cook/discourse-cook.js,
/// node vm 直跑,探针脚本见 tools/discourse-cook-bundle/test/smoke.mjs 同法)。
/// 「serialize 产物再 cook 与原 cooked 等价」已经离线三步法全绿验证
/// (12 组:regular/multiple+标题/number/close+name/富文本选项/status=closed
/// +groups/正文夹杂/多行选项/带空格 name/最小属性/同帖双 poll),此处固化
/// 结构断言防回归 —— 语义级等价由主项目 semantic_composer_codec 导入门禁运行时兜底。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editor_block.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

/// cooked html → 首个 poll 岛的序列化产物。
String rt(String cooked) {
  final nodes = ParagraphParser().parse(cooked);
  var n = 0;
  final doc = blockNodesToDoc(nodes, () => 'e_${n++}');
  final island = doc.whereType<IslandBlock>().firstWhere(
        (b) => b.node is PollNode,
      );
  return serializeIslandNode(island.node);
}

void main() {
  group('poll 岛序列化(cooked → [poll] BBCode)', () {
    test('regular 基础:type/results/public/chartType + 选项行', () {
      // cook('[poll type=regular results=always public=true chartType=bar]…')
      const cooked = '''
<div class="poll" data-poll-charttype="bar" data-poll-name="poll" data-poll-public="true" data-poll-results="always" data-poll-status="open" data-poll-type="regular">
<div class="poll-container">
<ul>
<li data-poll-option-id="cde51f51c588ef7af2c3ae58343deb28">选项甲</li>
<li data-poll-option-id="17a97d3e98d970f1015208b4abf112c0">选项乙</li>
</ul>
</div>
<div class="poll-info"><p>0 voters</p></div>
</div>''';
      expect(
        rt(cooked),
        '[poll type=regular results=always public=true chartType=bar]\n'
        '* 选项甲\n'
        '* 选项乙\n'
        '[/poll]',
      );
    });

    test('multiple + 标题 + min/max + pie', () {
      const cooked = '''
<div class="poll" data-poll-charttype="pie" data-poll-max="3" data-poll-min="1" data-poll-name="poll" data-poll-public="false" data-poll-results="on_vote" data-poll-status="open" data-poll-type="multiple">
<div class="poll-container">
<div class="poll-title">你最喜欢哪个?</div>
<ul>
<li data-poll-option-id="a1">A</li>
<li data-poll-option-id="b2">B</li>
</ul>
</div>
</div>''';
      expect(
        rt(cooked),
        '[poll type=multiple results=on_vote min=1 max=3 public=false chartType=pie]\n'
        '# 你最喜欢哪个?\n'
        '* A\n'
        '* B\n'
        '[/poll]',
      );
    });

    test('number:选项 li 是 min/max/step 派生物,不写选项行', () {
      const cooked = '''
<div class="poll" data-poll-max="10" data-poll-min="1" data-poll-name="poll" data-poll-public="true" data-poll-results="always" data-poll-status="open" data-poll-step="2" data-poll-type="number">
<div class="poll-container">
<ul><li data-poll-option-id="x1">1</li><li data-poll-option-id="x3">3</li></ul>
</div>
</div>''';
      expect(
        rt(cooked),
        '[poll type=number results=always min=1 max=10 step=2 public=true]\n'
        '[/poll]',
      );
    });

    test('非默认 name / close / status=closed / groups 写回', () {
      const cooked = '''
<div class="poll" data-poll-charttype="bar" data-poll-close="2026-12-31T16:00:00.000Z" data-poll-groups="staff,admins" data-poll-name="poll2" data-poll-public="true" data-poll-results="on_close" data-poll-status="closed" data-poll-type="regular">
<div class="poll-container">
<ul>
<li data-poll-option-id="y">是</li>
<li data-poll-option-id="n">否</li>
</ul>
</div>
</div>''';
      expect(
        rt(cooked),
        '[poll name=poll2 type=regular results=on_close public=true chartType=bar groups=staff,admins close=2026-12-31T16:00:00.000Z status=closed]\n'
        '* 是\n'
        '* 否\n'
        '[/poll]',
      );
    });

    test('默认值最小化:name=poll / status=open 不写回', () {
      // cook('[poll]\n* a\n* b\n[/poll]') 的输出形态
      const cooked = '''
<div class="poll" data-poll-name="poll" data-poll-status="open">
<div class="poll-container">
<ul>
<li data-poll-option-id="a">a</li>
<li data-poll-option-id="b">b</li>
</ul>
</div>
</div>''';
      expect(rt(cooked), '[poll]\n* a\n* b\n[/poll]');
    });

    test('富文本选项/标题:粗体/链接/emoji 还原 markdown 写法', () {
      const cooked = '''
<div class="poll" data-poll-charttype="bar" data-poll-name="poll" data-poll-public="true" data-poll-results="always" data-poll-status="open" data-poll-type="regular">
<div class="poll-container">
<div class="poll-title">标题 <strong>加粗</strong> <img src="/images/emoji/twitter/smile.png?v=15" title=":smile:" class="emoji" alt=":smile:" loading="lazy" width="20" height="20"></div>
<ul>
<li data-poll-option-id="o1"><strong>粗体</strong>选项</li>
<li data-poll-option-id="o2"><a href="https://example.com">链接</a></li>
</ul>
</div>
</div>''';
      expect(
        rt(cooked),
        '[poll type=regular results=always public=true chartType=bar]\n'
        '# 标题 **加粗** :smile:\n'
        '* **粗体**选项\n'
        '* [链接](https://example.com)\n'
        '[/poll]',
      );
    });

    test('多行选项(cooked <br>)写回缩进续行', () {
      const cooked = '''
<div class="poll" data-poll-charttype="bar" data-poll-name="poll" data-poll-public="true" data-poll-results="always" data-poll-status="open" data-poll-type="regular">
<div class="poll-container">
<ul>
<li data-poll-option-id="m">选项一<br>
续行文本</li>
<li data-poll-option-id="b">乙</li>
</ul>
</div>
</div>''';
      expect(
        rt(cooked),
        '[poll type=regular results=always public=true chartType=bar]\n'
        '* 选项一\n'
        '  续行文本\n'
        '* 乙\n'
        '[/poll]',
      );
    });

    test('name 含空格 → 引号包裹', () {
      const cooked = '''
<div class="poll" data-poll-charttype="bar" data-poll-name="my poll" data-poll-public="true" data-poll-results="always" data-poll-status="open" data-poll-type="regular">
<div class="poll-container">
<ul>
<li data-poll-option-id="a">a</li>
</ul>
</div>
</div>''';
      expect(rt(cooked), startsWith('[poll name="my poll" '));
    });

    test('islandSerializable:有 rawHtml 可序列化,无则不可', () {
      const withHtml = PollNode(
        id: 'b',
        pollName: 'poll',
        rawHtml: '<div class="poll" data-poll-name="poll"></div>',
      );
      const bare = PollNode(id: 'b', pollName: 'poll');
      expect(islandSerializable(withHtml), isTrue);
      expect(islandSerializable(bare), isFalse);
      expect(serializeIslandNode(bare), '');
    });
  });
}
