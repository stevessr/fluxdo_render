import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

Future<(EditorState, ScrollController)> pumpEditor(WidgetTester tester) async {
  final state = EditorState(
    blocks: [
      const IslandBlock(
        id: 'grid',
        node: ImageGridNode(id: 'grid-node', images: []),
      ),
      for (var i = 0; i < 50; i++)
        TextBlock(
          id: 'p$i',
          content: EditableTextContent(text: 'paragraph $i hello world'),
        ),
    ],
  );
  final scroll = ScrollController();
  addTearDown(state.dispose);
  addTearDown(scroll.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          controller: scroll,
          child: FluxdoEditor(
            state: state,
            autofocus: true,
            showTrailingParagraph: true,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  scroll.jumpTo(0);
  await tester.pump();
  return (state, scroll);
}

void main() {
  testWidgets('触控板双指滚动不改变选区', (tester) async {
    final (state, scroll) = await pumpEditor(tester);
    final before = state.selection;
    final point = tester.getCenter(find.text('paragraph 5 hello world'));
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(point);
    await gesture.panZoomUpdate(point, pan: const Offset(35, -2));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 8; i++) {
      await gesture.panZoomUpdate(point, pan: Offset(35, -30.0 * i));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.panZoomEnd();
    await tester.pump();
    expect(state.selection, before);
    expect(scroll.offset, greaterThan(100));
  });

  testWidgets('触摸停顿后开始滚动不提前落光标或唤起输入', (tester) async {
    final (state, scroll) = await pumpEditor(tester);
    final before = state.selection;
    final point = tester.getCenter(find.text('paragraph 5 hello world'));
    tester.testTextInput.log.clear();
    final gesture = await tester.startGesture(point);
    await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
    expect(state.selection, before, reason: '尚未确认点击，不应改变光标');
    expect(
      tester.testTextInput.log.where((call) => call.method == 'TextInput.show'),
      isEmpty,
    );
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
    expect(state.selection, before);
    expect(scroll.offset, greaterThan(100));
  });

  testWidgets('取消的触摸不计入双击，随后单击正常落光标', (tester) async {
    final (state, _) = await pumpEditor(tester);
    final before = state.selection;
    final point =
        tester.getTopLeft(find.text('paragraph 5 hello world')) +
        const Offset(30, 10);
    final gesture = await tester.startGesture(point);
    await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
    await gesture.cancel();
    expect(state.selection, before);
    await tester.tapAt(point);
    await tester.pump();
    expect(state.selection!.isCollapsed, isTrue);
    expect(state.selection!.extent.blockId, 'p5');
  });
}
