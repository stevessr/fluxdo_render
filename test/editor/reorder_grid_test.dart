/// reorderImageInGrid 命令 + EditorImageGrid 拖拽排序 widget 行为。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

ImageRun im(String a) => ImageRun(src: 'https://x.test/$a.png', alt: a);

List<String> altsOf(EditorState s) =>
    (s.blocks.whereType<IslandBlock>().first.node as ImageGridNode)
        .images
        .map((i) => i.alt)
        .toList();

void main() {
  test('reorderImageInGrid:落位 to 下标;undo 一步;越界 false', () {
    final s = EditorState(blocks: [
      IslandBlock(
        id: 'e_g',
        node: ImageGridNode(
            id: 'b_g', images: [im('a'), im('b'), im('c'), im('d')]),
      ),
    ]);
    addTearDown(s.dispose);

    // 向后拖:a(0) → 瓦片 c(2):a 落原 c 视觉格位
    expect(reorderImageInGrid(s, 'e_g', 0, 2), isTrue);
    expect(altsOf(s), ['b', 'c', 'a', 'd']);

    s.undo();
    expect(altsOf(s), ['a', 'b', 'c', 'd'], reason: 'undo 一步还原');

    // 向前拖:d(3) → 瓦片 b(1)
    expect(reorderImageInGrid(s, 'e_g', 3, 1), isTrue);
    expect(altsOf(s), ['a', 'd', 'b', 'c']);

    // 同位 = no-op true;越界/非 grid = false
    expect(reorderImageInGrid(s, 'e_g', 1, 1), isTrue);
    expect(altsOf(s), ['a', 'd', 'b', 'c']);
    expect(reorderImageInGrid(s, 'e_g', 0, 4), isFalse);
    expect(reorderImageInGrid(s, 'e_g', -1, 0), isFalse);
    expect(reorderImageInGrid(s, 'nope', 0, 1), isFalse);
  });

  testWidgets('长按瓦片拖到另一瓦片 = 重排;短按滑动不触发', (tester) async {
    final state = EditorState(blocks: [
      IslandBlock(
        id: 'e_g',
        node: ImageGridNode(
            id: 'b_g', images: [im('a'), im('b'), im('c')]),
      ),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FluxdoEditor(state: state, autofocus: true),
        ),
      ),
    ));
    await tester.pump();

    final tiles = find.byWidgetPredicate((widget) => widget is LongPressDraggable);
    expect(tiles, findsNWidgets(3));

    // 长按第 0 瓦片提起,拖到第 2 瓦片上放下
    final from = tester.getCenter(tiles.at(0));
    final rect = tester.getRect(tiles.at(2));
    final to = Offset(rect.right - 12, rect.center.dy);
    final g = await tester.startGesture(from, kind: PointerDeviceKind.touch);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveTo(to);
    await tester.pump(const Duration(milliseconds: 16));
    await g.up();
    await tester.pump();

    expect(altsOf(state), ['b', 'c', 'a'], reason: 'a 落位瓦片 2');

    // 短按滑动(未到长按阈值)= 不触发拖拽,顺序不变
    final g2 = await tester.startGesture(
      tester.getCenter(tiles.at(0)),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 80));
    await g2.moveBy(const Offset(200, 0));
    await tester.pump();
    await g2.up();
    await tester.pump();
    expect(altsOf(state), ['b', 'c', 'a'], reason: '未长按不重排');
  });

  testWidgets('单图 grid 禁用拖拽(保留稳定控件层级)', (tester) async {
    final state = EditorState(blocks: [
      IslandBlock(
        id: 'e_g',
        node: ImageGridNode(id: 'b_g', images: [im('a')]),
      ),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(state: state, autofocus: true),
      ),
    ));
    await tester.pump();
    final tile = find.byWidgetPredicate((widget) => widget is LongPressDraggable);
    expect(tile, findsOneWidget);
    expect(tester.widget<LongPressDraggable>(tile).maxSimultaneousDrags, 0);
  });
}
