import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

const images = [
  ImageRun(src: 'a', width: 100, height: 80),
  ImageRun(src: 'b', width: 100, height: 80),
  ImageRun(src: 'c', width: 100, height: 80),
];

Future<EditorState> pumpGrid(
  WidgetTester tester, {
  bool desktop = true,
  bool twoGroups = false,
  int imageCount = 3,
  double height = 900,
  FluxdoEditorContentActions? actions,
  ValueChanged<EditorObjectMenuRequest>? onMenu,
  ValueChanged<GridImageSelection>? onOpen,
  ValueChanged<String>? onAdd,
  List<Widget> Function(BuildContext, String)? pendingBuilder,
}) async {
  tester.view.physicalSize = Size(desktop ? 1000 : 390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = EditorState(
    blocks: [
      IslandBlock(
        id: 'grid',
        node: ImageGridNode(id: 'g', images: images.take(imageCount).toList()),
      ),
      if (twoGroups)
        const IslandBlock(
          id: 'other',
          node: ImageGridNode(id: 'other-node', images: images),
        ),
      TextBlock(
        id: 'text',
        content: EditableTextContent(text: '后面的正文'),
      ),
    ],
  );
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: desktop ? TargetPlatform.macOS : TargetPlatform.android,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: FluxdoEditor(
            state: state,
            contentActions: actions,
            objectToolbarManaged: true,
            onObjectMenuRequested: onMenu,
            onGridImageOpenRequest: onOpen,
            onAddGridImages: onAdd,
            gridPendingUploadsBuilder: pendingBuilder,
            nodeFactory: NodeFactory(
              imageContentBuilder: (_, image, total) => SizedBox(
                width: 100,
                height: 80,
                child: ColoredBox(
                  color: Colors.blueGrey,
                  child: Center(child: Text(image.src)),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return state;
}

EditorImageGridState gridState(WidgetTester tester, [String id = 'grid']) =>
    tester.state<EditorImageGridState>(
      find.byWidgetPredicate((w) => w is EditorImageGrid && w.islandId == id),
    );
List<String> order(EditorState state, [String id = 'grid']) =>
    ((state.blocks.firstWhere((b) => b.id == id) as IslandBlock).node
            as ImageGridNode)
        .images
        .map((i) => i.src)
        .toList();

void main() {
  testWidgets('待上传瓦片只显示在目标网格内部且不进入正文导出', (tester) async {
    final state = await pumpGrid(tester, twoGroups: true, onAdd: (_) {},
      pendingBuilder: (context, id) => id == 'grid'
        ? [const ColoredBox(key: ValueKey('pending-upload'), color: Colors.blue)] : []);
    expect(find.byKey(const ValueKey('pending-upload')), findsOneWidget);
    expect(state.exportMarkdown(), isNot(contains('pending-upload')));
    final rect = tester.getRect(find.byKey(const ValueKey('pending-upload')));
    expect(rect.width, greaterThan(0));
    expect(rect.width, rect.height);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选中网格图片保留键盘但清空输入目标，点回正文后正常输入', (tester) async {
    final actions = FluxdoEditorContentActions();
    final state = await pumpGrid(tester, actions: actions);
    await tester.tap(find.text('后面的正文'), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    actions.selectObject(const EditorGridImageTarget('grid', 0, 'a'));
    await tester.pump();
    expect(state.selection, isNull);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    final before = state.blocks;
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' 迟到的输入',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    expect(state.blocks, before);
    expect(state.selection, isNull);
    await tester.tap(find.text('后面的正文'), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' 后面的正文继续',
        selection: TextSelection.collapsed(offset: 8),
      ),
    );
    await tester.pump();
    expect(state.textBlockById('text')!.content.text, '后面的正文继续');
    expect(order(state), ['a', 'b', 'c']);
    state.undo();
    await tester.pump();
    expect(state.textBlockById('text')!.content.text, '后面的正文');
  });

  testWidgets('图片操作按钮按下后轻微移动不应启动图片拖拽', (tester) async {
    final menus = <EditorObjectMenuRequest>[];
    final state = await pumpGrid(tester, onMenu: menus.add);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(gridState(tester).selectionFor(0)!.globalRect.center);
    await tester.pump();
    final button = find.byKey(const ValueKey('grid-image-more-grid-0'));
    final point = tester.getCenter(button);
    await mouse.down(point);
    await mouse.moveTo(point + const Offset(3, 2));
    await tester.pump();
    expect(find.text('a'), findsOneWidget, reason: '不应生成图片拖拽预览');
    await mouse.up();
    await tester.pump();
    expect(menus, hasLength(1));
    expect(order(state), ['a', 'b', 'c']);
    await mouse.removePointer();
  });

  for (final change in ['mode', 'add', 'remove', 'resize', 'drag']) {
    testWidgets('悬浮提示显示时改变图片网格结构不能在布局中重挂浮层 $change', (tester) async {
      final state = await pumpGrid(
        tester,
        imageCount: change == 'add'
            ? 1
            : change == 'remove'
            ? 2
            : 3,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.moveTo(gridState(tester).selectionFor(0)!.globalRect.center);
      await tester.pump();
      final more = find.byKey(const ValueKey('grid-image-more-grid-0'));
      await mouse.moveTo(tester.getCenter(more));
      await tester.pump(const Duration(seconds: 1));
      final tooltip = find.descendant(of: more, matching: find.byType(Tooltip));
      tester.state<TooltipState>(tooltip).ensureTooltipVisible();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('图片操作'), findsOneWidget);
      final originalButton = tester.element(more);
      if (change == 'mode') {
        setImageGridMode(state, 'grid', ImageGridMode.carousel);
      } else if (change == 'add') {
        appendImagesToGrid(state, 'grid', [images[1]]);
      } else if (change == 'remove') {
        removeImageFromGrid(state, 'grid', 1);
      } else if (change == 'resize') {
        tester.view.physicalSize = const Size(400, 900);
      } else {
        await mouse.down(gridState(tester).selectionFor(0)!.globalRect.center);
        await mouse.moveBy(const Offset(30, 20));
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      if (change == 'drag') {
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('图片操作'), findsNothing, reason: '隐藏的按钮不能留下无法退场的提示浮层');
        await mouse.cancel();
      } else {
        expect(
          tester.element(more),
          same(originalButton),
          reason: '只改变布局，不搬迁或重建操作按钮',
        );
        if (change == 'mode') {
          setImageGridMode(state, 'grid', ImageGridMode.grid);
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(tester.element(more), same(originalButton));
        }
      }
      await mouse.removePointer();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('管理模式也有模式切换、添加入口和悬停单图操作', (tester) async {
    final menus = <EditorObjectMenuRequest>[];
    final opens = <GridImageSelection>[];
    final adds = <String>[];
    final state = await pumpGrid(
      tester,
      onMenu: menus.add,
      onOpen: opens.add,
      onAdd: adds.add,
    );
    expect(find.text('网格'), findsOneWidget);
    expect(find.text('轮播'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final selection = state.selection;
    await mouse.moveTo(gridState(tester).selectionFor(0)!.globalRect.center);
    await tester.pump();
    expect(state.selection, selection);
    final more = find.byKey(const ValueKey('grid-image-more-grid-0'));
    expect(more.hitTestable(), findsOneWidget);
    final anchor = tester.getRect(more);
    await tester.tap(more, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(menus.single.target, const EditorGridImageTarget('grid', 0, 'a'));
    expect(menus.single.globalAnchorRect, anchor);
    await tester.tap(find.byKey(const ValueKey('grid-image-view-grid-0')));
    expect(opens.single.image.src, 'a');
    await tester.tap(find.byKey(const ValueKey('grid-add-grid')));
    await tester.tap(find.byKey(const ValueKey('grid-add-tile-grid')));
    expect(adds, ['grid', 'grid']);
    await tester.tap(find.text('轮播'));
    await tester.pump();
    await tester.pump();
    expect((state.blocks.first as IslandBlock).node, isA<ImageGridNode>());
    expect(
      ((state.blocks.first as IslandBlock).node as ImageGridNode).mode,
      ImageGridMode.carousel,
    );
    expect(find.byKey(const ValueKey('grid-viewport-grid')), findsOneWidget);
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('grid-viewport-grid')),
          )
          .physics,
      isA<ClampingScrollPhysics>(),
    );
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('鼠标无需长按即可按落点前后排序，撤销后仍选中原图', (tester) async {
    final actions = FluxdoEditorContentActions();
    final state = await pumpGrid(tester, actions: actions);
    final start = gridState(tester).selectionFor(0)!.globalRect.center;
    final target = gridState(tester).selectionFor(2)!.globalRect;
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 20));
    await mouse.moveBy(const Offset(24, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await mouse.moveTo(Offset(target.right - 12, target.center.dy));
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('grid-drop-grid-2')), findsOneWidget);
    await mouse.up();
    await tester.pump();
    await tester.pump();
    expect(order(state), ['b', 'c', 'a']);
    expect(
      actions.objectSelection!.target,
      const EditorGridImageTarget('grid', 2, 'a'),
    );
    state.undo();
    await tester.pump();
    await tester.pump();
    expect(order(state), ['a', 'b', 'c']);
    expect(
      actions.objectSelection!.target,
      const EditorGridImageTarget('grid', 0, 'a'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('图片不能因跨组拖放而误排另一个网格', (tester) async {
    final state = await pumpGrid(tester, twoGroups: true);
    final mouse = await tester.startGesture(
      gridState(tester).selectionFor(0)!.globalRect.center,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(24, 0));
    await tester.pump();
    await mouse.moveTo(
      gridState(tester, 'other').selectionFor(2)!.globalRect.center,
    );
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(order(state), ['a', 'b', 'c']);
    expect(order(state, 'other'), ['a', 'b', 'c']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面轮播拖至边缘可自动滚动，取消拖动不改变顺序', (tester) async {
    final state = await pumpGrid(tester);
    appendImagesToGrid(state, 'grid', [
      for (var i = 0; i < 5; i++) ImageRun(src: 'extra-$i'),
    ]);
    setImageGridMode(state, 'grid', ImageGridMode.carousel);
    await tester.pump();
    await tester.pump();
    final original = order(state);
    final carousel = find.byKey(const ValueKey('grid-viewport-grid'));
    final viewport = tester.getRect(carousel);
    final scroll = tester
        .state<ScrollableState>(
          find
              .descendant(of: carousel, matching: find.byType(Scrollable))
              .first,
        )
        .position;
    final mouse = await tester.startGesture(
      gridState(tester).selectionFor(0)!.globalRect.center,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(24, 0));
    await tester.pump();
    await mouse.moveTo(Offset(viewport.right - 6, viewport.center.dy));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(scroll.pixels, greaterThan(0));
    await mouse.cancel();
    await tester.pump(const Duration(milliseconds: 400));
    expect(order(state), original);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('触摸未长按时竖向滑动仍滚动页面，不触发排序', (tester) async {
    final state = await pumpGrid(tester, desktop: false, height: 360);
    final start = gridState(tester).selectionFor(0)!.globalRect.center;
    final touch = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 80));
    await touch.moveBy(const Offset(0, -45));
    await tester.pump(const Duration(milliseconds: 16));
    await touch.moveBy(const Offset(0, -45));
    await tester.pump();
    await touch.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(order(state), ['a', 'b', 'c']);
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(scroll.pixels, greaterThan(0));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('触摸点选可开单图菜单，长按才进入排序', (tester) async {
    final menus = <EditorObjectMenuRequest>[];
    final state = await pumpGrid(tester, desktop: false, onMenu: menus.add);
    final start = gridState(tester).selectionFor(0)!.globalRect.center;
    expect(
      gridState(tester).selectionFor(1)!.globalRect.top,
      closeTo(gridState(tester).selectionFor(0)!.globalRect.top, .1),
      reason: '手机两张缩略图应能并排',
    );
    await tester.tapAt(start);
    await tester.pump();
    await tester.pump();
    final more = find.byKey(const ValueKey('grid-image-more-grid-0'));
    expect(more.hitTestable(), findsOneWidget);
    await tester.tap(more);
    await tester.pump();
    expect(menus.single.target, const EditorGridImageTarget('grid', 0, 'a'));
    final target = gridState(tester).selectionFor(1)!.globalRect;
    final touch = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 320));
    await touch.moveTo(Offset(target.right - 8, target.center.dy));
    await tester.pump();
    await touch.up();
    await tester.pump();
    await tester.pump();
    expect(order(state), ['b', 'a', 'c']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
