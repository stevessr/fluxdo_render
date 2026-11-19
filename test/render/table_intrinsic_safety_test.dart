import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

/// `_TableWidget` 行的 `IntrinsicHeight` 会对 cell 子树做固有尺寸测量,
/// cell 内含不支持 intrinsic 的 render(LayoutBuilder / RenderViewport)时
/// debug 直接抛 "does not support returning intrinsic dimensions",layout
/// 中断后上层逐节点级联 "RenderBox was not laid out"。竖线改由
/// `_TableColumnDividerPainter` 整表通高绘制后,这类 cell 内容必须安全。
void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('cell 内含 LayoutBuilder(SVG 主项目注入结构) 不抛异常', (tester) async {
    // 主项目 _svgBuilder 的结构:LayoutBuilder 按可用宽度等比算高。
    // LayoutBuilder 不支持固有尺寸测量。
    final factory = NodeFactory(
      svgBuilder: (ctx, node) => LayoutBuilder(
        builder: (context, constraints) => SizedBox(
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : 100,
          height: 40,
          child: const Text('SVG_BOX'),
        ),
      ),
    );
    const table = TableNode(
      id: 't_0',
      columnCount: 2,
      hasHeader: true,
      rows: [
        [
          TableCellData(isHeader: true, children: [
            ParagraphNode(id: 'h_0', inlines: [TextRun('H1')]),
          ]),
          TableCellData(isHeader: true, children: [
            ParagraphNode(id: 'h_1', inlines: [TextRun('H2')]),
          ]),
        ],
        [
          TableCellData(children: [
            ParagraphNode(id: 'c_0', inlines: [TextRun('plain')]),
          ]),
          TableCellData(children: [
            SvgNode(id: 's_0', svgSource: '<svg viewBox="0 0 1 1"/>'),
          ]),
        ],
      ],
    );

    await pump(tester, Builder(builder: (c) => factory.build(c, table)));

    expect(tester.takeException(), isNull);
    // 表格骨架(横向滚动视口)正常渲染;cell 文本是自绘段落,树内无 Text,
    // 只断言注入的 SVG 内容(SVG_BOX 是真 Text widget)与骨架存在。
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('SVG_BOX'), findsOneWidget);
  });

  testWidgets('cell 内嵌套 >30 行表格(内部 ListView) 不抛异常', (tester) async {
    // 嵌套表格行数超过 _kTableVirtualizeThreshold(30) → 内部走
    // ListView.builder(RenderViewport) —— 同样不支持固有尺寸测量。
    final factory = NodeFactory();
    final innerRows = [
      for (var i = 0; i < 35; i++)
        [
          TableCellData(children: [
            ParagraphNode(id: 'ir_$i', inlines: [TextRun('r$i')]),
          ]),
        ],
    ];
    final table = TableNode(
      id: 't_1',
      columnCount: 1,
      rows: [
        [
          TableCellData(children: [
            TableNode(id: 'inner', columnCount: 1, rows: innerRows),
          ]),
        ],
      ],
    );

    await pump(tester, Builder(builder: (c) => factory.build(c, table)));

    expect(tester.takeException(), isNull);
  });

  testWidgets('普通文本表格:列分隔竖线仍整表绘制(视觉回归防护)', (tester) async {
    final factory = NodeFactory();
    const table = TableNode(
      id: 't_2',
      columnCount: 2,
      hasHeader: true,
      rows: [
        [
          TableCellData(isHeader: true, children: [
            ParagraphNode(id: 'h_0', inlines: [TextRun('H1')]),
          ]),
          TableCellData(isHeader: true, children: [
            ParagraphNode(id: 'h_1', inlines: [TextRun('H2')]),
          ]),
        ],
        [
          TableCellData(children: [
            ParagraphNode(id: 'c_0', inlines: [TextRun('a')]),
          ]),
          TableCellData(children: [
            ParagraphNode(id: 'c_1', inlines: [TextRun('b')]),
          ]),
        ],
      ],
    );

    await pump(tester, Builder(builder: (c) => factory.build(c, table)));

    expect(tester.takeException(), isNull);
    // 竖线由 CustomPaint(foregroundPainter) 承载;列分隔不再来自 cell 边框
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.foregroundPainter != null,
      ),
      findsAtLeastNWidgets(1),
    );
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('图片 cell 参与列宽采样:<img width=229> 撑开列(不再缩进 44px)',
      (tester) async {
    // 对齐浏览器 table 布局:列宽按内容自然撑开。修复前列宽只采样
    // 文本,纯图片 cell 退化到 minColWidth(60),图片按 max-width:100%
    // 缩进 60-16=44px(229px 手机截图成缩略图)。
    final factory = NodeFactory(
      imageContentBuilder: (ctx, image, _) => SizedBox(
        key: const ValueKey('imgBox'),
        width: image.width,
        height: image.height,
      ),
    );
    const table = TableNode(
      id: 't_3',
      columnCount: 2,
      rows: [
        [
          TableCellData(children: [
            ParagraphNode(id: 'c_0', inlines: [TextRun('x')]),
          ]),
          TableCellData(children: [
            ParagraphNode(id: 'c_1', inlines: [
              ImageRun(src: 'https://cdn.x/y.jpeg', width: 229, height: 500),
            ]),
          ]),
        ],
      ],
    );

    await pump(tester, Builder(builder: (c) => factory.build(c, table)));

    expect(tester.takeException(), isNull);
    // 图片列宽 = clamp(229+16, 60, 200) = 200,段落内图片可用宽 200-16=184
    // (修复前 44)。
    final imgSize = tester.getSize(find.byKey(const ValueKey('imgBox')));
    expect(imgSize.width, moreOrLessEquals(184, epsilon: 1));
  });
}
