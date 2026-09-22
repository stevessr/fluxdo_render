/// iOS 浮动光标(长按空格 trackpad 模式):平台 Start/Update/End 报文
/// → 幽灵光标 overlay 跟手 + 实光标就近吸附 + End 收尾。
/// 报文经真实 textinput channel 回放(与 engine 编码一致)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo_render/src/editor/widget/editor_caret.dart';

Future<EditorState> pumpEditor(WidgetTester tester) async {
  final state = EditorState.fromTexts(['hello world foo bar baz']);
  addTearDown(state.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: FluxdoEditor(state: state, autofocus: true)),
  ));
  await tester.pump();
  // 触摸落光标到行首附近
  final para = tester.getRect(find.textContaining('hello').first);
  await tester.tapAt(Offset(para.left + 4, para.center.dy));
  await tester.pump();
  await tester.pump();
  return state;
}

/// 当前 IME 连接的 client id(engine 报文第一参数,必须匹配才会分发)。
int clientId(WidgetTester tester) {
  int? id;
  for (final call in tester.testTextInput.log) {
    if (call.method == 'TextInput.setClient') {
      id = (call.arguments as List)[0] as int;
    }
  }
  expect(id, isNotNull, reason: '编辑器已 attach IME');
  return id!;
}

/// 回放平台浮动光标报文([state] = start/update/end,engine 编码同款)。
Future<void> sendFloating(
  WidgetTester tester,
  String state, {
  Offset offset = Offset.zero,
}) async {
  final call = MethodCall('TextInputClient.updateFloatingCursor', [
    clientId(tester),
    'FloatingCursorDragState.$state',
    {'X': offset.dx, 'Y': offset.dy},
  ]);
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(call),
    (_) {},
  );
  await tester.pump();
}

