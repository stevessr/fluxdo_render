import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/flatten/inline_flattener.dart';
import 'package:fluxdo_render/src/flatten/soft_break.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

void main() {
  const flattener = InlineFlattener();
  const baseStyle = TextStyle(fontSize: 14, color: Color(0xFF000000));

  test('空列表产出空 children', () {
    final result = flattener.flatten([], baseStyle);
    expect(result.span.style, baseStyle);
    expect(result.span.children, isEmpty);
    expect(result.recognizers, isEmpty);
  });

  test('纯文本', () {
    final result = flattener.flatten([const TextRun('hello')], baseStyle);
    final children = result.span.children!;
    expect(children, hasLength(1));
    expect((children[0] as TextSpan).text, 'hello');
  });

  test('em 注入 italic style(尾字带 letterSpacing 校正)', () {
    final result = flattener.flatten(
      [const EmRun(children: [TextRun('it')])],
      baseStyle,
    );
    final em = result.span.children![0] as TextSpan;
    expect(em.style?.fontStyle, FontStyle.italic);
    // 合成斜体尾字校正:末 grapheme 拆独立子 span 加尾部 letterSpacing
    // (斜切墨迹倾出 advance,与后随正体重叠 —— italic correction)。
    // 文本内容不变:拼回来仍是 'it'。
    final flat = StringBuffer();
    em.visitChildren((s) {
      if (s is TextSpan && s.text != null) flat.write(s.text);
      return true;
    });
    expect(flat.toString(), 'it');
    TextSpan? corrected;
    em.visitChildren((s) {
      if (s is TextSpan && (s.style?.letterSpacing ?? 0) > 0) corrected = s;
      return true;
    });
    expect(corrected?.text, 't', reason: '斜体 run 末字形吃尾部校正间距');
  });

  test('strong 注入 bold style', () {
    final result = flattener.flatten(
      [const StrongRun(children: [TextRun('bd')])],
      baseStyle,
    );
    final strong = result.span.children![0] as TextSpan;
    expect(strong.style?.fontWeight, FontWeight.bold);
  });

  test('em 嵌套 strong 产生双层 span', () {
    final result = flattener.flatten(
      [
        const EmRun(
          children: [
            StrongRun(children: [TextRun('x')]),
          ],
        ),
      ],
      baseStyle,
    );
    final em = result.span.children![0] as TextSpan;
    final nestedStrong = em.children![0] as TextSpan;
    expect(em.style?.fontStyle, FontStyle.italic);
    expect(nestedStrong.style?.fontWeight, FontWeight.bold);
  });

  test('LineBreak 渲染为 \\n', () {
    final result = flattener.flatten(
      [
        const TextRun('a'),
        const LineBreakRun(),
        const TextRun('b'),
      ],
      baseStyle,
    );
    final children = result.span.children!;
    expect(children, hasLength(3));
    expect((children[1] as TextSpan).text, '\n');
  });

  test('混合复合段落保持顺序', () {
    final result = flattener.flatten(
      [
        const TextRun('hello '),
        const StrongRun(children: [TextRun('bold')]),
        const TextRun(' and '),
        const EmRun(children: [TextRun('italic')]),
        const LineBreakRun(),
        const TextRun('newline'),
      ],
      baseStyle,
    );
    expect(result.span.children, hasLength(6));
  });

  group('LinkRun', () {
    testWidgets('有 context 时产生 TapGestureRecognizer', (tester) async {
      late BuildContext capturedContext;
      await tester.pumpWidget(
        Builder(
          builder: (ctx) {
            capturedContext = ctx;
            return const SizedBox();
          },
        ),
      );
      String? tapped;
      final result = flattener.flatten(
        [const LinkRun(href: 'https://example.com', children: [TextRun('go')])],
        baseStyle,
        context: capturedContext,
        linkHandler: (_, href) => tapped = href,
      );
      expect(result.recognizers, hasLength(1));
      expect(result.recognizers[0], isA<TapGestureRecognizer>());

      // 新契约:点击经 mount 现取活 context,未挂载登记时 no-op(防悬空)
      (result.recognizers[0] as TapGestureRecognizer).onTap!();
      expect(tapped, isNull, reason: '未 attach 挂载 context 时点击应 no-op');

      // 挂载登记后点击生效
      result.mount.attach(capturedContext);
      (result.recognizers[0] as TapGestureRecognizer).onTap!();
      expect(tapped, 'https://example.com');

      // 清理 recognizer 避免 leak warning
      for (final r in result.recognizers) {
        r.dispose();
      }
    });

    test('无 context 时不创建 recognizer(link 不可点)', () {
      final result = flattener.flatten(
        [const LinkRun(href: 'https://example.com', children: [TextRun('go')])],
        baseStyle,
      );
      expect(result.recognizers, isEmpty);
      final linkSpan = result.span.children![0] as TextSpan;
      expect(linkSpan.recognizer, isNull);
    });

    testWidgets('link span 走主题主色,无下划线(对齐 legacy 样式)', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      final result = flattener.flatten(
        [const LinkRun(href: 'https://example.com', children: [TextRun('x')])],
        baseStyle,
        context: ctx,
      );
      final linkSpan = result.span.children![0] as TextSpan;
      // legacy: {color: theme.primary, text-decoration: none}
      expect(linkSpan.style?.color, Theme.of(ctx).colorScheme.primary);
      expect(linkSpan.style?.decoration, null);
      for (final r in result.recognizers) {
        r.dispose();
      }
    });

    test('无 context 时 link 字色 fallback 为 null(由 baseStyle 决定)', () {
      final result = flattener.flatten(
        [const LinkRun(href: 'https://example.com', children: [TextRun('x')])],
        baseStyle,
      );
      final linkSpan = result.span.children![0] as TextSpan;
      expect(linkSpan.style?.color, isNull);
    });

    test('link 内嵌 strong 保留嵌套样式', () {
      final result = flattener.flatten(
        [
          const LinkRun(
            href: 'https://example.com',
            children: [
              TextRun('点击 '),
              StrongRun(children: [TextRun('粗体')]),
            ],
          ),
        ],
        baseStyle,
      );
      final linkSpan = result.span.children![0] as TextSpan;
      expect(linkSpan.children, hasLength(2));
      final strong = linkSpan.children![1] as TextSpan;
      expect(strong.style?.fontWeight, FontWeight.bold);
    });

    testWidgets('recognizer 透传到所有叶子 span(回归: Flutter recognizer 不 bubble)',
        (tester) async {
      // Flutter `TextSpan.recognizer` 不会从父 span 传播到 children;
      // 必须挂到每个叶子 span(有 text 字段的那个),tap 才能响应。
      late BuildContext ctx;
      await tester.pumpWidget(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }));

      final result = flattener.flatten(
        [
          const LinkRun(
            href: 'https://x.com',
            children: [
              TextRun('前 '),
              StrongRun(children: [TextRun('粗')]),
              InlineCodeRun('code'),
            ],
          ),
        ],
        baseStyle,
        context: ctx,
        linkHandler: (_, _) {},
      );

      // 收集所有叶子 TextSpan 的 recognizer
      final leafRecognizers = <GestureRecognizer?>[];
      void walk(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text != null) {
            leafRecognizers.add(s.recognizer);
          }
          if (s.children != null) {
            for (final c in s.children!) {
              walk(c);
            }
          }
        }
      }
      walk(result.span);

      // 五个叶子(TextRun / StrongRun 内的 TextRun / InlineCodeRun 的
      // pad + code + pad)都必须挂同一个 recognizer
      expect(leafRecognizers, hasLength(5));
      expect(leafRecognizers.every((r) => r != null), isTrue);
      expect(
        leafRecognizers.toSet(),
        hasLength(1),
        reason: '一个 LinkRun 应该所有叶子共享同一个 recognizer 实例',
      );

      for (final r in result.recognizers) {
        r.dispose();
      }
    });
  });

  group('InlineCodeRun', () {
    // InlineCodeRun 产出 [NBSP pad][code][NBSP pad] 容器 span(粘性内边距,
    // 见 _buildInlineCodeSpan);取中间的 code 叶子断言样式。
    TextSpan codeLeafOf(FlattenResult result) {
      final container = result.span.children![0] as TextSpan;
      expect(container.children, hasLength(3));
      expect((container.children![0] as TextSpan).text, kInlineCodePadChar);
      expect((container.children![2] as TextSpan).text, kInlineCodePadChar);
      return container.children![1] as TextSpan;
    }

    testWidgets('light 主题:派生 onSurfaceVariant 字色(背景移到 painter,span 不带 background)',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      final scheme = Theme.of(ctx).colorScheme;
      final result = flattener.flatten(
        [const InlineCodeRun('git status')],
        baseStyle,
        context: ctx,
      );
      final span = codeLeafOf(result);
      expect(span.text, 'git status');
      expect(span.style?.fontFamily, 'FiraCode');
      expect(span.style?.fontFamilyFallback, ['monospace', 'Menlo', 'Courier']);
      // 0.85em
      expect(span.style?.fontSize, closeTo(11.9, 0.01));
      // 派生字色 onSurfaceVariant;背景由 InlineCodeBackgroundPainter 自绘 →
      // span.style 不再带 background(否则只能直角、跨行裂块)。
      expect(span.style?.color, scheme.onSurfaceVariant);
      expect(span.style?.background, isNull,
          reason: '背景移到 painter,span 不带 background');
    });

    testWidgets('dark 主题也走派生字色(颜色自动跟随)', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      final scheme = Theme.of(ctx).colorScheme;
      final result = flattener.flatten(
        [const InlineCodeRun('x')],
        baseStyle,
        context: ctx,
      );
      final span = codeLeafOf(result);
      expect(span.style?.color, scheme.onSurfaceVariant);
      expect(span.style?.background, isNull);
    });

    test('无 context 时 color 退化为 null(背景始终在 painter,span 无 background)', () {
      final result = flattener.flatten(
        [const InlineCodeRun('x')],
        baseStyle,
      );
      final span = codeLeafOf(result);
      expect(span.style?.color, isNull);
      expect(span.style?.background, isNull);
      // 字体/字号仍生效
      expect(span.style?.fontFamily, 'FiraCode');
      expect(span.style?.fontSize, closeTo(11.9, 0.01));
    });

    test('与 link / text 混排顺序保留', () {
      final result = flattener.flatten(
        [
          const TextRun('使用 '),
          const InlineCodeRun('git'),
          const TextRun(' 命令'),
        ],
        baseStyle,
      );
      final children = result.span.children!;
      expect(children, hasLength(3));
      expect((children[0] as TextSpan).text, '使用 ');
      final code = children[1] as TextSpan;
      // pad + code + pad 容器,中间是 code 文本
      expect((code.children![1] as TextSpan).text, 'git');
      expect((children[2] as TextSpan).text, ' 命令');
    });
  });

  group('EmojiRun', () {
    testWidgets('普通 emoji 产出 WidgetSpan,size = baseStyle.fontSize', (tester) async {
      late BuildContext ctx;
      double? capturedSize;
      EmojiRun? capturedRun;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ));
      final result = flattener.flatten(
        [const EmojiRun(name: 'heart', url: 'https://x/heart.png')],
        baseStyle, // fontSize: 14
        context: ctx,
        emojiImageBuilder: (_, run, size) {
          capturedRun = run;
          capturedSize = size;
          return const SizedBox();
        },
      );
      final span = result.span.children![0];
      expect(span, isA<WidgetSpan>());
      // build 一次让 Builder 触发
      await tester.pumpWidget(MaterialApp(home: Text.rich(result.span)));
      expect(capturedSize, 14);
      expect(capturedRun?.name, 'heart');
    });

    testWidgets('only-emoji 用 32dp', (tester) async {
      double? capturedSize;
      await tester.pumpWidget(MaterialApp(
        home: Text.rich(TextSpan(children: [
          flattener.flatten(
            [const EmojiRun(name: 'tada', url: 'x.png', isOnlyEmoji: true)],
            baseStyle,
            emojiImageBuilder: (_, _, size) {
              capturedSize = size;
              return const SizedBox();
            },
          ).span,
        ])),
      ));
      expect(capturedSize, 32);
    });

    testWidgets('h2 字号 21 时 emoji size 跟父 baseStyle', (tester) async {
      double? capturedSize;
      const h2Style = TextStyle(fontSize: 21);
      await tester.pumpWidget(MaterialApp(
        home: Text.rich(TextSpan(children: [
          flattener.flatten(
            [const EmojiRun(name: 'star', url: 'x.png')],
            h2Style,
            emojiImageBuilder: (_, _, size) {
              capturedSize = size;
              return const SizedBox();
            },
          ).span,
        ])),
      ));
      expect(capturedSize, 21);
    });

    test('无 builder 时走 defaultEmojiImageBuilder(不抛)', () {
      final result = flattener.flatten(
        [const EmojiRun(name: 'heart', url: 'https://x/h.png')],
        baseStyle,
      );
      final span = result.span.children![0];
      expect(span, isA<WidgetSpan>());
    });
  });

  group('MentionRun', () {
    // 无状态 emoji 的 mention 走纯 TextSpan 路径(行内代码三件套同款):
    // NBSP pad + `@username` + NBSP pad,点击走 recognizer,药丸底色由
    // InlineCodeBackgroundPainter 按 mentionText 投影区间自绘(golden 覆盖)。
    testWidgets('纯 TextSpan 路径:recognizer tap 触发 handler 带 username + href',
        (tester) async {
      String? tappedUser;
      String? tappedHref;
      late FlattenResult result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            result = flattener.flatten(
              [const MentionRun(username: 'alice', href: '/u/alice')],
              baseStyle,
              context: c,
              mentionTapHandler: (_, user, href) {
                tappedUser = user;
                tappedHref = href;
              },
            );
            // 新契约:挂载方登记活 context,recognizer 点击时现取
            result.mount.attach(c);
            return Text.rich(result.span);
          }),
        ),
      ));
      // 不再有 GestureDetector:recognizer 挂在 span 叶子上,并经
      // FlattenResult.recognizers 暴露给调用方释放
      expect(find.byType(GestureDetector), findsNothing);
      expect(result.recognizers, hasLength(1));
      final recognizer = result.recognizers.single;
      expect(recognizer, isA<TapGestureRecognizer>());
      (recognizer as TapGestureRecognizer).onTap!();
      expect(tappedUser, 'alice');
      expect(tappedHref, '/u/alice');
    });

    testWidgets('字色 = colorScheme.primary,字号 0.82em,NBSP 粘性内边距',
        (tester) async {
      late BuildContext ctx;
      late FlattenResult result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          ctx = c;
          result = flattener.flatten(
            [const MentionRun(username: 'alice', href: '/u/alice')],
            baseStyle,
            context: c,
          );
          return Text.rich(result.span);
        }),
      ));
      final scheme = Theme.of(ctx).colorScheme;
      final mention = result.span.children![0] as TextSpan;
      final children = mention.children!;
      expect(children, hasLength(3));
      expect((children[0] as TextSpan).text, kInlineCodePadChar);
      expect((children[2] as TextSpan).text, kInlineCodePadChar);
      final body = children[1] as TextSpan;
      expect(body.text, '@alice');
      expect(body.style?.color, scheme.primary);
      expect(body.style?.fontSize, closeTo(14 * 0.82, 0.01));
    });

    testWidgets('statusEmoji 渲染到 username 右侧', (tester) async {
      int builderCallCount = 0;
      EmojiRun? receivedEmoji;
      double? receivedSize;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          return Text.rich(flattener.flatten(
            [
              const MentionRun(
                username: 'alice',
                href: '/u/alice',
                statusEmoji: EmojiRun(name: 'fire', url: 'x.png'),
              ),
            ],
            baseStyle,
            context: c,
            emojiImageBuilder: (_, e, size) {
              builderCallCount++;
              receivedEmoji = e;
              receivedSize = size;
              return const SizedBox();
            },
          ).span);
        }),
      ));
      expect(builderCallCount, 1);
      expect(receivedEmoji?.name, 'fire');
      // status emoji size = fontSize * 1.2 = 14 * 0.82 * 1.2 ≈ 13.78
      expect(receivedSize, closeTo(14 * 0.82 * 1.2, 0.01));
    });

    test('无 context 时纯结构输出(TextSpan 路径,无 recognizer)', () {
      final result = flattener.flatten(
        [const MentionRun(username: 'a', href: '/u/a')],
        baseStyle,
      );
      final mention = result.span.children![0] as TextSpan;
      expect((mention.children![1] as TextSpan).text, '@a');
      expect(result.recognizers, isEmpty);
    });
  });
}
