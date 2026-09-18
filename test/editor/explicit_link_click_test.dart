import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ParagraphParser;
import 'package:fluxdo_render/src/editor/widget/editable_paragraph.dart';

void main() {
  for (final mode in EditorMode.values) {
    for (final automatic in [false, true]) {
      for (final label in ['https://github.com', if (!automatic) 'GitHub']) {
        testWidgets('$mode 点击 ${automatic ? '自动' : '显式'} 链接 $label', (
          tester,
        ) async {
          const url = 'https://github.com';
          var n = 0;
          final blocks = blockNodesToDoc(
            ParagraphParser().parse(
              '<p>前 <a href="$url"${automatic ? ' class="inline-onebox-loading"' : ''}>$label</a> 后</p>'
              '<p>离开链接</p>',
            ),
            () => 'e_${n++}',
          );
          final state = EditorState(blocks: blocks)..mode = mode;
          addTearDown(state.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: FluxdoEditor(state: state, autofocus: true)),
            ),
          );
          await tester.pump();
          final paragraphs = find.byType(EditableParagraph);
          final firstText = find.descendant(
            of: paragraphs.first,
            matching: find.byType(RichText),
          );
          String rendered() =>
              tester.widget<RichText>(firstText).text.toPlainText();
          expect(rendered(), '前 $label 后');
          final render = tester.renderObject<RenderParagraph>(firstText);
          final boxes = render.getBoxesForSelection(
            const TextSelection(baseOffset: 3, extentOffset: 4),
          );
          await tester.tapAt(
            render.localToGlobal(boxes.first.toRect().center),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 400));
          final expanded = mode == EditorMode.ir && !automatic;
          expect(
            rendered(),
            expanded ? '前 [$label]($url) 后' : '前 $label 后',
            reason: '显式链接恢复真实点击展开，自动链接不凭空生成包装',
          );
          expect(
            (state.blocks.first as TextBlock).content.text,
            rendered(),
            reason: '源码必须真实可编辑，而非只画出定界符',
          );
          if (expanded) {
            final position = '前 [$label]('.length + url.length;
            state.updateSelection(
              EditorSelection.collapsed(
                EditorPosition(blockId: blocks.first.id, offset: position),
              ),
            );
            state.insertText('/issues');
            await tester.pump();
            expect(rendered(), '前 [$label]($url/issues) 后');
          }
          await tester.tapAt(
            tester.getCenter(paragraphs.last),
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(rendered(), '前 $label 后');
          final content = (state.blocks.first as TextBlock).content;
          expect(content.marks.single.attr, expanded ? '$url/issues' : url);
          expect(content.marks.single.isAutoLink, automatic);
          expect(
            docToMarkdown(state.blocks),
            automatic
                ? '前 $url 后\n\n离开链接'
                : '前 [$label](${expanded ? '$url/issues' : url}) 后\n\n离开链接',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }
}
