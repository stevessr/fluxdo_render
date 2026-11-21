import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/render/selectable_object_block.dart';
import 'package:fluxdo_render/src/widget/fluxdo_render.dart';

import '../test_text_finders.dart';

void main() {
  for (final richText in [false, true]) {
    testWidgets('正文、链接、附件和空白按实际命中显示光标（RichText=$richText）', (tester) async {
      InlineSpanText.debugForceRichText = richText;
      addTearDown(() => InlineSpanText.debugForceRichText = false);
      final links = <String>[];
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      addTearDown(mouse.removePointer);
      Future<void> hover(Offset point, MouseCursor cursor) async {
        await mouse.moveTo(point);
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          cursor,
        );
      }

      for (final selectable in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(40),
                child: FluxdoRender(
                  cookedHtml:
                      '<p>see <a href="/link"><strong>link</strong></a></p>'
                      '<hr><p><a class="attachment" href="/file.pdf">file.pdf</a></p>'
                      '<p><a href="/emoji"><img class="emoji" alt=":heart:" src="/heart.png"></a></p>',
                  selectionEnabled: selectable,
                  linkHandler: (_, href) => links.add(href),
                  emojiImageBuilder: (_, _, size) => SizedBox.square(
                    key: const ValueKey('emoji'),
                    dimension: size,
                  ),
                ),
              ),
            ),
          ),
        );
        final geometry = textGeometryAt(tester);
        Offset glyph(int index) => geometry.renderBox.localToGlobal(
          geometry
              .getBoxesForSelection(
                TextSelection(baseOffset: index, extentOffset: index + 1),
              )
              .single
              .toRect()
              .center,
        );
        final textCursor = selectable
            ? SystemMouseCursors.text
            : SystemMouseCursors.basic;
        await hover(glyph(0), textCursor);
        final link = glyph(7);
        await hover(link, SystemMouseCursors.click);
        await mouse.down(link);
        await mouse.up();
        final trailingSpace = link + const Offset(80, 0);
        await hover(trailingSpace, textCursor);
        await mouse.down(trailingSpace);
        await mouse.up();
        final icon = tester.getCenter(find.byIcon(Icons.save_alt));
        await hover(icon, SystemMouseCursors.click);
        await mouse.down(icon);
        await mouse.up();
        final emoji = tester.getCenter(find.byKey(const ValueKey('emoji')));
        await hover(emoji, SystemMouseCursors.click);
        await mouse.down(emoji);
        await mouse.up();
        expect(links, ['/link', '/file.pdf', '/emoji']);
        links.clear();
        await hover(
          tester.getCenter(find.byType(SelectableObjectBlock)),
          SystemMouseCursors.basic,
        );
        await hover(const Offset(10, 10), SystemMouseCursors.basic);
      }
    });
  }
}
