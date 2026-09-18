import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ParagraphParser;
import 'package:fluxdo_render/src/editor/widget/editable_paragraph.dart';

void main() {
  for (final mode in EditorMode.values) {
    testWidgets('裸链接在 $mode 下移动光标、编辑和撤销不产生额外包装', (tester) async {
      const expected = r'[https://github.com/\](https://github.com)';
      var n = 0;
      final blocks = blockNodesToDoc(
        ParagraphParser().parse(
          '<p>[<a href="https://github.com/%5C" '
          'class="inline-onebox-loading">https://github.com/\\</a>]('
          '<a href="https://github.com">https://github.com</a>)</p>',
        ),
        () => 'e_${n++}',
      );
      final state = EditorState(blocks: blocks)..mode = mode;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: FluxdoEditor(state: state, autofocus: true)),
        ),
      );
      await tester.pump();

      String rendered() => tester
          .widget<RichText>(
            find.descendant(
              of: find.byType(EditableParagraph),
              matching: find.byType(RichText),
            ),
          )
          .text
          .toPlainText();

      // 只扫描有自动来源证据的第一个链接；第二个无 class 链接保守
      // 按显式处理，IR 点击展开由 explicit_link_click_test 验证。
      final autoEnd = (blocks.first as TextBlock).content.marks.first.end;
      for (var offset = 0; offset <= autoEnd; offset++) {
        state.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: blocks.single.id, offset: offset),
          ),
        );
        await tester.pump();
        expect(rendered(), expected, reason: '光标在 $offset 时显示必须稳定');
        expect((state.blocks.single as TextBlock).content.text, expected);
      }

      state.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: blocks.single.id, offset: 20),
        ),
      );
      state.insertText('path');
      await tester.pump();
      expect(rendered(), expected.replaceRange(20, 20, 'path'));
      state.undo();
      await tester.pump();
      expect(rendered(), expected);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