void main() {
  testWidgets('Start 出幽灵 → Update 吸附移光标 → End 收幽灵留光标',
      (tester) async {
    final state = await pumpEditor(tester);
    final before = state.selection!.extent.offset;

    await sendFloating(tester, 'start');
    expect(find.byKey(kFloatingCursorGhostKey), findsOneWidget,
        reason: 'Start 出浮动幽灵');
    final theme = Theme.of(tester.element(find.byType(FluxdoEditor)));
    final caretDim = tester.widget<EditorCaret>(find.byType(EditorCaret));
    expect(caretDim.color, theme.colorScheme.outline,
        reason: '浮动期间实光标灰化残影');
    expect(caretDim.alwaysVisible, isTrue, reason: '残影常亮不闪');
    final ghostBefore =
        tester.getTopLeft(find.byKey(kFloatingCursorGhostKey));

    await sendFloating(tester, 'update', offset: const Offset(150, 0));
    final ghostAfter =
        tester.getTopLeft(find.byKey(kFloatingCursorGhostKey));
    expect(ghostAfter.dx, greaterThan(ghostBefore.dx),
        reason: '幽灵跟手右移');
    final mid = state.selection!.extent.offset;
    expect(mid, greaterThan(before), reason: '实光标就近吸附右移');
    expect(state.selection!.isCollapsed, isTrue);

    await sendFloating(tester, 'end');
    expect(find.byKey(kFloatingCursorGhostKey), findsNothing,
        reason: 'End 收幽灵');
    expect(state.selection!.extent.offset, mid, reason: '光标保持吸附位');
    final caretBack = tester.widget<EditorCaret>(find.byType(EditorCaret));
    expect(caretBack.color, theme.colorScheme.primary,
        reason: 'End 恢复主题色');
  });

  testWidgets('Update 越界钳到视口(不飘出屏幕)', (tester) async {
    await pumpEditor(tester);
    await sendFloating(tester, 'start');
    await sendFloating(tester, 'update', offset: const Offset(9999, 9999));
    final ghost = tester.getRect(find.byKey(kFloatingCursorGhostKey));
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(ghost.right, lessThanOrEqualTo(view.width));
    expect(ghost.bottom, lessThanOrEqualTo(view.height));
    await sendFloating(tester, 'end');
  });

  for (final useVirtualPointer in [false, true]) {
    testWidgets('${useVirtualPointer ? '虚拟' : '平台浮动'}光标限制在正文区域，不进入标题和留白',
        (tester) async {
      final state = EditorState.fromTexts(['hello world foo bar baz']);
      addTearDown(state.dispose);
      final pointer = FluxdoEditorVirtualPointer();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 100),
                Padding(
                  padding: const EdgeInsets.fromLTRB(80, 12, 60, 24),
                  child: SizedBox(
                    height: 240,
                    child: FluxdoEditor(
                      state: state,
                      autofocus: true,
                      virtualPointer: pointer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      final paragraph = tester.getRect(find.textContaining('hello').first);
      await tester.tapAt(Offset(paragraph.left + 4, paragraph.center.dy));
      await tester.pump();
      await tester.pump();
      final content = tester.getRect(find.byType(FluxdoEditor));

      if (useVirtualPointer) {
        expect(pointer.start(), isTrue);
        await tester.pump();
      } else {
        await sendFloating(tester, 'start');
      }
      final startGhost = tester.getRect(find.byKey(kFloatingCursorGhostKey));
      expect(startGhost.left, greaterThanOrEqualTo(content.left));
      expect(startGhost.top, greaterThanOrEqualTo(content.top));

      if (useVirtualPointer) {
        pointer.moveBy(const Offset(9999, 9999));
        await tester.pump();
      } else {
        await sendFloating(tester, 'update', offset: const Offset(9999, 9999));
      }
      final bottomRight = tester.getRect(find.byKey(kFloatingCursorGhostKey));
      expect(bottomRight.right, closeTo(content.right, 0.01));
      expect(bottomRight.bottom, closeTo(content.bottom, 0.01));

      if (useVirtualPointer) {
        pointer.moveBy(const Offset(-19998, -19998));
        await tester.pump();
      } else {
        await sendFloating(tester, 'update', offset: const Offset(-9999, -9999));
      }
      final topLeft = tester.getRect(find.byKey(kFloatingCursorGhostKey));
      expect(topLeft.left, closeTo(content.left, 0.01));
      expect(topLeft.top, closeTo(content.top, 0.01));
      if (useVirtualPointer) {
        pointer.end();
        await tester.pump();
      } else {
        await sendFloating(tester, 'end');
      }
    });
  }

  testWidgets('行首起步时幽灵本体也不能伸出正文左边缘', (tester) async {
    final state = await pumpEditor(tester);
    state.updateSelection(EditorSelection.collapsed(
      EditorPosition(blockId: state.selection!.extent.blockId, offset: 0),
    ));
    await tester.pump();
    final content = tester.getRect(find.byType(FluxdoEditor));
    await sendFloating(tester, 'start');
    final ghost = tester.getRect(find.byKey(kFloatingCursorGhostKey));
    expect(ghost.left, closeTo(content.left, 0.01));
    expect(ghost.top, greaterThanOrEqualTo(content.top));
    await sendFloating(tester, 'end');
  });

  testWidgets('虚拟光标越过下边界后反向立即上移，不积攒越界位移', (tester) async {
    final pointer = FluxdoEditorVirtualPointer();
    final state = EditorState.fromTexts(['hello world']);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FluxdoEditor(state: state, virtualPointer: pointer)),
    ));
    await tester.pump();
    expect(pointer.start(), isTrue);
    pointer.moveBy(const Offset(0, 5000));
    await tester.pump();
    final bottom = tester.getCenter(find.byKey(kFloatingCursorGhostKey));
    pointer.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(tester.getCenter(find.byKey(kFloatingCursorGhostKey)).dy,
        closeTo(bottom.dy - 20, 0.01));
    pointer.moveBy(const Offset(0, -5000));
    await tester.pump();
    final top = tester.getCenter(find.byKey(kFloatingCursorGhostKey));
    pointer.moveBy(const Offset(0, 5));
    await tester.pump();
    expect(tester.getCenter(find.byKey(kFloatingCursorGhostKey)).dy,
        closeTo(top.dy + 5, 0.01));
    pointer.end();
    await tester.pump();
  });

  testWidgets('平台浮动光标贴边后小幅反向也立即移动', (tester) async {
    await pumpEditor(tester);
    await sendFloating(tester, 'start');
    await sendFloating(tester, 'update', offset: const Offset(5000, 5000));
    final edge = tester.getCenter(find.byKey(kFloatingCursorGhostKey));
    await sendFloating(tester, 'update', offset: const Offset(4995, 4995));
    expect(tester.getCenter(find.byKey(kFloatingCursorGhostKey)),
        edge - const Offset(5, 5));
    await sendFloating(tester, 'end');
  });

  testWidgets('高图下方向上贴边自动滚动，可以越过图片到上一段', (tester) async {
    final pointer = FluxdoEditorVirtualPointer();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final state = EditorState(blocks: [
      TextBlock(id: 'above', content: EditableTextContent(text: 'above image')),
      TextBlock(id: 'image', content: EditableTextContent.fromInlines(const [
        ImageRun(src: 'https://example.com/tall.png', width: 240, height: 800),
      ])),
      TextBlock(id: 'below', content: EditableTextContent(text: 'below image')),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(
        width: 320,
        height: 240,
        child: SingleChildScrollView(
          controller: scroll,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FluxdoEditor(state: state, virtualPointer: pointer),
          ),
        ),
      ))),
    ));
    await tester.pump();
    scroll.jumpTo(scroll.position.maxScrollExtent);
    state.updateSelection(const EditorSelection.collapsed(
      EditorPosition(blockId: 'below', offset: 0),
    ));
    await tester.pump();
    expect(pointer.start(), isTrue);
    pointer.moveBy(const Offset(0, -5000));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.offset, closeTo(0, 0.01));
    expect(state.selection!.extent.blockId, 'above');
    pointer.end();
    await tester.pump();
  });

  testWidgets('范围选区时 Start 忽略(不出幽灵不炸)', (tester) async {
    final state = await pumpEditor(tester);
    state.selectAll();
    await tester.pump();
    await sendFloating(tester, 'start');
    expect(find.byKey(kFloatingCursorGhostKey), findsNothing);
    await sendFloating(tester, 'update', offset: const Offset(50, 0));
    await sendFloating(tester, 'end');
    expect(state.selection!.isCollapsed, isFalse, reason: '选区未被破坏');
  });

  testWidgets('浮动拖到视口底缘 = 边缘自动滚;End 即停', (tester) async {
    final state = EditorState.fromTexts(
      [for (var i = 0; i < 40; i++) 'paragraph line $i text'],
    );
    addTearDown(state.dispose);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.fromLTRB(40, 80, 40, 100),
          child: SingleChildScrollView(
            controller: scroll,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: FluxdoEditor(state: state, autofocus: true),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    final para = tester.getRect(find.textContaining('line 0').first);
    await tester.tapAt(Offset(para.left + 4, para.center.dy));
    await tester.pump();
    await tester.pump();

    await sendFloating(tester, 'start');
    // 大幅向下:钳到视口底缘(56px 边缘带内)→ ticker 每帧滚
    await sendFloating(tester, 'update', offset: const Offset(0, 5000));
    final ghost = tester.getRect(find.byKey(kFloatingCursorGhostKey));
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    expect(ghost.bottom, closeTo(viewport.bottom, 0.01),
        reason: '长文按正文与视口交集限位，不落到屏幕底部');
    final atEdge = scroll.offset;
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.offset, greaterThan(atEdge), reason: '贴底持续自动滚');
    expect(state.selection!.isCollapsed, isTrue);

    await sendFloating(tester, 'end');
    expect(find.byKey(kFloatingCursorGhostKey), findsNothing);
    final settled = scroll.offset;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.offset, settled, reason: 'End 即停');
  });

  testWidgets('虚拟指针:start/moveBy 二维漂移吸附,end 收幽灵', (tester) async {
    final vp = FluxdoEditorVirtualPointer();
    final state = EditorState.fromTexts(
        ['first line of text here', 'second line target words']);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(
            state: state, autofocus: true, virtualPointer: vp),
      ),
    ));
    await tester.pump();
    final para = tester.getRect(find.textContaining('first').first);
    await tester.tapAt(Offset(para.left + 4, para.center.dy));
    await tester.pump();
    await tester.pump();
    final startBlock = state.selection!.extent.blockId;

    expect(vp.start(), isTrue);
    await tester.pump();
    expect(find.byKey(kFloatingCursorGhostKey), findsOneWidget);
    // 向右下漂(跨到第二段)
    vp.moveBy(const Offset(60, 0));
    vp.moveBy(Offset(0, para.height + 8));
    await tester.pump();
    final sel = state.selection!;
    expect(sel.isCollapsed, isTrue);
    expect(sel.extent.blockId, isNot(startBlock), reason: '跨段吸附');
    vp.end();
    await tester.pump();
    expect(find.byKey(kFloatingCursorGhostKey), findsNothing);
    expect(vp.isActive, isFalse);
  });

  testWidgets('虚拟指针扩选:base 固定,extent 随指针', (tester) async {
    final vp = FluxdoEditorVirtualPointer();
    final state = EditorState.fromTexts(['hello world foo bar']);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(
            state: state, autofocus: true, virtualPointer: vp),
      ),
    ));
    await tester.pump();
    final para = tester.getRect(find.textContaining('hello').first);
    await tester.tapAt(Offset(para.left + 4, para.center.dy));
    await tester.pump();
    await tester.pump();
    final base = state.selection!.base;

    expect(vp.start(extend: true), isTrue);
    vp.moveBy(const Offset(80, 0));
    await tester.pump();
    final sel = state.selection!;
    expect(sel.isCollapsed, isFalse, reason: '扩出范围选区');
    expect(sel.base, base, reason: 'base 固定');
    expect(sel.extent.offset, greaterThan(base.offset));
    vp.end();
    await tester.pump();
    expect(state.selection!.isCollapsed, isFalse, reason: '选区保留');
  });

  testWidgets('无光标时 start 自动落文末起步(随时可用)', (tester) async {
    final vp = FluxdoEditorVirtualPointer();
    final state = EditorState.fromTexts(['abc']);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(state: state, virtualPointer: vp),
      ),
    ));
    await tester.pump();
    expect(state.selection, isNull, reason: '未聚焦未点击,无光标前置');

    expect(vp.start(), isTrue, reason: '自动落文末起步');
    final sel = state.selection!;
    expect(sel.isCollapsed, isTrue);
    expect(sel.extent.offset, 3, reason: '落在文末');
    vp.moveBy(const Offset(-40, 0));
    await tester.pump();
    vp.end();
    await tester.pump();
    expect(find.byKey(kFloatingCursorGhostKey), findsNothing);
  });

  testWidgets('虚拟光标拖过网格图片块不失焦:吸附岛外邻块并可继续拖出',
      (tester) async {
    final vp = FluxdoEditorVirtualPointer();
    final state = EditorState(blocks: [
      TextBlock(id: 'above', content: EditableTextContent(text: 'above the grid')),
      const IslandBlock(
        id: 'grid',
        node: ImageGridNode(id: 'g0', images: [
          ImageRun(src: 'https://example.com/a.png', width: 120, height: 90),
          ImageRun(src: 'https://example.com/b.png', width: 120, height: 90),
        ]),
      ),
      TextBlock(id: 'below', content: EditableTextContent(text: 'below the grid')),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            height: 480,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FluxdoEditor(state: state, virtualPointer: vp),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    final above = tester.getRect(find.textContaining('above').first);
    final below = tester.getRect(find.textContaining('below').first);
    expect(below.top, greaterThan(above.bottom), reason: '前置:岛在两段之间');

    state.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: 'above', offset: 5)),
    );
    await tester.pump();
    expect(vp.start(), isTrue);
    await tester.pump();

    // 拖进岛正中(above.bottom 与 below.top 之间)
    var ghost = tester.getCenter(find.byKey(kFloatingCursorGhostKey));
    final islandMid = Offset(above.center.dx, (above.bottom + below.top) / 2);
    vp.moveBy(islandMid - ghost);
    await tester.pump();
    expect(
      state.selection!.extent.blockId,
      anyOf('above', 'below'),
      reason: '岛不是光标可停位,命中解析到岛外邻块(不失焦)',
    );
    expect(state.selection!.isCollapsed, isTrue);
    expect(find.byKey(kFloatingCursorGhostKey), findsOneWidget,
        reason: '会话不中断');

    // 继续拖到 below → 落到 below(拖出能力)
    ghost = tester.getCenter(find.byKey(kFloatingCursorGhostKey));
    vp.moveBy(below.center - ghost);
    await tester.pump();
    expect(state.selection!.extent.blockId, 'below');
    vp.end();
    await tester.pump();
    expect(find.byKey(kFloatingCursorGhostKey), findsNothing);
  });

  testWidgets('光标驻留岛位时 start 仍可起步拖出(对象边缘兜底)', (tester) async {
    final vp = FluxdoEditorVirtualPointer();
    final state = EditorState(blocks: [
      TextBlock(id: 'p0', content: EditableTextContent(text: 'before island')),
      const IslandBlock(
        id: 'grid',
        node: ImageGridNode(id: 'g0', images: [
          ImageRun(src: 'https://example.com/a.png', width: 120, height: 90),
        ]),
      ),
      TextBlock(id: 'p1', content: EditableTextContent(text: 'after island')),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(state: state, virtualPointer: vp),
      ),
    ));
    await tester.pump();
    // 模拟历史遗留态:光标 collapsed 在岛位(无文本 caret)
    state.updateSelection(
      const EditorSelection.collapsed(EditorPosition(blockId: 'grid', offset: 1)),
    );
    await tester.pump();

    expect(vp.start(), isTrue, reason: '岛位不再是失焦死角');
    await tester.pump();
    expect(find.byKey(kFloatingCursorGhostKey), findsOneWidget);
    vp.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(
      state.selection!.extent.blockId,
      anyOf('p0', 'p1'),
      reason: '拖动即回到文本位',
    );
    vp.end();
    await tester.pump();
  });

  testWidgets('岛整选态(点过表格/图集后)start 折叠到 extent 起步', (tester) async {
    final vp = FluxdoEditorVirtualPointer();
    final state = EditorState(blocks: [
      TextBlock(id: 'p0', content: EditableTextContent(text: 'before island')),
      const IslandBlock(
        id: 'grid',
        node: ImageGridNode(id: 'g0', images: [
          ImageRun(src: 'https://example.com/a.png', width: 120, height: 90),
        ]),
      ),
      TextBlock(id: 'p1', content: EditableTextContent(text: 'after island')),
    ]);
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(state: state, virtualPointer: vp),
      ),
    ));
    await tester.pump();
    // 模拟点击 table/图集后的整选态(非 collapsed,端点在岛上)
    state.updateSelection(const EditorSelection(
      base: EditorPosition(blockId: 'grid', offset: 0),
      extent: EditorPosition(blockId: 'grid', offset: 1),
    ));
    await tester.pump();

    expect(vp.start(), isTrue, reason: '整选态不再永久失灵');
    await tester.pump();
    expect(find.byKey(kFloatingCursorGhostKey), findsOneWidget);
    final sel = state.selection!;
    expect(sel.isCollapsed, isTrue, reason: '整选折叠起步,不再非折叠拒启动');
    expect(sel.extent.blockId, isNot('grid'), reason: '锚定到可停位,不驻留岛位');
    vp.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(
      state.selection!.extent.blockId,
      anyOf('p0', 'p1'),
      reason: '拖动落文本位',
    );
    vp.end();
    await tester.pump();
  });
}
