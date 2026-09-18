/// doc ↔ BlockNode 互转测试。
///
/// 往返策略:直接比较"树碎段形状"会掉进语义等价陷阱(粗体拆两段渲染
/// 相同但 != ),改断言 **二次导入不动点**:
///   `import(export(import(x))) == import(x)`(EditorBlock 值相等,
///   剔除 id —— id 每轮重新发号)
/// 加投影文本守恒(导出树的投影 == 导入前原树投影)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';
import 'package:fluxdo_render/src/selection/projection_builder.dart';

import '../fixtures/_meta/fixture_loader.dart' as loader;

String Function() idGen() {
  var n = 0;
  return () => 'e_${n++}';
}

/// 块的"内容签名"(剔 id;纯嵌套 List → expect 深比较)。
List<Object?> docSignature(List<EditorBlock> doc) => [
      for (final b in doc)
        switch (b) {
          TextBlock() => [
              'text',
              b.kind.name,
              b.headingLevel,
              b.ordered,
              b.depth,
              b.quoteDepth,
              b.content.text,
              [for (final m in b.content.marks) m.toString()],
              [
                for (final e in b.content.atoms.entries)
                  '${e.key}:${e.value}',
              ],
            ],
          IslandBlock() => ['island', b.node],
        },
    ];

/// 文档全部块的投影文本拼接(内容守恒断言)。
String blockNodesProjection(List<BlockNode> nodes) {
  final buf = StringBuffer();
  void walk(BlockNode n) {
    switch (n) {
      case ParagraphNode(:final inlines):
        buf.writeln(buildInlineProjection(inlines).projectAll());
      case HeadingNode(:final inlines):
        buf.writeln(buildInlineProjection(inlines).projectAll());
      case ListNode(:final items):
        for (final item in items) {
          buf.writeln(buildInlineProjection(item.inlines).projectAll());
          for (final sub in item.children ?? const <ListNode>[]) {
            walk(sub);
          }
        }
      case BlockquoteNode(:final children):
        children.forEach(walk);
      default:
        buf.writeln('[island:${n.runtimeType}]');
    }
  }

  nodes.forEach(walk);
  // ZWSP 软换行是渲染注入,内容比较剔除
  return buf.toString().replaceAll('​', '');
}

