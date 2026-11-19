import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser footnote 识别', () {
    test('弹层移除嵌套脚注和回链，保留多段、链接及图片', () {
      final result = parser.parse(
        '<p>引用<sup class="footnote-ref"><a href="#fn:1">1</a></sup></p>'
        '<ol class="footnotes-list"><li id="fn:1">'
        '<p>第一段<sup class="footnote-ref"><a href="#fn:2">2</a></sup></p>'
        '<p>第二段<a href="https://example.com">链接</a><img src="note.png">'
        '<a class="footnote-backref" href="#ref">↩︎</a></p>'
        '</li><li id="fn:2"><p>嵌套脚注</p></li></ol>',
      );
      final ref = (result.first as ParagraphNode).inlines
          .whereType<FootnoteRefRun>()
          .single;
      expect(
        ref.contentHtml,
        '<p>第一段</p><p>第二段<a href="https://example.com">链接</a><img src="note.png"></p>',
      );
      // 清理只作用于弹层副本，编辑器仍能取得原始脚注引用。
      final section = result.whereType<FootnotesSectionNode>().single;
      expect(
        section.entries.first.inlines.whereType<FootnoteRefRun>(),
        hasLength(1),
      );
    });

    test('sup.footnote-ref → FootnoteRefRun + content 从 section 取', () {
      final result = parser.parse(
        '<p>引用 <sup class="footnote-ref"><a href="#fn:a">1</a></sup> 这里。</p>'
        '<hr class="footnotes-sep">'
        '<section class="footnotes">'
        '<ol class="footnotes-list">'
        '<li id="fn:a"><p>脚注正文 <a class="footnote-backref" href="#fnref:a">↩</a></p></li>'
        '</ol>'
        '</section>',
      );
      // 第一段含 FootnoteRefRun + 第二个节点是 FootnotesSectionNode
      expect(result, hasLength(2));
      final p = result[0] as ParagraphNode;
      final ref = p.inlines.whereType<FootnoteRefRun>().single;
      expect(ref.number, '1');
      expect(ref.fnId, 'fn:a');
      expect(ref.contentHtml, '脚注正文');
      expect(result[1], isA<FootnotesSectionNode>());
    });

    test('多个 footnote-ref → 各自取对应 content', () {
      final result = parser.parse(
        '<p>A<sup class="footnote-ref"><a href="#fn:1">1</a></sup>'
        ' B<sup class="footnote-ref"><a href="#fn:2">2</a></sup></p>'
        '<section class="footnotes">'
        '<ol class="footnotes-list">'
        '<li id="fn:1">第一条 <a class="footnote-backref" href="#x">↩</a></li>'
        '<li id="fn:2">第二条 <a class="footnote-backref" href="#x">↩</a></li>'
        '</ol>'
        '</section>',
      );
      final p = result[0] as ParagraphNode;
      final refs = p.inlines.whereType<FootnoteRefRun>().toList();
      expect(refs, hasLength(2));
      expect(refs[0].contentHtml, '第一条');
      expect(refs[1].contentHtml, '第二条');
    });

    test('未找到对应 li → FootnoteRefRun.contentHtml 为 null', () {
      final result = parser.parse(
        '<p><sup class="footnote-ref"><a href="#fn:missing">1</a></sup></p>',
      );
      final p = result[0] as ParagraphNode;
      final ref = p.inlines.whereType<FootnoteRefRun>().single;
      expect(ref.contentHtml, isNull);
    });

    test('section.footnotes → FootnotesSectionNode(渲染时隐藏)', () {
      final result = parser.parse(
        '<section class="footnotes"><ol class="footnotes-list">'
        '<li id="fn:a">x</li></ol></section>',
      );
      expect(result, hasLength(1));
      expect(result[0], isA<FootnotesSectionNode>());
    });

    test('hr.footnotes-sep 已被跳过(不产 HorizontalRuleNode)', () {
      final result = parser.parse(
        '<p>before</p><hr class="footnotes-sep"><p>after</p>',
      );
      // 只剩两段 paragraph
      expect(result, hasLength(2));
      expect(result.whereType<HorizontalRuleNode>().toList(), isEmpty);
    });

    test('普通 hr 仍产 HorizontalRuleNode', () {
      final result = parser.parse('<p>a</p><hr><p>b</p>');
      expect(result.whereType<HorizontalRuleNode>(), hasLength(1));
    });

    test('a 文本带 [N] 时也能正确解析 number', () {
      final result = parser.parse(
        '<p><sup class="footnote-ref"><a href="#fn:a">[3]</a></sup></p>'
        '<section class="footnotes"><ol class="footnotes-list">'
        '<li id="fn:a">x</li></ol></section>',
      );
      final ref = (result[0] as ParagraphNode).inlines
          .whereType<FootnoteRefRun>()
          .single;
      expect(ref.number, '3'); // [] 被剥
    });

    test('普通 sup(非 footnote-ref) → 展平兜底,不产 FootnoteRefRun', () {
      final result = parser.parse('<p>H<sup>2</sup>O</p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<FootnoteRefRun>(), isEmpty);
    });

    test('contentHtml 已 strip <a class="footnote-backref">↩</a>', () {
      final result = parser.parse(
        '<p><sup class="footnote-ref"><a href="#fn:a">1</a></sup></p>'
        '<section class="footnotes"><ol class="footnotes-list">'
        '<li id="fn:a"><p>正文 <a class="footnote-backref" href="#x">↩︎</a></p></li>'
        '</ol></section>',
      );
      final ref = (result[0] as ParagraphNode).inlines
          .whereType<FootnoteRefRun>()
          .single;
      expect(ref.contentHtml, '正文');
      expect(ref.contentHtml, isNot(contains('↩')));
    });

    test('countImageRuns 不把 FootnotesSectionNode 算入 + FootnoteRefRun 不含图', () {
      final result = parser.parse(
        '<p><img src="a.png"><sup class="footnote-ref"><a href="#fn:a">1</a></sup></p>'
        '<section class="footnotes"><ol class="footnotes-list">'
        '<li id="fn:a">x</li></ol></section>',
      );
      // 只有 a.png 一张图
      expect(countImageRuns(result), 1);
    });
  });
}
