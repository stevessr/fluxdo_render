/// ir spin 纯函数(inline_spin.dart)测试:整块扫描折叠完整字面标记对、
/// caret 重映射、排除区、循环不动点、快退路径。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/inline_spin.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

EditableTextContent content(
  String text, {
  List<MarkSpan> marks = const [],
}) =>
    EditableTextContent(text: text, marks: marks);

void main() {
  group('各 kind 完整对折叠', () {
    test('**bold** → strong', () {
      final r = spinInlineMarks(content('a **bold** b'), caret: 12);
      expect(r.content.text, 'a bold b');
      expect(r.content.marks.single.kind, MarkKind.strong);
      expect(r.content.marks.single.start, 2);
      expect(r.content.marks.single.end, 6);
      expect(r.caret, 8);
    });

    test('*em* / __strong__ / ~~del~~ / `code`', () {
      expect(
        spinInlineMarks(content('*x*'), caret: 0).content.marks.single.kind,
        MarkKind.em,
      );
      expect(
        spinInlineMarks(content('__x__'), caret: 0).content.marks.single.kind,
        MarkKind.strong,
      );
      expect(
        spinInlineMarks(content('~~x~~'), caret: 0).content.marks.single.kind,
        MarkKind.lineThrough,
      );
      final code = spinInlineMarks(content('`x`'), caret: 0);
      expect(code.content.marks.single.kind, MarkKind.inlineCode);
    });

    test('BBCode 无 attr:[u]x[/u] / [spoiler]x[/spoiler] / [b]x[/b]', () {
      expect(
        spinInlineMarks(content('[u]x[/u]'), caret: 0)
            .content
            .marks
            .single
            .kind,
        MarkKind.underline,
      );
      final sp = spinInlineMarks(content('[spoiler]秘密[/spoiler]'), caret: 0);
      expect(sp.content.text, '秘密');
      expect(sp.content.marks.single.kind, MarkKind.spoilerInline);
      expect(
        spinInlineMarks(content('[b]x[/b]'), caret: 0)
            .content
            .marks
            .single
            .kind,
        MarkKind.strong,
      );
    });

    test('BBCode attr:[size=150]大[/size] → size mark 带 attr', () {
      final r = spinInlineMarks(content('[size=150]大[/size]'), caret: 19);
      expect(r.content.text, '大');
      final m = r.content.marks.single;
      expect(m.kind, MarkKind.size);
      expect(m.attr, '150');
      expect(r.caret, 1);
    });

    test('BBCode attr:[color=#f00]红[/color]', () {
      final r = spinInlineMarks(content('[color=#f00]红[/color]'), caret: 0);
      expect(r.content.text, '红');
      expect(r.content.marks.single.kind, MarkKind.textColor);
      expect(r.content.marks.single.attr, '#f00');
    });

    test('HTML 标签:<small>x</small> / <kbd>k</kbd>', () {
      expect(
        spinInlineMarks(content('<small>x</small>'), caret: 0)
            .content
            .marks
            .single
            .kind,
        MarkKind.smallStyle,
      );
      expect(
        spinInlineMarks(content('<kbd>k</kbd>'), caret: 0)
            .content
            .marks
            .single
            .kind,
        MarkKind.monospaceStyle,
      );
    });
  });

  group('caret 重映射', () {
    test('命中区之前:caret 不动', () {
      final r = spinInlineMarks(content('ab **x** c'), caret: 2);
      expect(r.content.text, 'ab x c');
      expect(r.caret, 2);
    });

    test('开定界符内:clamp 到折叠区起点', () {
      final r = spinInlineMarks(content('**x**'), caret: 1);
      expect(r.content.text, 'x');
      expect(r.caret, 0);
    });

    test('内容内:减开定界符长', () {
      final r = spinInlineMarks(content('**bold**'), caret: 4); // bo|ld
      expect(r.caret, 2);
    });

    test('闭定界符内:clamp 到折叠后内容尾', () {
      final r = spinInlineMarks(content('**bold**'), caret: 7); // 闭 ** 中间
      expect(r.content.text, 'bold');
      expect(r.caret, 4);
    });

    test('命中区之后:左移两段定界符长', () {
      final r = spinInlineMarks(content('**x** tail'), caret: 8);
      expect(r.content.text, 'x tail');
      expect(r.caret, 4);
    });
  });

  group('排除与约束', () {
    test('inlineCode mark 覆盖区内的字面不折叠', () {
      final src = content(
        'code **x** here',
        marks: const [
          MarkSpan(start: 0, end: 15, kind: MarkKind.inlineCode),
        ],
      );
      final r = spinInlineMarks(src, caret: 0);
      expect(identical(r.content, src), isTrue, reason: '无命中原样返回');
      expect(r.content.text, 'code **x** here', reason: '代码字面量区不折叠');
    });

    test('首尾空格不折(CommonMark 语义)', () {
      final r = spinInlineMarks(content('** x**'), caret: 0);
      expect(r.content.text, '** x**');
      expect(r.content.marks, isEmpty);
    });

    test('内容含 \\n 不折(跨软换行不成对)', () {
      final r = spinInlineMarks(content('**a\nb**'), caret: 0);
      expect(r.content.text, '**a\nb**');
      expect(r.content.marks, isEmpty);
    });

    test('BBCode 内容含 [ 不折;HTML 内容含 < 不折', () {
      expect(
        spinInlineMarks(content('[u]a[b[/u]'), caret: 0).content.marks,
        isEmpty,
      );
      expect(
        spinInlineMarks(content('<small>a<b</small>'), caret: 0)
            .content
            .marks,
        isEmpty,
      );
    });

    test('link/图片字面第一期不折叠', () {
      expect(
        spinInlineMarks(content('[text](https://x)'), caret: 0).content.marks,
        isEmpty,
      );
      expect(
        spinInlineMarks(content('![alt](src)'), caret: 0).content.marks,
        isEmpty,
      );
    });

    test('原子哨兵在内容里照折,身份与位置随折叠平移', () {
      // '**a￼b**':原子在 3(开定界符后第 2 个内容字符)
      const emoji = EmojiRun(name: 'heart', url: 'u');
      final src = EditableTextContent(text: '**ab**')
          .insertAtom(3, emoji); // '**a￼b**'
      expect(src.text, '**a${kAtomChar}b**');
      final r = spinInlineMarks(src, caret: src.text.length);
      expect(r.content.text, 'a${kAtomChar}b');
      expect(r.content.marks.single.kind, MarkKind.strong);
      expect(r.content.atoms[1], emoji, reason: '原子身份保留、位置左移');
      expect(r.caret, 3);
    });
  });

  group('多对与循环折叠', () {
    test('多对依次折叠(最靠前优先)', () {
      final r = spinInlineMarks(content('**a** and ~~b~~'), caret: 15);
      expect(r.content.text, 'a and b');
      expect(r.content.marks.length, 2);
      expect(r.content.marks[0].kind, MarkKind.strong);
      expect(r.content.marks[1].kind, MarkKind.lineThrough);
      expect(r.content.marks[1].start, 6);
      expect(r.caret, 7);
    });

    test('嵌套 ***x*** 循环收敛为 strong+em', () {
      final r = spinInlineMarks(content('***x***'), caret: 7);
      expect(r.content.text, 'x');
      expect(
        r.content.marks.map((m) => m.kind).toSet(),
        {MarkKind.strong, MarkKind.em},
      );
      expect(r.caret, 1);
    });

    test('嵌套 **~~x~~** 循环收敛', () {
      final r = spinInlineMarks(content('**~~x~~**'), caret: 9);
      expect(r.content.text, 'x');
      expect(
        r.content.marks.map((m) => m.kind).toSet(),
        {MarkKind.strong, MarkKind.lineThrough},
      );
    });

    test('*bold** → em + 残 `*`', () {
      final r = spinInlineMarks(content('*bold**'), caret: 7);
      expect(r.content.text, 'bold*');
      expect(r.content.marks.single.kind, MarkKind.em);
      expect(r.content.marks.single.end, 4);
      expect(r.caret, 5);
    });
  });

  group('不动点与快退', () {
    test('无命中:content identical 返回', () {
      final plain = content('plain text with * lone star');
      final r = spinInlineMarks(plain, caret: 3);
      expect(identical(r.content, plain), isTrue);
      expect(r.caret, 3);
      // 已折叠产物再 spin = 不动点
      final once = spinInlineMarks(content('**x**'), caret: 0);
      final twice = spinInlineMarks(once.content, caret: once.caret);
      expect(identical(twice.content, once.content), isTrue);
    });

    test('快退路径:无任何定界符首字符直接原样返回', () {
      final plain = content('普通中文文本 plain 123');
      final r = spinInlineMarks(plain, caret: 5);
      expect(identical(r.content, plain), isTrue);
      expect(r.caret, 5);
    });

    test('caret 越界入参被 clamp', () {
      final r = spinInlineMarks(content('**x**'), caret: 99);
      expect(r.caret, 1);
    });
  });
}
