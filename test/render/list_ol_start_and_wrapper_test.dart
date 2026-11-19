/// 验证两个真机列表 bug 的修复(《Claude Code FAQ 指南》官网/中转站):
/// 1. `<ol start="N">` 续接序号 → marker = start+index(不是恒 1.)。
/// 2. 外层 li 仅含嵌套 ol/ul(inlines 空)→ 不渲染孤零零的空 bullet,
///    只保留嵌套子列表自身的 marker。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

void main() {
  Future<void> pump(WidgetTester tester, ListNode node) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (ctx) => NodeFactory().buildList(ctx, node)),
        ),
      ),
    );
  }

  testWidgets('ol start:marker 用 start+index(start=2 → 2./3.,无 1.)',
      (tester) async {
    await pump(
      tester,
      const ListNode(
        id: 'l',
        ordered: true,
        start: 2,
        depth: 0,
        items: [
          ListItem(inlines: [TextRun('中转站')]),
          ListItem(inlines: [TextRun('自定义')]),
        ],
      ),
    );
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('1.'), findsNothing, reason: 'start=2 不应出现 1.');
  });

  testWidgets('包裹 li(空 inline + 嵌套 ol/ul):marker 与嵌套首行同排(merge)',
      (tester) async {
    await pump(
      tester,
      const ListNode(
        id: 'l',
        ordered: false,
        depth: 0,
        items: [
          ListItem(
            inlines: [],
            children: [
              ListNode(
                id: 'ol',
                ordered: true,
                start: 2,
                depth: 1,
                items: [ListItem(inlines: [TextRun('中转站')])],
              ),
              ListNode(
                id: 'ul',
                ordered: false,
                depth: 1,
                items: [ListItem(inlines: [TextRun('BASE_URL')])],
              ),
            ],
          ),
        ],
      ),
    );
    // 嵌套 ol 续接序号正常。
    expect(find.text('2.'), findsOneWidget);
    final discFinder = find.byKey(const ValueKey('ul_marker_disc'));
    // 1) 同排:包裹 marker(disc)与嵌套 "2." 顶部接近(非空 marker 独占一行)。
    final discTop = tester.getTopLeft(discFinder).dy;
    final numTop = tester.getTopLeft(find.text('2.')).dy;
    expect((discTop - numTop).abs(), lessThan(10.0),
        reason: '包裹 marker 应与嵌套首行同排,diff=${discTop - numTop}');
    // 2) 紧凑:disc 右边到 "2." 左边的水平间距要小(修前是双重 gutter ~36px)。
    final gap = tester.getTopLeft(find.text('2.')).dx -
        tester.getTopRight(discFinder).dx;
    expect(gap, lessThan(18.0),
        reason: '○ 与 1. 间距应紧凑(对齐网页),实际 gap=$gap');
  });

  testWidgets('无序 marker 按 depth 变形:disc/circle/square(绘制形状)',
      (tester) async {
    await pump(
      tester,
      const ListNode(
        id: 'l',
        ordered: false,
        depth: 0,
        items: [
          ListItem(inlines: [TextRun('L0')], children: [
            ListNode(id: 'l1', ordered: false, depth: 1, items: [
              ListItem(inlines: [TextRun('L1')], children: [
                ListNode(id: 'l2', ordered: false, depth: 2, items: [
                  ListItem(inlines: [TextRun('L2')]),
                ]),
              ]),
            ]),
          ]),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('ul_marker_disc')), findsOneWidget,
        reason: 'depth0 = disc');
    expect(find.byKey(const ValueKey('ul_marker_circle')), findsOneWidget,
        reason: 'depth1 = circle');
    expect(find.byKey(const ValueKey('ul_marker_square')), findsOneWidget,
        reason: 'depth2 = square');
  });

  testWidgets('真实 fixture(block_li_nested_ol_start):完整 marker 多重集',
      (tester) async {
    // 直接读真实语料 fixture(官网/中转站/自定义 三段 + 嵌套 ul + 二选一)。
    final html = _readFixture('list/block_li_nested_ol_start.html');
    final nodes = ParagraphParser().parse(html);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              final f = NodeFactory();
              return ListView(children: [for (final n in nodes) f.build(ctx, n)]);
            },
          ),
        ),
      ),
    );
    // 三段续接序号各一次(修前是 1./1./1.)。
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('3.'), findsOneWidget);
    // 层级 marker(绘制形状):
    // - disc×1:Q 块级 li(depth0)。
    // - circle×3:官网/中转站/自定义 三个包裹 li(depth1,merge 后显示自身 marker)。
    // - square×6:有使用/使用/BASE_URL/AUTH_TOKEN/二选一/同中转站(depth≥2)。
    expect(find.byKey(const ValueKey('ul_marker_disc')), findsOneWidget);
    expect(find.byKey(const ValueKey('ul_marker_circle')), findsNWidgets(3));
    expect(find.byKey(const ValueKey('ul_marker_square')), findsNWidgets(6));
  });
}

String _readFixture(String rel) {
  for (final base in ['test/fixtures', 'packages/fluxdo_render/test/fixtures']) {
    final f = File('$base/$rel');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到 fixture: $rel');
}
