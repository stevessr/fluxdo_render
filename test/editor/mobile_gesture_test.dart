/// 移动端手势(设备分流):触摸竖滑=滚动不拖选、长按选词+手柄+动作条、
/// 双击选词、长按图原子=整选、长按岛=不误选邻段。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

Future<(ScrollController, EditorState)> pumpMobile(
  WidgetTester tester, {
  List<String> paragraphs = const ['hello world foo', 'second paragraph here'],
  List<EditorBlock>? blocks,
}) async {
  final state = blocks != null
      ? EditorState(blocks: blocks)
      : EditorState.fromTexts(paragraphs);
  addTearDown(state.dispose);
  final scroll = ScrollController();
  addTearDown(scroll.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          FluxdoEditor(state: state, autofocus: true),
          const SizedBox(height: 2000), // 保证可滚
        ]),
      ),
    ),
  ));
  await tester.pump();
  return (scroll, state);
}

void main() {
  testWidgets('触摸竖滑 = 页面滚动,选区不变(pan 不进竞技场)',
      (tester) async {
    final (scroll, state) = await pumpMobile(tester);
    final before = state.selection;

    final g = await tester.startGesture(
      tester.getCenter(find.byType(FluxdoEditor)),
      kind: PointerDeviceKind.touch,
    );
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();

    expect(scroll.offset, greaterThan(50), reason: '滚动生效');
    expect(state.selection, before, reason: '选区未被拖选劫持');
  });

  testWidgets('长按 = 选词 + 手柄 + 动作条;触摸后收 UI', (tester) async {
    final (_, state) = await pumpMobile(tester);
    // 长按 "world"(首段中间词)
    final para = tester.getRect(find.textContaining('hello').first);
    final target = Offset(para.left + 90, para.center.dy);

    final g = await tester.startGesture(target,
        kind: PointerDeviceKind.touch);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await tester.pump();
    await tester.pump(); // _afterFrame → 手柄/动作条

    final sel = state.selection!;
    expect(sel.isCollapsed, isFalse, reason: '长按选中了词');
    final tb = state.blocks.first as TextBlock;
    final word = tb.content.text.substring(
      sel.base.offset < sel.extent.offset ? sel.base.offset : sel.extent.offset,
      sel.base.offset < sel.extent.offset ? sel.extent.offset : sel.base.offset,
    );
    expect(word.trim(), isNotEmpty);
    expect(word.contains(' '), isFalse, reason: '单词粒度: "$word"');

    // 动作条出现(系统 AdaptiveTextSelectionToolbar)
    expect(find.byType(TextSelectionToolbarTextButton), findsWidgets);

    // 点别处(第二段,远离动作条浮层)落光标 → 触摸选区 UI 收
    final para2 = tester.getRect(find.textContaining('second').first);
    await tester.tapAt(Offset(para2.left + 4, para2.center.dy));
    await tester.pump();
    await tester.pump();
    expect(state.selection!.isCollapsed, isTrue);
  });

  testWidgets('双击(触摸连击)= 选词', (tester) async {
    final (_, state) = await pumpMobile(tester);
    final para = tester.getRect(find.textContaining('hello').first);
    final target = Offset(para.left + 20, para.center.dy);

    await tester.tapAt(target);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(target);
    await tester.pump();

    final sel = state.selection!;
    expect(sel.isCollapsed, isFalse, reason: '双击选词');
  });

  testWidgets('长按图片原子 = 整选(不选词不弹词边界)', (tester) async {
    const img = ImageRun(
        src: 'https://x/a.png', alt: 'a', width: 60, height: 40);
    final (_, state) = await pumpMobile(tester, blocks: [
      TextBlock(
        id: 'e_0',
        content: EditableTextContent.fromInlines(
            const [TextRun('前'), img, TextRun('后')]),
      ),
    ]);

    final imgRect = tester.getRect(find.byType(Image).first);
    final g = await tester.startGesture(imgRect.center,
        kind: PointerDeviceKind.touch);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await tester.pump();

    final sel = state.selection!;
    expect(sel.base.offset, 1);
    expect(sel.extent.offset, 2, reason: '图原子整选');
  });

  testWidgets('长按岛(代码块)= 让路不误选邻段', (tester) async {
    final (_, state) = await pumpMobile(tester, blocks: [
      TextBlock(id: 'e_0', content: EditableTextContent(text: '邻段文字')),
      const IslandBlock(
        id: 'e_isl',
        node: CodeBlockNode(id: 'b_0', code: 'code here', language: 'py'),
      ),
    ]);
    final g = await tester.startGesture(
      tester.getCenter(find.byType(EditorIsland)),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await tester.pump();

    // 岛自己的长按会整选该对象；正文识别器不能误选邻段文字。
    expect(state.selection, const EditorSelection(
      base: EditorPosition(blockId: 'e_isl', offset: 0),
      extent: EditorPosition(blockId: 'e_isl', offset: 1),
    ));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('鼠标拖选不受分流影响(桌面回归)', (tester) async {
    final (scroll, state) = await pumpMobile(tester);
    final para = tester.getRect(find.textContaining('hello').first);

    final g = await tester.startGesture(
      Offset(para.left + 4, para.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 40));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(18, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();

    expect(state.selection!.isCollapsed, isFalse, reason: '鼠标拖选生效');
    expect(scroll.offset, 0, reason: '鼠标拖选不滚动');
  });

  // -----------------------------------------------------------------
  // collapsed 单手柄(光标拖柄)
  // -----------------------------------------------------------------

  testWidgets('长按空白(collapsed)= 出「粘贴 | 全选」动作条', (tester) async {
    final (_, state) = await pumpMobile(tester, paragraphs: ['']);
    final g = await tester.startGesture(
      tester.getCenter(find.byType(FluxdoEditor)),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.up();
    await tester.pump();
    await tester.pump(); // _afterFrame → 动作条

    expect(state.selection!.isCollapsed, isTrue, reason: '空白落光标无选区');
    expect(find.byType(TextSelectionToolbarTextButton), findsWidgets,
        reason: 'collapsed 也出动作条(粘贴入口)');
  });

  testWidgets('普通触摸落光标 = 不出动作条(仅长按空白才出)',
      (tester) async {
    final (_, state) = await pumpMobile(tester);
    final para = tester.getRect(find.textContaining('hello').first);
    await tester.tapAt(Offset(para.left + 20, para.center.dy));
    await tester.pump();
    await tester.pump();
    expect(state.selection!.isCollapsed, isTrue);
    expect(find.byType(TextSelectionToolbarTextButton), findsNothing,
        reason: '普通点击不弹粘贴条');
  });

  testWidgets('触摸落光标 = collapsed 手柄出现;鼠标点击不出', (tester) async {
    final (_, state) = await pumpMobile(tester);
    final para = tester.getRect(find.textContaining('hello').first);
    final target = Offset(para.left + 20, para.center.dy);

    // 触摸 tap(tester.tapAt 默认即 touch)
    await tester.tapAt(target);
    await tester.pump();
    await tester.pump(); // _afterFrame → sync 手柄

    expect(state.selection!.isCollapsed, isTrue);
    expect(find.byKey(kCollapsedHandleKey), findsOneWidget,
        reason: '触摸落光标出单手柄');

    // 鼠标点击另一处(横向远离手柄 44px 命中区 —— 手柄区内的点击
    // 归手柄手势,与系统一致)→ 手柄收
    final para2 = tester.getRect(find.textContaining('second').first);
    final g = await tester.startGesture(
      Offset(para2.left + 160, para2.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await g.up();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(kCollapsedHandleKey), findsNothing,
        reason: '鼠标来源不出手柄');
  });

  testWidgets('拖 collapsed 手柄 = 移光标(不产生范围选区)', (tester) async {
    final (_, state) = await pumpMobile(tester);
    final para = tester.getRect(find.textContaining('hello').first);
    await tester.tapAt(Offset(para.left + 8, para.center.dy));
    await tester.pump();
    await tester.pump();
    final before = state.selection!.extent.offset;

    final handle = tester.getCenter(find.byKey(kCollapsedHandleKey));
    final g = await tester.startGesture(handle, kind: PointerDeviceKind.touch);
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(15, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    await tester.pump();

    final sel = state.selection!;
    expect(sel.isCollapsed, isTrue, reason: '拖单手柄只移光标');
    expect(sel.extent.offset, greaterThan(before), reason: '光标右移');
    expect(find.byKey(kCollapsedHandleKey), findsOneWidget,
        reason: '拖完手柄仍在新光标处');
  });

  testWidgets('物理键盘移光标 = collapsed 手柄收起', (tester) async {
    final (_, state) = await pumpMobile(tester);
    final para = tester.getRect(find.textContaining('hello').first);
    await tester.tapAt(Offset(para.left + 20, para.center.dy));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(kCollapsedHandleKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();

    expect(state.selection!.isCollapsed, isTrue);
    expect(find.byKey(kCollapsedHandleKey), findsNothing,
        reason: '键盘操作收触摸选区 UI');
  });

  testWidgets('拖 collapsed 手柄到视口底缘 = 边缘自动滚', (tester) async {
    final (scroll, state) = await pumpMobile(tester);
    final para = tester.getRect(find.textContaining('second').first);
    await tester.tapAt(Offset(para.left + 8, para.center.dy));
    await tester.pump();
    await tester.pump();

    final handle = tester.getCenter(find.byKey(kCollapsedHandleKey));
    final g = await tester.startGesture(handle, kind: PointerDeviceKind.touch);
    // 拖到视口底缘(600 高视口,进入 56px 边缘带)后按住不动
    final view = tester.view.physicalSize / tester.view.devicePixelRatio;
    await g.moveTo(Offset(handle.dx, view.height - 20));
    await tester.pump(const Duration(milliseconds: 16));
    final offsetAtEdge = scroll.offset;
    // 按住:ticker 每帧滚
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.offset, greaterThan(offsetAtEdge),
        reason: '贴边持续自动滚动');
    await g.up();
    await tester.pump();
    final settled = scroll.offset;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.offset, settled, reason: '松手即停');
    expect(state.selection!.isCollapsed, isTrue);
  });
}
