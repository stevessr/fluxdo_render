import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/flatten/inline_flattener.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/selection/projection_builder.dart';

void main() {
  group('buildInlineProjection 投影规则', () {
    test('纯文本', () {
      final p = buildInlineProjection(const [TextRun('你好世界')]);
      expect(p.projectAll(), '你好世界');
      expect(p.renderLength, 4);
    });

    test('emoji → :name:,占 1 渲染偏移', () {
      final p = buildInlineProjection(const [
        TextRun('心情'),
        EmojiRun(name: 'heart', url: 'x'),
        TextRun('好'),
      ]);
      expect(p.projectAll(), '心情:heart:好');
      // 渲染偏移: 心(0)情(1)￼(2)好(3) → renderLength 4
      expect(p.renderLength, 4);
      // 只选 ￼ → 整条 :heart:
      expect(p.project(2, 3), ':heart:');
    });

    test('空名 emoji 不贡献', () {
      final p = buildInlineProjection(const [
        TextRun('AB'),
        EmojiRun(name: '', url: 'x'),
        TextRun('CD'),
      ]);
      expect(p.projectAll(), 'ABCD');
      expect(p.renderLength, 5); // A B ￼ C D
    });

    test('mention → @username', () {
      final p = buildInlineProjection(const [
        TextRun('感谢 '),
        MentionRun(username: 'alice', href: '/u/alice'),
        TextRun(' 帮助'),
      ]);
      expect(p.projectAll(), '感谢 @alice 帮助');
    });

    test('clickCount 排除', () {
      final p = buildInlineProjection(const [
        TextRun('链接'),
        ClickCountRun('123'),
        TextRun('尾'),
      ]);
      expect(p.projectAll(), '链接尾');
      expect(p.renderLength, 4); // 链 接 ￼ 尾
    });

    test('image → alt(空则跳过)', () {
      expect(
        buildInlineProjection(const [
          TextRun('图'),
          ImageRun(src: 'x', alt: '截图'),
        ]).projectAll(),
        '图截图',
      );
      expect(
        buildInlineProjection(const [
          TextRun('图'),
          ImageRun(src: 'x', alt: ''),
        ]).projectAll(),
        '图',
      );
    });

    test('em/strong/link 递归不加额外偏移', () {
      final p = buildInlineProjection(const [
        StrongRun(children: [TextRun('粗')]),
        EmRun(children: [TextRun('斜')]),
        LinkRun(href: 'x', children: [TextRun('链')]),
      ]);
      expect(p.projectAll(), '粗斜链');
      expect(p.renderLength, 3);
    });

    test('inline code 原文', () {
      final p = buildInlineProjection(const [InlineCodeRun('flutter run')]);
      expect(p.projectAll(), 'flutter run');
    });

    test('lineBreak → \\n', () {
      final p = buildInlineProjection(const [
        TextRun('上'),
        LineBreakRun(),
        TextRun('下'),
      ]);
      expect(p.projectAll(), '上\n下');
    });

    test('spoiler → 子文本全文(占 1 渲染偏移,原子)', () {
      final p = buildInlineProjection(const [
        TextRun('答案是'),
        SpoilerRun(children: [TextRun('42')]),
        TextRun('。'),
      ]);
      expect(p.projectAll(), '答案是42。');
      // 渲染偏移: 答(0)案(1)是(2)￼(3)。(4) → renderLength 5
      expect(p.renderLength, 5);
      // 只选 spoiler ￼ → 整条子文本
      expect(p.project(3, 4), '42');
    });

    test('footnote → number;localDate → fallbackText', () {
      final p = buildInlineProjection(const [
        TextRun('正文'),
        FootnoteRefRun(number: '1', fnId: 'fn:a'),
        TextRun(' '),
        LocalDateRun(date: '2026-06-25', fallbackText: '2026年6月25日'),
      ]);
      expect(p.projectAll(), '正文1 2026年6月25日');
    });

    test('mathInline 投影 latex(对齐 cooked textContent)', () {
      final p = buildInlineProjection(const [
        TextRun('公式'),
        MathInlineRun('x^2'),
        TextRun('完'),
      ]);
      expect(p.projectAll(), '公式x^2完');
      expect(p.renderLength, 4); // 公 式 ￼(math占1) 完
      // 只选 math ￼ → 整条 latex
      expect(p.project(2, 3), 'x^2');
    });
  });

  // 关键不变式:buildInlineProjection 的 renderLength 必须 == 实际 RenderParagraph
  // 的 plainText 长度(否则命中/高亮偏移全错)。
  group('renderLength == RenderParagraph plainText 长度', () {
    Future<int> realRenderLength(
        WidgetTester tester, List<InlineNode> inlines) async {
      const flattener = InlineFlattener();
      final result = flattener.flatten(inlines, const TextStyle(fontSize: 14),
          emojiImageBuilder: (ctx, emoji, size) => SizedBox(width: size, height: size),
          imageContentBuilder: (ctx, image, total) =>
              const SizedBox(width: 20, height: 20),
          context: null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Text.rich(result.span, textDirection: TextDirection.ltr),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final para = tester.allRenderObjects.whereType<RenderParagraph>().first;
      return para.text.toPlainText().length;
    }

    testWidgets('文本+emoji+mention 偏移对齐', (tester) async {
      const inlines = [
        TextRun('Hi '),
        EmojiRun(name: 'heart', url: 'x'),
        TextRun(' '),
        MentionRun(username: 'bob', href: '/u/bob'),
        TextRun(' end'),
      ];
      final real = await realRenderLength(tester, inlines);
      final proj = buildInlineProjection(inlines);
      expect(proj.renderLength, real,
          reason: 'projection renderLength 必须等于 RenderParagraph plainText 长度');
    });

    testWidgets('含 image + lineBreak 偏移对齐', (tester) async {
      const inlines = [
        TextRun('A'),
        ImageRun(src: 'x', alt: 'img'),
        LineBreakRun(),
        TextRun('B'),
      ];
      final real = await realRenderLength(tester, inlines);
      final proj = buildInlineProjection(inlines);
      expect(proj.renderLength, real);
    });

    testWidgets('含 hashtag 药丸偏移对齐(投影原子化与渲染 WidgetSpan 必须同步落地)',
        (tester) async {
      // #13/#14 拆分教训:投影侧原子化(#13)先落地而渲染侧药丸(#14)
      // 未跟上时,本用例红(投影 1 个占位 vs 渲染按 5 个字符画)——
      // 含 hashtag 的段落从 hashtag 起选区/复制偏移全错。两侧必须同步。
      const inlines = [
        TextRun('看看 '),
        LinkRun(
          href: '/c/dev/4',
          hashtagRef: 'dev',
          children: [TextRun('#开发调优')],
        ),
        TextRun(' 板块'),
      ];
      final real = await realRenderLength(tester, inlines);
      final proj = buildInlineProjection(inlines);
      expect(proj.renderLength, real,
          reason: '铁律:投影与渲染逐字一致,否则 hashtag 后所有偏移错位');
    });
  });
}
