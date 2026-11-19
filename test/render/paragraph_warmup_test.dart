/// ParagraphWarmup 单测:预热产物与挂载路径 key 同源(缓存命中)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  setUp(() {
    FlattenCache.evictAll();
    ParagraphLayoutCache.evictAll();
    ParagraphWarmupProbe.reset();
  });

  testWidgets('预热后挂载:flatten 与排版均缓存命中', (tester) async {
    const nodes = <BlockNode>[
      ParagraphNode(id: 'b_0', inlines: [TextRun('warm me up before you go')]),
      ParagraphNode(id: 'b_1', inlines: [TextRun('second paragraph body')]),
    ];

    // 第一次挂载:登记探针(真实 theme/env/宽度)。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: FluxdoRender(cookedHtml: '', parsedNodes: nodes),
      ),
    ));
    expect(ParagraphWarmupProbe.snapshot(), isNotNull,
        reason: '直绘块挂载后探针应已收敛');

    // 卸载(模拟 sliver 回收)+ 清缓存(模拟这些段落从未见过)。
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    FlattenCache.evictAll();
    ParagraphLayoutCache.evictAll();

    // 预热(探针快照 + 任意挂载 context)。
    final ctx = tester.element(find.byType(SizedBox));
    final snapshot = ParagraphWarmupProbe.snapshot()!;
    final next = ParagraphWarmup.warmParagraphs(
      nodes: nodes,
      ctx: snapshot,
      context: ctx,
      totalImagesInPost: 0,
      budgetMicros: 1 << 30,
    );
    expect(next, -1, reason: '预算充足应一次热完');

    final flattenMissesAfterWarm = FlattenCache.misses;
    final layoutMissesAfterWarm = ParagraphLayoutCache.misses;
    expect(FlattenCache.length, 2);
    expect(ParagraphLayoutCache.length, greaterThanOrEqualTo(2));

    // 重新挂载:两层缓存都应命中,miss 不再增长。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: FluxdoRender(cookedHtml: '', parsedNodes: nodes),
      ),
    ));
    expect(FlattenCache.misses, flattenMissesAfterWarm,
        reason: '挂载 flatten 应全部命中预热产物');
    expect(ParagraphLayoutCache.misses, layoutMissesAfterWarm,
        reason: '挂载排版应全部命中预热产物');
  });

  testWidgets('探针未收敛时 snapshot 为 null', (tester) async {
    expect(ParagraphWarmupProbe.snapshot(), isNull);
  });
}
