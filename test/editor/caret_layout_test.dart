import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo_render/src/editor/widget/editor_caret.dart';

void main() {
  testWidgets('自动定位动画期间前置内容缩短，不能停在滚动范围外留下空白', (tester) async {
    final headerHeight = ValueNotifier(5000.0);
    final scroll = ScrollController();
    final state = EditorState(
      blocks: [
        for (var i = 0; i < 40; i++)
          TextBlock(
            id: 'p$i',
            content: EditableTextContent(text: 'paragraph $i'),
          ),
      ],
    );
    addTearDown(headerHeight.dispose);
    addTearDown(scroll.dispose);
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: scroll,
            slivers: [
              SliverToBoxAdapter(
                child: ValueListenableBuilder(
                  valueListenable: headerHeight,
                  builder: (_, height, _) => SizedBox(height: height),
                ),
              ),
              SliverToBoxAdapter(
                child: FluxdoEditor(state: state, autofocus: true),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.offset, greaterThan(2000));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    // 编辑器内部的光标坐标不变，仅外部前置内容高度变化。
    headerHeight.value = 100;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      scroll.position.outOfRange,
      isFalse,
      reason:
          '动画提前结束也必须回到新的有效范围 ${scroll.offset}/${scroll.position.maxScrollExtent}',
    );
    final tail = tester.getRect(find.text('paragraph 39', skipOffstage: false));
    expect(tail.overlaps(const Rect.fromLTWH(0, 0, 800, 600)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final height in [100.0, 1600.0]) {
    testWidgets('媒体高度异步变为 $height 后光标仍跟随末段', (tester) async {
      final imageHeight = ValueNotifier(800.0);
      final scroll = ScrollController();
      final state = EditorState(
        blocks: [
          TextBlock(
            id: 'image',
            content: EditableTextContent.fromInlines(const [
              ImageRun(src: 'test', width: 300, height: 800),
            ]),
          ),
          TextBlock(
            id: 'tail',
            content: EditableTextContent(text: 'document tail'),
          ),
        ],
      );
      addTearDown(imageHeight.dispose);
      addTearDown(scroll.dispose);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: FluxdoEditor(
                state: state,
                autofocus: true,
                nodeFactory: NodeFactory(
                  imageContentBuilder: (_, _, _) => ValueListenableBuilder(
                    valueListenable: imageHeight,
                    builder: (_, value, _) =>
                        SizedBox(width: 300, height: value),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      imageHeight.value = height;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final tail = tester.getRect(find.text('document tail'));
      final caret = tester.getRect(find.byType(EditorCaret));
      expect(caret.top, closeTo(tail.top, 1));
      expect(tail.bottom, lessThanOrEqualTo(600));
      expect(tail.top, greaterThanOrEqualTo(0));

      // 用户主动滚离后，媒体后续布局变化不能把视口拉回末尾。
      if (height > 600) {
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, 250),
        );
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final before = scroll.offset;
        imageHeight.value += 100;
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(scroll.offset, before);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
