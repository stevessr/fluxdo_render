import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser quote_card 识别', () {
    test('aside.quote 产生 QuoteCardNode', () {
      final result = parser.parse(
        '<aside class="quote" data-username="alice" data-post="3" data-topic="999">'
        '<div class="title"><img class="avatar" src="https://a/alice.png"> alice:</div>'
        '<blockquote><p>引用内容</p></blockquote>'
        '</aside>',
      );
      expect(result, hasLength(1));
      final qc = result[0] as QuoteCardNode;
      expect(qc.username, 'alice');
      expect(qc.avatarUrl, 'https://a/alice.png');
      expect(qc.topicId, 999);
      expect(qc.postNumber, 3);
      expect(qc.children, hasLength(1));
      final p = qc.children[0] as ParagraphNode;
      expect(p.inlines, [const TextRun('引用内容')]);
    });

    test('aside.quote 内有 .title > a 提取 titleText/titleHref', () {
      final result = parser.parse(
        '<aside class="quote" data-username="bob">'
        '<div class="title">'
        '<img class="avatar" src="x.png">'
        '<a href="/t/topic-slug/999/3">原帖标题</a>'
        '</div>'
        '<blockquote><p>x</p></blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.titleText, '原帖标题');
      expect(qc.titleHref, '/t/topic-slug/999/3');
    });

    test('跨帖引用的来源占位保留链接而不是标题，不依赖占位文案的语言', () {
      for (final (label, href) in [
        ('在另一个话题中', '/t/421/2'),
        ('任意本地化文案', '/forum/t/421/2?view=1#post_2'),
      ]) {
        final quote = parser.parse(
          '<aside class="quote no-group" data-username="sam" data-display-name="山岚" '
          'data-post="2" data-topic="421"><div class="title"><div class="quote-controls"></div>'
          '<img class="avatar" src="/sam.png"><a href="$href">$label</a></div>'
          '<blockquote><p>原文</p></blockquote></aside>',
        ).single as QuoteCardNode;
        expect(quote.titleText, isNull);
        expect(quote.titleInlines, isEmpty);
        expect(quote.titleHref, href);
        expect(quote.displayName, '山岚');
        expect(quote.avatarUrl, '/sam.png');
        expect(quote.excerptText, '原文');
      }
    });

    test('真实标题不会因为和占位文字同名或使用数字链接而被过滤', () {
      const label = '在另一个话题中';
      for (final header in [
        '<a href="/t/real-title/421/2">$label</a>',
        '<a href="https://forum.example/t/421/2">$label</a>',
        '<div class="quote-title__text-content"><a href="/t/421/2">$label</a></div>',
      ]) {
        final quote = parser.parse(
          '<aside class="quote" data-username="sam" data-topic="421" data-post="2">'
          '<div class="title">$header</div><blockquote>原文</blockquote></aside>',
        ).single as QuoteCardNode;
        expect(quote.titleText, label);
        expect(quote.titleInlines.single, isA<LinkRun>());
      }
    });

    test('.quote-title__text-content > a 优先(新版)', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<div class="title">'
        '<div class="quote-title__text-content">'
        '<a href="/new-href">new title</a>'
        '</div>'
        '<a href="/old-href">old title</a>'
        '</div>'
        '<blockquote></blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.titleText, 'new title');
      expect(qc.titleHref, '/new-href');
    });

    test('无 .title 块 — 所有头部字段为 null', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<blockquote><p>x</p></blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.avatarUrl, isNull);
      expect(qc.titleText, isNull);
      expect(qc.titleHref, isNull);
    });

    test('data-topic / data-post 非数字 → null', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x" data-topic="abc" data-post="xx">'
        '<blockquote></blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.topicId, isNull);
      expect(qc.postNumber, isNull);
    });

    test('嵌套 quote_card', () {
      final result = parser.parse(
        '<aside class="quote" data-username="outer">'
        '<blockquote>'
        '<p>外</p>'
        '<aside class="quote" data-username="inner">'
        '<blockquote><p>内</p></blockquote>'
        '</aside>'
        '</blockquote>'
        '</aside>',
      );
      final outer = result[0] as QuoteCardNode;
      expect(outer.username, 'outer');
      expect(outer.children, hasLength(2));
      expect(outer.children[0], isA<ParagraphNode>());
      final inner = outer.children[1] as QuoteCardNode;
      expect(inner.username, 'inner');
      expect(inner.children, hasLength(1));
    });

    test('外层引用不会借用内层的头像、标题或分类', () {
      final outer = parser.parse('<aside class="quote quote-post-not-found" data-full="true">'
          '<blockquote><aside class="quote" data-username="inner" data-display-name="里层">'
          '<div class="title"><img class="avatar" src="inner.png">'
          '<a href="/t/88">里层话题</a><a class="badge-category__wrapper" href="/c/8">'
          '<span class="badge-category__name">分类</span></a></div>'
          '<blockquote><p>只在<b>里层</b>出现</p></blockquote></aside></blockquote></aside>').single as QuoteCardNode;
      expect(outer.sourceMissing, isTrue);
      expect(outer.full, isTrue);
      expect([outer.titleHref, outer.avatarUrl, outer.categoryName], everyElement(isNull));
      final inner = outer.children.single as QuoteCardNode;
      expect(inner.avatarUrl, 'inner.png');
      expect(inner.titleText, '里层话题');
      expect(inner.categoryName, '分类');
      expect(inner.displayName, '里层');
      expect(inner.excerptText, '只在里层出现');
      expect(inner.sourceMissing, isFalse);
    });

    test('引用内含 list / strong 等混合块', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<blockquote>'
        '<p>段 <strong>粗</strong></p>'
        '<ul><li>项</li></ul>'
        '</blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.children, hasLength(2));
      expect(qc.children[0], isA<ParagraphNode>());
      expect(qc.children[1], isA<ListNode>());
    });

    test('非 .quote 的 aside 不走 QuoteCardNode(走 fallback)', () {
      final result = parser.parse('<aside class="onebox"><p>x</p></aside>');
      expect(result.whereType<QuoteCardNode>(), isEmpty);
    });

    test('id 在嵌套场景下全局唯一', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<blockquote>'
        '<p>a</p>'
        '<aside class="quote" data-username="y">'
        '<blockquote><p>b</p></blockquote>'
        '</aside>'
        '</blockquote>'
        '</aside>',
      );
      final outer = result[0] as QuoteCardNode;
      final outerP = outer.children[0] as ParagraphNode;
      final inner = outer.children[1] as QuoteCardNode;
      final innerP = inner.children[0] as ParagraphNode;
      expect({outer.id, outerP.id, inner.id, innerP.id}, hasLength(4));
    });

    test('标题含 emoji + 分类徽章 → titleInlines 保留 emoji、category 结构化', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<div class="title"><div class="quote-title__text-content">'
        '<a href="/t/1">标题 '
        '<img class="emoji" title="tada" alt="tada" src="/e.png"></a> '
        '<a class="badge-category__wrapper" href="/c/dev/4">'
        '<span class="badge-category" '
        'style="--category-badge-color: #32c3c3; '
        '--category-badge-text-color: #000000;">'
        '<span class="badge-category__name">开发调优</span></span></a>'
        '</div></div>'
        '<blockquote><p>正文</p></blockquote></aside>',
      );
      final qc = result[0] as QuoteCardNode;
      // 标题走 titleInlines,是一个 LinkRun,内部保留 emoji(不再被纯文本吃掉)。
      final link = qc.titleInlines.whereType<LinkRun>().single;
      expect(link.href, '/t/1');
      expect(link.children.whereType<EmojiRun>(), hasLength(1));
      // 纯文本 titleText 仍在(fallback / 相等用)。
      expect(qc.titleText, isNotNull);
      // 分类徽章结构化提取(名称 / 底色 / 文字色 / 跳分类链接)。
      expect(qc.categoryName, '开发调优');
      expect(qc.categoryColor, '#32c3c3');
      expect(qc.categoryTextColor, '#000000');
      expect(qc.categoryHref, '/c/dev/4');
    });

    test('普通标题(无徽章)→ category 全 null', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<div class="title"><a href="/t/2">纯标题</a></div>'
        '<blockquote><p>x</p></blockquote></aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.categoryName, isNull);
      expect(qc.categoryColor, isNull);
    });
  });
}
