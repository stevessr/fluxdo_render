import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ParagraphParser;
import 'package:fluxdo_render/src/editor/input/input_rules.dart';

void main() {
  for (final mode in EditorMode.values) {
    for (final raw in [
      'https://github.com ',
      '[GitHub](https://github.com)',
      '[https://github.com](https://github.com)',
    ]) {
      test('逐字输入 $mode：$raw', () {
        final state = EditorState.fromTexts([''])..mode = mode;
        addTearDown(state.dispose);
        final id = state.blocks.single.id;
        state.updateSelection(
          EditorSelection.collapsed(EditorPosition(blockId: id, offset: 0)),
        );
        for (final char in raw.split('')) {
          state.insertText(char);
          tryApplyInputRules(state, id, typedChar: char);
        }
        final content = (state.blocks.single as TextBlock).content;
        final links = content.marks.where((m) => m.kind == MarkKind.link);
        if (raw.startsWith('[')) {
          expect(links, hasLength(1));
          expect(links.single.attr, 'https://github.com');
          expect(
            content.text,
            raw.startsWith('[GitHub]') ? 'GitHub' : 'https://github.com',
          );
        } else {
          expect(links, isEmpty, reason: '裸 URL 手打自动识别并非既有输入规则');
          expect(content.text, raw);
        }
      });
    }

    for (final available in [true, false]) {
      testWidgets('真实剪贴板粘贴 $mode，解析可用=$available', (tester) async {
        final state = EditorState.fromTexts([''])..mode = mode;
        addTearDown(state.dispose);
        final id = state.blocks.single.id;
        state.updateSelection(
          EditorSelection.collapsed(EditorPosition(blockId: id, offset: 0)),
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? {'text': 'https://github.com'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        var calls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FluxdoEditor(
                state: state,
                autofocus: true,
                markdownImporter: (raw) async {
                  calls++;
                  expect(raw, 'https://github.com');
                  if (!available) return null;
                  var n = 0;
                  return blockNodesToDoc(
                    ParagraphParser().parse(
                      '<p><a href="https://github.com" class="onebox" '
                      'target="_blank">https://github.com</a></p>',
                    ),
                    () => 'p_${n++}',
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tapAt(tester.getCenter(find.byType(FluxdoEditor)));
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(calls, 1);
        final content = (state.blocks.single as TextBlock).content;
        expect(content.text, 'https://github.com');
        expect(
          content.marks.where((m) => m.kind == MarkKind.link).length,
          available ? 1 : 0,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
