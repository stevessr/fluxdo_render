/// 复现「鼠标拖选,到图片附近 extent 卡住带不动」。
///
/// 结构:段落A → 高图片块(400px)→ 段落B,模拟鼠标从 A 拖到 B 经过图片,
/// 断言 positionAt 在图片各处都能命中(不返回 null),且能拖到 B。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/hit_tester.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

void main() {
  testWidgets('鼠标拖选经过高图片块:positionAt 在图片各处都命中', (tester) async {
    final c = SelectionController(SelectionRegistry());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: SelectionScope(
                controller: c,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const InlineSpanText(
                      inlines: [TextRun('AAAAA 第一段文字')],
                      baseStyle: TextStyle(fontSize: 16),
                      documentOrder: 0,
                    ),
                    // 高图片块(400px),作为可选块(￼ 占位)。
                    InlineSpanText(
                      inlines: const [
                        ImageRun(src: 'x', alt: 'pic', width: 300, height: 400),
                      ],
                      baseStyle: const TextStyle(fontSize: 16),
                      documentOrder: 1,
                      imageContentBuilder: (ctx, run, total) => const SizedBox(
                        width: 300,
                        height: 400,
                        child: ColoredBox(color: Color(0xFF888888)),
                      ),
                    ),
                    const InlineSpanText(
                      inlines: [TextRun('BBBBB 第二段文字')],
                      baseStyle: TextStyle(fontSize: 16),
                      documentOrder: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final hit = SelectionHitTester(c.registry);
    final order = c.registry.orderedBlocks();
    expect(order.length, 3, reason: '段+图+段 三块都注册');
    final imgId = order[1].id;
    final imgRect = c.registry.byId(imgId)!.globalRect();
    expect(imgRect, isNotNull, reason: '图片块应有几何');
    // 打印图片块几何 + 各处命中结果
    debugPrint('[img-rect] $imgRect');

    // 图片块顶部 / 中部 / 底部 三点
    for (final f in [0.1, 0.5, 0.9]) {
      final p = Offset(
        imgRect!.left + imgRect.width / 2,
        imgRect.top + imgRect.height * f,
      );
      final pos = hit.positionAt(p);
      debugPrint('[img-hit] f=$f point=$p -> $pos');
      expect(pos, isNotNull, reason: '图片块 $f 处应命中(不返回 null → 否则 extent 卡住)');
    }

    // 段落B 处也要命中(拖过图片到 B)
    final bId = order[2].id;
    final bRect = c.registry.byId(bId)!.globalRect()!;
    final posB = hit.positionAt(bRect.center);
    debugPrint('[B-hit] $posB');
    expect(posB, isNotNull);
    expect(posB!.blockId, bId, reason: 'B 中心应命中 B 块(extent 能拖到 B)');
  });
}
