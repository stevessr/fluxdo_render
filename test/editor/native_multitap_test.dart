import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/widget/editable_paragraph.dart';

const paragraphs = ['alpha beta gamma', 'second delta epsilon', 'tail'];
const style = TextStyle(fontSize: 14, height: 1.5);

class Harness {
  Harness(this.tester, this.native, this.state, this.controller);
  final WidgetTester tester;
  final bool native;
  final EditorState state;
  final TextEditingController controller;

  int linear(EditorPosition p) {
    var offset = p.offset;
    for (final b in state.blocks) {
      if (b.id == p.blockId) break;
      offset += b.selectionLength + 1;
    }
    return offset;
  }

  TextSelection get selection {
    if (native) return controller.selection;
    final s = state.selection!;
    return TextSelection(
      baseOffset: linear(s.base),
      extentOffset: linear(s.extent),
    );
  }

  Offset point(int block, int offset, {bool blank = false}) {
    if (native) {
      final render = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      var index = offset;
      for (var i = 0; i < block; i++) {
        index += (state.blocks[i] as TextBlock).content.length + 1;
      }
      final rect = render.getLocalRectForCaret(TextPosition(offset: index));
      return render.localToGlobal(
        Offset(blank ? 285 : rect.left + 3, rect.center.dy),
      );
    }
    final text = find
        .descendant(
          of: find.byType(EditableParagraph).at(block),
          matching: find.byType(RichText),
        )
        .first;
    final render = tester.renderObject<RenderParagraph>(text);
    final caret = render.getOffsetForCaret(
      TextPosition(offset: offset),
      const Rect.fromLTWH(0, 0, 2, 21),
    );
    return render.localToGlobal(
      Offset(blank ? 285 : caret.dx + 3, caret.dy + 10),
    );
  }

