/// mention 点击的全局坐标记录(宿主用户卡片浮层锚点)。
///
/// mention 是 TextSpan/WidgetSpan,宿主在 MentionTapHandler 里拿不到
/// 被点者的 RenderBox —— 只能靠 recognizer onTapDown 记下的全局坐标,
/// 否则浮层只能锚整个段落的 rect,飘到段落角上。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/flatten/inline_flattener.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/mention_handler.dart';

void main() {
  setUp(() => lastInlineTapGlobalPosition = null);

  Future<void> pump(WidgetTester tester, List<InlineNode> inlines) async {
    const flattener = InlineFlattener();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (ctx) {
          final result = flattener.flatten(
            inlines,
            const TextStyle(fontSize: 14),
            emojiImageBuilder: (c, e, s) => SizedBox(width: s, height: s),
            context: ctx,
            mentionTapHandler: (c, u, h) {},
          );
          return Text.rich(result.span, textDirection: TextDirection.ltr);
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('TextSpan 版 mention(无状态 emoji):点击记录全局坐标',
      (tester) async {
    await pump(tester, const [
      TextRun('hi '),
      MentionRun(username: 'bob', href: '/u/bob'),
    ]);
    expect(lastInlineTapGlobalPosition, isNull);
    await tester.tapAt(tester.getCenter(find.byType(Text)));
    await tester.pump();
    expect(lastInlineTapGlobalPosition, isNotNull,
        reason: 'onTapDown 应记下坐标供宿主锚浮层');
  });

  testWidgets('WidgetSpan 版 mention(带状态 emoji):同样记录', (tester) async {
    await pump(tester, const [
      MentionRun(
        username: 'bob',
        href: '/u/bob',
        statusEmoji: EmojiRun(name: 'coffee', url: 'x'),
      ),
    ]);
    final chip = find.byType(GestureDetector).first;
    await tester.tap(chip);
    await tester.pump();
    expect(lastInlineTapGlobalPosition, isNotNull,
        reason: '两条 mention 渲染路径必须同源记录,漏一条就读到陈旧坐标');
  });
}
