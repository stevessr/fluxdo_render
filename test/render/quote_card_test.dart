import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:material_ui/material_ui.dart';

import '../test_text_finders.dart';

void main() {
  testWidgets('窄屏大字下两类引用都有作者头像；标题两行，分类和楼层在下一行', (tester) async {
    final longTitle = '能占满两行的很长的话题标题' * 6;
    final category = '很长的分类名称' * 4;
    final urls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SizedBox(
                width: 320,
                child: SingleChildScrollView(
                  child: FluxdoRender(
                    cookedHtml:
                        '<aside class="quote" data-topic="88" data-post="7"><div class="title">'
                        '<img class="avatar" src="/alice.png"><div class="quote-title__text-content">'
                        '<a href="/t/88/7">$longTitle</a><a class="badge-category__wrapper" href="/c/4">'
                        '<span class="badge-category__name">$category</span></a></div></div>'
                        '<blockquote><p>话题摘录</p></blockquote></aside>'
                        '<aside class="quote" data-username="bob" data-display-name="小波" data-post="12">'
                        '<div class="title"><img class="avatar" src="/bob.png"></div><blockquote>帖子摘录</blockquote></aside>'
                        '<aside class="quote"><blockquote>匿名摘录</blockquote></aside>',
                    quoteAvatarBuilder: (_, username, avatar, size) =>
                        SizedBox.square(
                          key: ValueKey('avatar:$avatar'),
                          dimension: size,
                        ),
                    linkHandler: (_, url) => urls.add(url),
                    quoteCardBuilder: (_, node, layout, _) => layout(
                      trailing: node.postNumber == null
                          ? null
                          : const Text('展开'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('avatar:/alice.png')), findsOneWidget);
    expect(find.byKey(const ValueKey('avatar:/bob.png')), findsOneWidget);
    expect(find.text('小波'), findsOneWidget);
    final anonymous = find.byType(RenderQuoteCard).last;
    expect(
      find.descendant(of: anonymous, matching: find.byType(Row)),
      findsNothing,
    );
    final title = findRenderedText(longTitle);
    expect(tester.widget<RichText>(title).maxLines, 2);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('avatar:/alice.png'))).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
    );
    expect(
      tester.getTopLeft(find.text(category)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
    );
    expect(
      tester.getTopLeft(find.text('#7')).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
    );
    await tester.tap(title);
    await tester.tap(find.text(category));
    expect(urls, ['/t/88/7', '/c/4']);
  });

  testWidgets('跨话题帖引文并排显示作者和楼层，长名字让位，卡头紧凑不撑高', (tester) async {
    final author = '很长的显示名' * 6;
    final urls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: SizedBox(
                width: 320,
                child: FluxdoRender(
                  cookedHtml:
                      '<aside class="quote no-group" data-username="sam" data-display-name="$author" '
                      'data-topic="421" data-post="2" data-full="true"><div class="title">'
                      '<img class="avatar" src="/sam.png"><a href="/t/421/2">在另一个话题中</a></div>'
                      '<blockquote><p>引用的第一句。</p></blockquote></aside>',
                  quoteAvatarBuilder: (_, _, _, size) => SizedBox.square(
                    key: const ValueKey('avatar'),
                    dimension: size,
                  ),
                  linkHandler: (_, url) => urls.add(url),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(findRenderedText('在另一个话题中'), findsNothing);
    expect(find.byType(Divider), findsNothing);
    final floor = find.text('#2');
    final centerY = tester.getCenter(floor).dy;
    expect(tester.getCenter(find.text(author)).dy, closeTo(centerY, 2));
    expect(
      tester.getCenter(find.byKey(const ValueKey('avatar'))).dy,
      closeTo(centerY, 2),
    );
    final floorInk = find.ancestor(of: floor, matching: find.byType(InkWell));
    final target = tester.getRect(floorInk);
    expect(target.height, lessThan(40));
    expect(
      tester.getTopLeft(findRenderedText('引用的第一句。')).dy - target.bottom,
      inInclusiveRange(0, 10),
    );
    await tester.tap(floor);
    expect(urls, ['/t/421/2']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('点摘录链接和长按选字不会触发楼层跳转', (tester) async {
    final urls = <String>[];
    var jumps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FluxdoRender(
            cookedHtml:
                '<aside class="quote" data-post="12"><blockquote>'
                '<p><a href="/docs">Reference</a></p><p>select these words</p></blockquote></aside>',
            linkHandler: (_, href) => urls.add(href),
            quoteCardBuilder: (_, _, layout, _) =>
                layout(onOpen: () => jumps++),
          ),
        ),
      ),
    );
    await tester.tapAt(
      tester.getTopLeft(findRenderedText('Reference')) + const Offset(6, 8),
    );
    expect(urls, ['/docs']);
    await tester.longPressAt(
      tester.getTopLeft(findRenderedText('select these words')) +
          const Offset(8, 8),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<SelectionScope>(find.byType(SelectionScope))
        .controller;
    expect(controller.selection, isNotNull);
    expect(jumps, 0);
    controller.clear();
    await tester.pumpAndSettle();
    await tester.tap(find.text('#12'));
    expect(jumps, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
