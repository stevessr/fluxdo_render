/// 图片原子交互：确认点击后整选；触摸重复点选不打开，鼠标双击查看。
/// 覆盖滚动取消、长按、退格删除、reselect 与选区矩形。
library;

import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

const _img = ImageRun(
  src: 'https://x/doge.png',
  alt: 'doge',
  width: 100,
  height: 80,
);

EditorState _doc() => EditorState(
  blocks: [
    TextBlock(
      id: 'e_0',
      content: EditableTextContent.fromInlines(const [
        TextRun('前'),
        _img,
        TextRun('后'),
      ]),
    ),
  ],
);

void main() {
  Future<
    ({
      EditorState state,
      List<ImageAtomSelection?> selEvents,
      List<ImageAtomSelection> openEvents,
    })
  >
  pump(WidgetTester tester) async {
    final state = _doc();
    addTearDown(state.dispose);
    final selEvents = <ImageAtomSelection?>[];
    final openEvents = <ImageAtomSelection>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: FluxdoEditor(
              state: state,
              autofocus: true,
              onImageAtomSelectionChanged: selEvents.add,
              onImageAtomOpenRequest: openEvents.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(); // 帧后事件
    return (state: state, selEvents: selEvents, openEvents: openEvents);
  }

  Future<void> tapImage(WidgetTester tester) async {
    await tester.tap(
      find.byType(Image, skipOffstage: false).first,
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(); // _afterFrame 上抛
  }

  testWidgets('点图 = 整选原子(不落光标),事件带矩形贴图', (tester) async {
    final h = await pump(tester);
    await tapImage(tester);

    final sel = h.state.selection!;
    expect(sel.base.offset, 1);
    expect(sel.extent.offset, 2, reason: '整选 FFFC,非折叠光标');

    final ev = h.selEvents.last;
    expect(ev, isNotNull);
    expect(ev!.blockId, 'e_0');
    expect(ev.offset, 1);
    expect(ev.image, _img);
    final imgRect = tester.getRect(find.byType(Image).first);
    expect(
      (ev.globalRect.center - imgRect.center).distance,
      lessThan(2),
      reason: '事件矩形贴图片渲染矩形',
    );
  });

  testWidgets('已选中再点保持选中，不误打开查看器', (tester) async {
    final h = await pump(tester);
    await tapImage(tester);
    expect(h.openEvents, isEmpty);

    await tapImage(tester);
    expect(h.openEvents, isEmpty);
    expect(h.state.selection!.extent.offset, 2, reason: '选区保持整选');
  });

  testWidgets('图片按下尚未选中，滑动取消不遗留选中或打开动作', (tester) async {
    final h = await pump(tester);
    final before = h.state.selection;
    final rect = tester.getRect(find.byType(Image).first);
    final gesture = await tester.startGesture(rect.center);
    await tester.pump(const Duration(milliseconds: 150));
    expect(h.state.selection, before);
    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await tester.pump();
    expect(h.state.selection, before);
    expect(h.openEvents, isEmpty);
  });

  testWidgets('长按已选中图片保持对象，不打开查看器', (tester) async {
    final h = await pump(tester);
    await tapImage(tester);
    await tester.longPress(find.byType(Image).first);
    await tester.pump();
    expect(h.openEvents, isEmpty);
    expect(
      h.state.selection!.extent.offset - h.state.selection!.base.offset,
      1,
    );
  });

  testWidgets('鼠标双击图片打开查看器，第一次只选中', (tester) async {
    final h = await pump(tester);
    final point = tester.getRect(find.byType(Image).first).center;
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(h.openEvents, isEmpty);
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(h.openEvents, hasLength(1));
  });

  testWidgets('选中态退格 → 删原子,事件回 null', (tester) async {
    final h = await pump(tester);
    await tapImage(tester);

    h.state.backspace();
    await tester.pump();
    await tester.pump();

    final b = h.state.blocks.single as TextBlock;
    expect(b.content.text, '前后');
    expect(b.content.atoms, isEmpty);
    expect(h.selEvents.last, isNull, reason: '取消选中事件');
  });

  testWidgets('replaceAtomAt reselect:true → 选区保持,事件带新 ImageRun', (
    tester,
  ) async {
    final h = await pump(tester);
    await tapImage(tester);

    h.state.replaceAtomAt('e_0', 1, _img.copyWith(scale: 75), reselect: true);
    await tester.pump();
    await tester.pump();

    expect(h.state.selection!.base.offset, 1);
    expect(h.state.selection!.extent.offset, 2);
    final ev = h.selEvents.last;
    expect(ev, isNotNull);
    expect(ev!.image.scale, 75, reason: '事件携带更新后的 ImageRun');
  });

  testWidgets('点图片行右侧空白 → 落光标,不选图不开查看器', (tester) async {
    final h = await pump(tester);
    // 图矩形右侧远处(同一行的行内空白)
    final imgRect = tester.getRect(
      find.byType(Image, skipOffstage: false).first,
    );
    await tester.tapAt(Offset(imgRect.right + 120, imgRect.center.dy));
    await tester.pump();
    await tester.pump();
    expect(h.state.selection!.isCollapsed, isTrue, reason: '空白处落光标');
    expect(
      h.selEvents.whereType<ImageAtomSelection>(),
      isEmpty,
      reason: '不触发图选中',
    );
    // 再点一次也不能变成"已选中再点"误开查看器
    await tester.tapAt(Offset(imgRect.right + 120, imgRect.center.dy));
    await tester.pump();
    expect(h.openEvents, isEmpty);
  });

  testWidgets('点文字落光标(图原子路由不干扰正常编辑)', (tester) async {
    final h = await pump(tester);
    // 点段首文字位置(远离图片)
    final para = tester.getRect(find.textContaining('前').first);
    await tester.tapAt(para.centerLeft + const Offset(2, 0));
    await tester.pump();
    expect(h.state.selection!.isCollapsed, isTrue, reason: '文字处正常落光标');
  });

  // ---- 网格容器交互(官方 composer 内聚布局) ----

  testWidgets('grid 容器常驻控件:切轮播/移除网格生效', (tester) async {
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: 'x'),
        ),
        const IslandBlock(
          id: 'e_g',
          node: ImageGridNode(
            id: 'b_g',
            images: [
              ImageRun(src: 'upload://1.png', alt: 'a', width: 10, height: 10),
              ImageRun(src: 'upload://2.png', alt: 'b', width: 20, height: 20),
            ],
          ),
        ),
      ],
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FluxdoEditor(state: state, autofocus: true),
          ),
        ),
      ),
    );
    await tester.pump();

    // 官方内聚布局:模式切换/移除网格**常驻**容器内(不依赖选中态)
    expect(find.text('移除网格'), findsOneWidget);
    expect(find.text('轮播'), findsOneWidget);

    // 切轮播:mode 变(容器控件在自管区,选区无关)
    await tester.tap(find.text('轮播'), warnIfMissed: false);
    await tester.pump();
    expect(
      ((state.blocks[1] as IslandBlock).node as ImageGridNode).mode,
      ImageGridMode.carousel,
    );

    // 移除网格:拆成两个图原子段
    await tester.tap(find.text('移除网格'), warnIfMissed: false);
    await tester.pump();
    expect(state.blocks.whereType<IslandBlock>(), isEmpty);
    expect(state.blocks, hasLength(3)); // x + 两图段
    await tester.pump(const Duration(seconds: 1));
  });
}
