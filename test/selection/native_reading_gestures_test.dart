import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/selection_range.dart';
import 'package:fluxdo_render/src/selection/selection_gesture_layer.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';
import 'package:fluxdo_render/src/selection/block_text_geometry.dart';
import '../test_text_finders.dart';

const _style = TextStyle(fontSize: 14, height: 1.5);
const _paragraphs = ['alpha beta gamma', 'second delta epsilon', 'tail'];

class _Harness {
  _Harness(this.tester, this.native, this.controller, this.texts);
  final WidgetTester tester;
  final bool native;
  final SelectionController controller;
  final List<String> texts;
  String nativeSelection = '';
  // Native SelectionArea concatenates separate Text widgets without separators.
  // Compare selected characters here, leaving FluxDO's paragraph/newline copy
  // formatting to the exporter tests; preserve actual newlines inside each node.
  String get selected => native
      ? nativeSelection
      : controller.selection == null || controller.selection!.isCollapsed
      ? ''
      : expandSelection(controller.registry, controller.selection!)
            .map((range) => range.projection.project(range.start, range.end))
            .join();
  Offset point(int block, int offset, {bool blank = false}) {
    final render = tester.renderObject(findRenderedText(texts[block]).first);
    final geometry = render is BlockTextGeometry
        ? render as BlockTextGeometry
        : ParagraphGeometry(render as RenderParagraph);
    final caret = geometry.caretRectAt(offset);
    return geometry.renderBox.localToGlobal(
      Offset(blank ? 285 : caret.left + 2, caret.center.dy),
    );
  }