  Future<void> tap(
    int block,
    int offset, {
    bool blank = false,
    PointerDeviceKind kind = PointerDeviceKind.mouse,
  }) async {
    await tester.tapAt(point(block, offset, blank: blank), kind: kind);
    await tester.pump(const Duration(milliseconds: 70));
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
    controller.dispose();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<Harness> mount(
  WidgetTester tester, {
  required bool native,
  List<String> texts = paragraphs,
  EditorState? initialState,
}) async {
  final state = initialState ?? EditorState.fromTexts(texts);
  final controller = TextEditingController(text: texts.join('\n'));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 80),
            child: SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: native
                    ? TextField(
                        controller: controller,
                        maxLines: null,
                        style: style,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      )
                    : FluxdoEditor(state: state, baseTextStyle: style),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return Harness(tester, native, state, controller);
}

void main() {
  testWidgets('IR 双击保留逻辑词，点击外部空白还原富文本且不产生撤销步骤', (tester) async {
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'text',
          content: EditableTextContent(
            text: 'hello bold after',
            marks: const [MarkSpan(start: 6, end: 10, kind: MarkKind.strong)],
          ),
        ),
      ],
    )..mode = EditorMode.ir;
    final h = await mount(tester, native: false, initialState: state);
    final point = h.point(0, 7);
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 70));
    expect(state.textBlockById('text')!.content.text, contains('**bold**'));
    await tester.tapAt(point, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 70));
    final selection = state.normalizedSelection()!;
    expect(
      state
          .textBlockById('text')!
          .content
          .text
          .substring(selection.$1.offset, selection.$2.offset),
      'bold',
    );
    await tester.tapAt(const Offset(500, 350), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(state.textBlockById('text')!.content.text, 'hello bold after');
    expect(
      state.textBlockById('text')!.content.marks.single.kind,
      MarkKind.strong,
    );
    expect(state.canUndo, isFalse);
    await h.close();
  });

  testWidgets('连击拖选贴边自动滚动，取消后停止且下次单击恢复光标', (tester) async {
    final h = await mount(
      tester,
      native: false,
      texts: List.generate(50, (i) => 'alpha beta gamma $i'),
    );
    await h.tap(0, 7);
    final drag = await tester.startGesture(
      h.point(0, 7),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 30));
    await drag.moveTo(const Offset(100, 580));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(scroll.pixels, greaterThan(0));
    await drag.cancel();
    await tester.pump();
    final stopped = scroll.pixels;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scroll.pixels, stopped);
    await tester.tapAt(const Offset(220, 200), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(h.state.selection!.isCollapsed, isTrue);
    await h.close();
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    group('$platform native parity', () {
      void parityTest(String name, WidgetTesterCallback body) {
        testWidgets(name, (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }

      parityTest('空格、标点、中英文与 emoji 的双击词边界符合原生', (tester) async {
        for (final offset in [5, 6, 10, 13, 16, 21]) {
          (int, int)? expected;
          for (final native in [true, false]) {
            final h = await mount(
              tester,
              native: native,
              texts: ['alpha  beta, 中文 👩‍💻 tail'],
            );
            await h.tap(0, offset);
            await h.tap(0, offset);
            final range = (h.selection.baseOffset, h.selection.extentOffset);
            if (native) {
              expected = range;
            } else {
              expect(range, expected, reason: 'offset=$offset');
            }
            await h.close();
          }
        }
      });

      parityTest('段尾空白与空段双击/三击符合原生', (tester) async {
        for (final target in [(0, 10), (1, 0), (2, 4)]) {
          final expected = <(int, int)>[];
          for (final native in [true, false]) {
            final h = await mount(
              tester,
              native: native,
              texts: ['alpha beta', '', 'tail'],
            );
            for (var i = 0; i < 3; i++) {
              await h.tap(target.$1, target.$2, blank: true);
              final range = (h.selection.baseOffset, h.selection.extentOffset);
              if (native) {
                expected.add(range);
              } else {
                expect(range, expected.removeAt(0));
              }
            }
            await h.close();
          }
        }
      });

      parityTest('编辑区外空白点击按原生规则失焦', (tester) async {
        bool? expected;
        for (final native in [true, false]) {
          final h = await mount(tester, native: native);
          await h.tap(0, 7);
          await h.tap(0, 7);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tapAt(
            const Offset(500, 350),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          if (native) {
            expected = tester.testTextInput.hasAnyClients;
          } else {
            expect(tester.testTextInput.hasAnyClients, expected);
          }
          await h.close();
        }
      });

      parityTest('Shift 点击从原选区扩展，并能继续反向拖选', (tester) async {
        final expected = <(int, int)>[];
        for (final native in [true, false]) {
          final h = await mount(tester, native: native);
          await h.tap(0, 7);
          await h.tap(0, 7);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await h.tap(0, 2);
          final click = (h.selection.baseOffset, h.selection.extentOffset);
          if (native) {
            expected.add(click);
          } else {
            expect(click, expected.removeAt(0));
          }
          await tester.pump(const Duration(milliseconds: 400));
          // Avoid grabbing the native iOS selection handle at the old endpoint.
          final g = await tester.startGesture(
            h.point(0, 5),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 30));
          await g.moveBy(const Offset(6, 0));
          await tester.pump(const Duration(milliseconds: 16));
          for (final offset in [13, 1]) {
            await g.moveTo(h.point(0, offset));
            await tester.pump(const Duration(milliseconds: 30));
            final range = (h.selection.baseOffset, h.selection.extentOffset);
            if (native) {
              expected.add(range);
            } else {
              expect(range, expected.removeAt(0));
            }
          }
          await g.up();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await h.close();
        }
      });

      parityTest('三击自动换行与软换行边界符合原生', (tester) async {
        for (final texts in [
          ['alpha beta gamma delta epsilon zeta eta theta iota kappa', 'tail'],
          ['alpha beta\nsecond delta\ntail'],
        ]) {
          (int, int)? expected;
          for (final native in [true, false]) {
            final h = await mount(tester, native: native, texts: texts);
            await h.tap(0, 7);
            await h.tap(0, 7);
            await h.tap(0, 7);
            final range = (h.selection.baseOffset, h.selection.extentOffset);
            if (native) {
              expected = range;
            } else {
              expect(range, expected);
            }
            await h.close();
          }
        }
      });

      if (platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS) {
        parityTest('手机双击后拖动以词扩展并可继续输入', (tester) async {
          (int, int)? expected;
          for (final native in [true, false]) {
            final h = await mount(tester, native: native);
            await h.tap(0, 7, kind: PointerDeviceKind.touch);
            final g = await tester.startGesture(
              h.point(0, 7),
              kind: PointerDeviceKind.touch,
            );
            await tester.pump(const Duration(milliseconds: 30));
            await g.moveBy(const Offset(35, 0));
            await tester.pump(const Duration(milliseconds: 30));
            await g.moveTo(h.point(1, 10));
            await tester.pump(const Duration(milliseconds: 30));
            final range = (h.selection.baseOffset, h.selection.extentOffset);
            if (native) {
              expected = range;
            } else {
              expect(range, expected);
            }
            await g.up();
            await tester.pump(const Duration(milliseconds: 200));
            expect(tester.takeException(), isNull);
            final whole = paragraphs.join('\n');
            final selected = h.selection;
            final desired = whole.replaceRange(
              selected.start,
              selected.end,
              'X',
            );
            final platformValue = TextEditingValue.fromJSON(
              tester.testTextInput.editingState!,
            );
            tester.testTextInput.updateEditingValue(
              platformValue.copyWith(
                text: platformValue.text.replaceRange(
                  platformValue.selection.start,
                  platformValue.selection.end,
                  'X',
                ),
                selection: TextSelection.collapsed(
                  offset: platformValue.selection.start + 1,
                ),
                composing: TextRange.empty,
              ),
            );
            await tester.pump();
            final actual = native
                ? h.controller.text
                : h.state.blocks
                      .whereType<TextBlock>()
                      .map((b) => b.content.text)
                      .join('\n');
            expect(actual, desired, reason: '跨段选区输入必须整体替换');
            if (!native) {
              h.state.undo();
              expect(
                h.state.blocks
                    .whereType<TextBlock>()
                    .map((b) => b.content.text)
                    .join('\n'),
                whole,
                reason: '替换只占一个撤销步骤',
              );
            }
            await h.close();
          }
        });

        parityTest('手机长按与拖动按聚焦状态对齐原生', (tester) async {
          for (final focused in [false, true]) {
            final expected = <(int, int)>[];
            for (final native in [true, false]) {
              final h = await mount(tester, native: native);
              if (focused) {
                await h.tap(2, 1);
                await tester.pump(const Duration(milliseconds: 400));
              }
              final g = await tester.startGesture(
                h.point(0, 7),
                kind: PointerDeviceKind.touch,
              );
              await tester.pump(const Duration(milliseconds: 600));
              final start = (h.selection.baseOffset, h.selection.extentOffset);
              if (native) {
                expected.add(start);
              } else {
                expect(
                  start,
                  expected.removeAt(0),
                  reason: 'focused=$focused start',
                );
              }
              await g.moveTo(h.point(1, 10));
              await tester.pump(const Duration(milliseconds: 30));
              final moved = (h.selection.baseOffset, h.selection.extentOffset);
              if (native) {
                expected.add(moved);
              } else {
                expect(
                  moved,
                  expected.removeAt(0),
                  reason: 'focused=$focused move',
                );
              }
              await g.up();
              await h.close();
            }
          }
        });

        parityTest('手机触摸连击和空白点按对齐原生', (tester) async {
          final expected = <(int, int)>[];
          for (final native in [true, false]) {
            final h = await mount(tester, native: native);
            for (var i = 0; i < 3; i++) {
              await h.tap(0, 7, kind: PointerDeviceKind.touch);
              final range = (h.selection.baseOffset, h.selection.extentOffset);
              if (native) {
                expected.add(range);
              } else {
                expect(range, expected.removeAt(0));
              }
            }
            await tester.pump(const Duration(milliseconds: 400));
            await h.tap(2, 4, blank: true, kind: PointerDeviceKind.touch);
            final range = (h.selection.baseOffset, h.selection.extentOffset);
            if (native) {
              expected.add(range);
            } else {
              expect(range, expected.removeAt(0));
            }
            await h.close();
          }
        });
      }

      parityTest('1–5 连击与原生选区一致', (tester) async {
        final expected = <TextSelection>[];
        for (final native in [true, false]) {
          final h = await mount(tester, native: native);
          for (var count = 1; count <= 5; count++) {
            await h.tap(0, 7);
            if (native) {
              expected.add(h.selection);
            } else {
              expect(
                (h.selection.baseOffset, h.selection.extentOffset),
                (
                  expected[count - 1].baseOffset,
                  expected[count - 1].extentOffset,
                ),
                reason: '第 $count 击',
              );
            }
          }
          await h.close();
        }
      });

      parityTest('第二击换词按新落点，空白单击恢复光标', (tester) async {
        final expected = <TextSelection>[];
        for (final native in [true, false]) {
          final h = await mount(tester, native: native);
          await h.tap(0, 1);
          await h.tap(0, 7);
          if (native) {
            expected.add(h.selection);
          } else {
            expect(
              (h.selection.baseOffset, h.selection.extentOffset),
              (expected[0].baseOffset, expected[0].extentOffset),
            );
          }
          await tester.pump(const Duration(milliseconds: 400));
          await h.tap(1, 5, blank: true);
          if (native) {
            expected.add(h.selection);
          } else {
            expect(
              (h.selection.baseOffset, h.selection.extentOffset),
              (expected[1].baseOffset, expected[1].extentOffset),
            );
          }
          expect(h.selection.isCollapsed, isTrue);
          await h.close();
        }
      });

      parityTest('双击拖选按词扩展并支持反向回拖', (tester) async {
        final expected = <(int, int)>[];
        for (final native in [true, false]) {
          final h = await mount(tester, native: native);
          await h.tap(0, 7);
          final g = await tester.startGesture(
            h.point(0, 7),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 30));
          for (final target in [(1, 10), (0, 1), (0, 8)]) {
            await g.moveTo(h.point(target.$1, target.$2));
            await tester.pump(const Duration(milliseconds: 30));
            final selection = (
              h.selection.baseOffset,
              h.selection.extentOffset,
            );
            if (native) {
              expected.add(selection);
            } else {
              expect(selection, expected.removeAt(0));
            }
          }
          await g.up();
          await h.close();
        }
      });

      parityTest('三击拖选保持段落或行粒度', (tester) async {
        (int, int)? expected;
        for (final native in [true, false]) {
          final h = await mount(tester, native: native);
          await h.tap(0, 7);
          await h.tap(0, 7);
          final g = await tester.startGesture(
            h.point(0, 7),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 30));
          await g.moveTo(h.point(1, 10));
          await tester.pump(const Duration(milliseconds: 30));
          final selection = (h.selection.baseOffset, h.selection.extentOffset);
          if (native) {
            expected = selection;
          } else {
            expect(selection, expected);
          }
          await g.up();
          await h.close();
        }
      });
    });
  }
}