void main() {
  group('fixture 驱动:二次导入不动点 + 投影守恒', () {
    final parser = ParagraphParser();
    final types = [
      'paragraph',
      'heading',
      'list',
      'blockquote',
      'emoji',
      'mention',
      'inline_code',
    ];

    for (final type in types) {
      test(type, () {
        final fixtures = loader.loadByNodeType(type);
        expect(fixtures, isNotEmpty, reason: '$type fixture 不应为空');
        for (final f in fixtures) {
          final nodes = parser.parse(f.html);
          final doc1 = blockNodesToDoc(nodes, idGen());
          final exported = docToBlockNodes(doc1);
          final doc2 = blockNodesToDoc(exported, idGen());

          expect(
            docSignature(doc2),
            docSignature(doc1),
            reason: '${f.relativePath} 二次导入应是不动点',
          );
          expect(
            blockNodesProjection(exported),
            blockNodesProjection(nodes),
            reason: '${f.relativePath} 投影文本应守恒',
          );
        }
      });
    }
  });

  group('精确导出', () {
    test('嵌套列表:深度栈重建 ul>li>ol', () {
      var n = 0;
      String nid() => 'e_${n++}';
      final doc = <EditorBlock>[
        TextBlock(
          id: nid(),
          content: EditableTextContent(text: 'a'),
          kind: TextBlockKind.listItem,
        ),
        TextBlock(
          id: nid(),
          content: EditableTextContent(text: 'a1'),
          kind: TextBlockKind.listItem,
          ordered: true,
          depth: 1,
        ),
        TextBlock(
          id: nid(),
          content: EditableTextContent(text: 'b'),
          kind: TextBlockKind.listItem,
        ),
      ];
      final nodes = docToBlockNodes(doc);
      expect(nodes.length, 1);
      final list = nodes[0] as ListNode;
      expect(list.ordered, false);
      expect(list.items.length, 2);
      expect(list.items[0].children!.length, 1);
      final sub = list.items[0].children![0];
      expect(sub.ordered, true);
      expect(sub.depth, 1);
    });

    test('ol start 还原', () {
      final doc = <EditorBlock>[
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: 'x'),
          kind: TextBlockKind.listItem,
          ordered: true,
          listStart: 5,
        ),
      ];
      final nodes = docToBlockNodes(doc);
      expect((nodes[0] as ListNode).start, 5);
    });

    test('容器栈 run → 嵌套 BlockquoteNode(共享帧分组)', () {
      // groupId 语义:同帧实例才合并 —— 嵌套结构显式共享外层帧
      const outer = QuoteFrame(groupId: 'q_outer');
      const inner = QuoteFrame(groupId: 'q_inner');
      final doc = <EditorBlock>[
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: 'outer'),
          containers: const [outer],
        ),
        TextBlock(
          id: 'e_1',
          content: EditableTextContent(text: 'inner'),
          containers: const [outer, inner],
        ),
        TextBlock(
          id: 'e_2',
          content: EditableTextContent(text: 'after'),
        ),
      ];
      final nodes = docToBlockNodes(doc);
      expect(nodes.length, 2);
      final quote = nodes[0] as BlockquoteNode;
      expect(quote.children.length, 2);
      expect(quote.children[1], isA<BlockquoteNode>());
      expect(nodes[1], isA<ParagraphNode>());

      // 独立帧(不同 groupId)不合并:两个相邻引用保持两个
      final doc2 = <EditorBlock>[
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: 'A'),
          containers: const [QuoteFrame(groupId: 'qa')],
        ),
        TextBlock(
          id: 'e_1',
          content: EditableTextContent(text: 'B'),
          containers: const [QuoteFrame(groupId: 'qb')],
        ),
      ];
      expect(docToBlockNodes(doc2).length, 2);
    });

    test('ul/ol 相邻同深分家', () {
      final doc = <EditorBlock>[
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: 'u'),
          kind: TextBlockKind.listItem,
        ),
        TextBlock(
          id: 'e_1',
          content: EditableTextContent(text: 'o'),
          kind: TextBlockKind.listItem,
          ordered: true,
        ),
      ];
      final nodes = docToBlockNodes(doc);
      expect(nodes.length, 2);
      expect((nodes[0] as ListNode).ordered, false);
      expect((nodes[1] as ListNode).ordered, true);
    });

    test('单 emoji 段落导出 only-emoji', () {
      const emoji = EmojiRun(name: 'heart', url: 'u');
      final doc = <EditorBlock>[
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: kAtomChar, atoms: const {0: emoji}),
        ),
      ];
      final nodes = docToBlockNodes(doc);
      final para = nodes[0] as ParagraphNode;
      expect((para.inlines.single as EmojiRun).isOnlyEmoji, true);
    });

    test('空段落导出 BlankLineNode', () {
      final doc = <EditorBlock>[
        TextBlock(id: 'e_0', content: EditableTextContent.empty),
      ];
      expect(docToBlockNodes(doc)[0], isA<BlankLineNode>());
    });
  });

  group('岛化与 identity 透传', () {
    final parser = ParagraphParser();

    test('code_block/poll/table fixture 导入即岛,导出 identity', () {
      for (final type in ['code_block', 'poll', 'table']) {
        final fixtures = loader.loadByNodeType(type);
        for (final f in fixtures) {
          final nodes = parser.parse(f.html);
          final doc = blockNodesToDoc(nodes, idGen());
          final exported = docToBlockNodes(doc);
          final islands = doc.whereType<IslandBlock>().toList();
          expect(islands, isNotEmpty,
              reason: '${f.relativePath} 应至少产出一个岛');
          // identity 保真:导出树里能找到与岛 node 同一实例的节点
          for (final island in islands) {
            expect(
              exported.any((n) => identical(n, island.node)),
              true,
              reason: '${f.relativePath} 岛 node 应原引用直出',
            );
          }
        }
      }
    });

    test('普通链接段落可编辑(M5 link mark);特种链接仍岛化', () {
      // 普通链接:mark 化,不岛化
      final nodes = parser.parse('<p>看 <a href="https://x.com">这里</a></p>');
      final doc = blockNodesToDoc(nodes, idGen());
      expect(doc.whereType<IslandBlock>(), isEmpty);
      final tb = doc.single as TextBlock;
      expect(tb.content.text, '看 这里');
      expect(
        tb.content.marks.single,
        const MarkSpan(
            start: 2, end: 4, kind: MarkKind.link, attr: 'https://x.com',
            isAutoLink: false),
      );
      // 往返:toInlines 还原 LinkRun
      final back = tb.content.toInlines();
      expect(back.whereType<LinkRun>().single.href, 'https://x.com');

      // 特种链接(attachment)仍岛化
      final att = parser.parse(
          '<p><a class="attachment" href="/404" data-orig-href="upload://d.pdf">d.pdf</a></p>');
      final attDoc = blockNodesToDoc(att, idGen());
      expect(attDoc.whereType<IslandBlock>().length, 1);
    });

    test('列表含块级子节点:整棵岛化', () {
      final fixtures = loader.loadByNodeType('list');
      final faq = fixtures.firstWhere(
        (f) => f.relativePath.contains('block_children'),
      );
      final nodes = parser.parse(faq.html);
      final doc = blockNodesToDoc(nodes, idGen());
      expect(
        doc.whereType<IslandBlock>().any((b) => b.node is ListNode),
        true,
        reason: '含块级子节点的列表应整棵岛化',
      );
    });
  });
}
