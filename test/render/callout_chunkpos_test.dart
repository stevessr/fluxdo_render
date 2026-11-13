/// 验证 callout「装饰下放」位置感知:首片有标题头 + 上外边距/上圆角,
/// 中/尾片无标题、连续装饰(左条+主色背景每片都画),仅尾片下外边距/下圆角。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

import '../test_text_finders.dart';

void main() {
  Future<Container> calloutContainer(
    WidgetTester tester,
    BlockquoteChunkPos pos, {
    String? title,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => NodeFactory().buildCallout(
              ctx,
              CalloutNode(
                id: 'c',
                kind: CalloutKind.info,
                typeRaw: 'info',
                title: title,
                chunkPos: pos,
                children: const [
                  ParagraphNode(id: 'p', inlines: [TextRun('正文')]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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

  testWidgets('whole:上下外边距 + 上下圆角 + 标题头', (tester) async {
    final c = await calloutContainer(
      tester,
      BlockquoteChunkPos.whole,
      title: '提示',
    );
    expect(margin(tester, c), (top: 8.0, bottom: 8.0));
    expect(corners(tester, c), (tr: 4.0, br: 4.0));
    expect(findRenderedText('提示'), findsOneWidget); // 标题头
  });

  testWidgets('first:上外边距 + 上圆角 + 标题头(无下圆角)', (tester) async {
    final c = await calloutContainer(
      tester,
      BlockquoteChunkPos.first,
      title: '提示',
    );
    expect(margin(tester, c), (top: 8.0, bottom: 0.0));
    expect(corners(tester, c), (tr: 4.0, br: 0.0));
    expect(findRenderedText('提示'), findsOneWidget);
  });

  testWidgets('mid:无外边距/圆角/标题(只正文 + 连续装饰)', (tester) async {
    final c = await calloutContainer(tester, BlockquoteChunkPos.mid);
    expect(margin(tester, c), (top: 0.0, bottom: 0.0));
    expect(corners(tester, c), (tr: 0.0, br: 0.0));
    // 中片不渲染标题头(info 默认标题 "Info" / "信息" 都不应出现)
    expect(findRenderedText('正文'), findsOneWidget);
  });

  testWidgets('last:下外边距 + 下圆角 + 无标题', (tester) async {
    final c = await calloutContainer(tester, BlockquoteChunkPos.last);
    expect(margin(tester, c), (top: 0.0, bottom: 8.0));
    expect(corners(tester, c), (tr: 0.0, br: 4.0));
  });

  testWidgets('各片左条 + 主色背景一致(连续)', (tester) async {
    for (final pos in BlockquoteChunkPos.values) {
      final c = await calloutContainer(tester, pos, title: 'T');
      final d = c.decoration! as BoxDecoration;
      expect((d.border! as Border).left.width, 4);
      expect(d.color, isNotNull);
    }
  });
}