  Future<void> tap(
    int block,
    int offset, {
    PointerDeviceKind kind = PointerDeviceKind.mouse,
    bool blank = false,
  }) async {
    await tester.tapAt(point(block, offset, blank: blank), kind: kind);
    await tester.pump(const Duration(milliseconds: 70));
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<_Harness> _mount(
  WidgetTester tester,
  int implementation, {
  List<String> texts = _paragraphs,
}) async {
  final native = implementation == 0;
  InlineSpanText.debugForceRichText = implementation == 1;
  final controller = SelectionController(SelectionRegistry());
  final harness = _Harness(tester, native, controller, texts);
  final content = Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < texts.length; i++)
        native
            ? Text(texts[i], style: _style)
            : InlineSpanText(
                inlines: [TextRun(texts[i])],
                baseStyle: _style,
                documentOrder: i,
              ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(top: 110),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: native
                  ? SelectionArea(
                      onSelectionChanged: (value) =>
                          harness.nativeSelection = value?.plainText ?? '',
                      child: content,
                    )
                  : SelectionScope(
                      controller: controller,
                      child: SelectionGestureLayer(
                        controller: controller,
                        onSelectionChanged: (_, {bool fromTouch = false}) {},
                        child: content,
                      ),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return harness;
}

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    void parity(String name, WidgetTesterCallback body) =>
        testWidgets('$platform $name', (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          try {
            await body(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
            InlineSpanText.debugForceRichText = false;
          }
        });

    parity('阅读态 1–5 连击与原生 SelectionArea 一致（两种渲染路径）', (tester) async {
      final expected = <String>[];
      for (var implementation = 0; implementation < 3; implementation++) {
        final h = await _mount(tester, implementation);
        for (var i = 0; i < 5; i++) {
          await h.tap(0, 7);
          if (h.native) {
            expected.add(h.selected);
          } else {
            expect(
              h.selected,
              expected[i],
              reason: 'renderer=$implementation tap=${i + 1}',
            );
          }
        }
        await tester.pump(const Duration(milliseconds: 400));
        await h.tap(2, 4, blank: true);
        expect(h.selected, isEmpty);
        await h.close();
      }
    });

    for (final taps in [1, 2, 3]) {
      parity('阅读态 $taps 击拖选按字符/词/段并支持反向', (tester) async {
        final expected = <String>[];
        for (var implementation = 0; implementation < 3; implementation++) {
          final h = await _mount(tester, implementation);
          for (var i = 1; i < taps; i++) {
            await h.tap(0, 7);
          }
          final g = await tester.startGesture(
            h.point(0, 7),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 30));
          var i = 0;
          for (final target in [(1, 10), (0, 1), (0, 8)]) {
            await g.moveTo(h.point(target.$1, target.$2));
            await tester.pump(const Duration(milliseconds: 30));
            if (h.native) {
              expected.add(h.selected);
            } else {
              expect(
                h.selected,
                expected[i],
                reason: 'renderer=$implementation endpoint=$target',
              );
            }
            i++;
          }
          await g.up();
          await h.close();
        }
      });
    }

    parity('阅读态三击按段落边界，不把换行代码整块选中', (tester) async {
      for (final text in [
        'alpha beta\nsecond delta\ntail',
        'alpha beta gamma delta epsilon zeta eta theta iota kappa',
      ]) {
        String? expected;
        for (var implementation = 0; implementation < 3; implementation++) {
          final h = await _mount(tester, implementation, texts: [text]);
          await h.tap(0, 7);
          await h.tap(0, 7);
          await h.tap(0, 7);
          if (h.native) {
            expected = h.selected;
          } else {
            expect(h.selected, expected);
          }
          await h.close();
        }
      }
    });

    parity('阅读态 Unicode 词边界不拆开 emoji 或退化为单个 UTF-16 字符', (tester) async {
      for (final offset in [5, 6, 13, 16, 21]) {
        String? expected;
        for (var implementation = 0; implementation < 3; implementation++) {
          final h = await _mount(
            tester,
            implementation,
            texts: ['alpha  beta, 中文 👩‍💻 tail'],
          );
          await h.tap(0, offset);
          await h.tap(0, offset);
          if (h.native) {
            expected = h.selected;
          } else {
            expect(
              h.selected,
              expected,
              reason: 'offset=$offset renderer=$implementation',
            );
          }
          await h.close();
        }
      }
    });

    parity('阅读态 Shift 点击向前、向后和区内扩展保持原生锚点', (tester) async {
      for (final target in [(1, 8), (0, 2), (0, 8)]) {
        String? expected;
        for (var implementation = 0; implementation < 3; implementation++) {
          final h = await _mount(tester, implementation);
          await h.tap(0, 7);
          await h.tap(0, 7);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await h.tap(target.$1, target.$2);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          if (h.native) {
            expected = h.selected;
          } else {
            expect(
              h.selected,
              expected,
              reason: 'endpoint=$target renderer=$implementation',
            );
          }
          await h.close();
        }
      }
    });

    if (platform == TargetPlatform.android || platform == TargetPlatform.iOS) {
      parity('阅读态双击拖动与长按拖动保持原生词边界', (tester) async {
        for (final longPress in [false, true]) {
          String? expected;
          for (var implementation = 0; implementation < 3; implementation++) {
            final h = await _mount(tester, implementation);
            if (!longPress) await h.tap(0, 7, kind: PointerDeviceKind.touch);
            final g = await tester.startGesture(
              h.point(0, 7),
              kind: PointerDeviceKind.touch,
            );
            await tester.pump(Duration(milliseconds: longPress ? 600 : 50));
            await g.moveBy(const Offset(35, 0));
            await tester.pump(const Duration(milliseconds: 30));
            await g.moveTo(h.point(1, 10));
            await tester.pump(const Duration(milliseconds: 30));
            if (h.native) {
              expected = h.selected;
            } else {
              expect(
                h.selected,
                expected,
                reason: 'longPress=$longPress renderer=$implementation',
              );
            }
            await g.up();
            await h.close();
          }
        }
      });

      parity('阅读态手机触摸连击不借用编辑态规则', (tester) async {
        final expected = <String>[];
        for (var implementation = 0; implementation < 3; implementation++) {
          final h = await _mount(tester, implementation);
          for (var i = 0; i < 3; i++) {
            await h.tap(0, 7, kind: PointerDeviceKind.touch);
            if (h.native) {
              expected.add(h.selected);
            } else {
              expect(h.selected, expected[i]);
            }
          }
          expect(tester.testTextInput.hasAnyClients, isFalse);
          await h.close();
        }
      });
    }
  }
}
