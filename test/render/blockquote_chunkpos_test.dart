/// 验证 blockquote「装饰下放」位置感知:首/中/尾片的外边距与圆角,
/// 确保拆片后堆叠视觉连续(左条+背景每片都画,仅首尾留外边距/圆角)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

void main() {
  Future<Container> bqContainer(
    WidgetTester tester,
    BlockquoteChunkPos pos,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => NodeFactory().buildBlockquote(
              ctx,
              BlockquoteNode(
                id: 'b',
                chunkPos: pos,
                children: const [
                  ParagraphNode(id: 'p', inlines: [TextRun('引用')]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // buildBlockquote 根是唯一的 Container(子段落用 Padding,无 Container)。
    return tester.widget<Container>(find.byType(Container).first);
  }

  ({double top, double bottom}) margin(WidgetTester tester, Container c) {
    final m = tester.widget<Padding>(find.byWidgetPredicate((w) => w is Padding && w.child is ClipRSuperellipse && (w.child as ClipRSuperellipse).child == c)).padding as EdgeInsets;
    return (top: m.top, bottom: m.bottom);
  }

  ({double tr, double br}) corners(WidgetTester tester, Container c) {
    final r =
        tester
                .widget<ClipRSuperellipse>(
                  find
                      .ancestor(
                        of: find.byWidget(c),
                        matching: find.byType(ClipRSuperellipse),
                      )
                      .first,
                )
                .borderRadius
            as BorderRadius;
    return (tr: r.topRight.x, br: r.bottomRight.x);
  }

  testWidgets('whole:上下都有外边距 + 上下圆角(原行为)', (tester) async {
    final c = await bqContainer(tester, BlockquoteChunkPos.whole);
    expect(margin(tester, c), (top: 8.0, bottom: 8.0));
    expect(corners(tester, c), (tr: 4.0, br: 4.0));
  });

  testWidgets('first:仅上外边距 + 上圆角(无下圆角,接 mid)', (tester) async {
    final c = await bqContainer(tester, BlockquoteChunkPos.first);
    expect(margin(tester, c), (top: 8.0, bottom: 0.0));
    expect(corners(tester, c), (tr: 4.0, br: 0.0));
  });

  testWidgets('mid:无外边距、无圆角(上下无缝拼接)', (tester) async {
    final c = await bqContainer(tester, BlockquoteChunkPos.mid);
    expect(margin(tester, c), (top: 0.0, bottom: 0.0));
    expect(corners(tester, c), (tr: 0.0, br: 0.0));
  });

  testWidgets('last:仅下外边距 + 下圆角(无上圆角,接 mid)', (tester) async {
    final c = await bqContainer(tester, BlockquoteChunkPos.last);
    expect(margin(tester, c), (top: 0.0, bottom: 8.0));
    expect(corners(tester, c), (tr: 0.0, br: 4.0));
  });

  testWidgets('各片左条 + 背景一致(连续)', (tester) async {
    for (final pos in BlockquoteChunkPos.values) {
      final c = await bqContainer(tester, pos);
      final d = c.decoration! as BoxDecoration;
      // 每片都有左 4px 竖条 + 半透明背景 → 堆叠连续。
      expect((d.border! as Border).left.width, 4);
      expect(d.color, isNotNull);
    }
  });
}
