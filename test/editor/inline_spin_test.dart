/// ir spin 纯函数(inline_spin.dart)测试:整块扫描折叠完整字面标记对、
/// caret 重映射、排除区、循环不动点、快退路径。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
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

  group('caret 重映射(guardAtCaret: false,收口全折场景)', () {
    test('命中区之前:caret 不动', () {
      final r = spinInlineMarks(content('ab **x** c'), caret: 2);
      expect(r.content.text, 'ab x c');
      expect(r.caret, 2);
    });

    test('开定界符内:clamp 到折叠区起点', () {
      final r = spinInlineMarks(content('**x**'), caret: 1, guardAtCaret: false);
      expect(r.content.text, 'x');
      expect(r.caret, 0);
    });

    test('内容内:减开定界符长', () {
      final r = spinInlineMarks(content('**bold**'),
          caret: 4, guardAtCaret: false); // bo|ld
      expect(r.caret, 2);
    });

    test('闭定界符内:clamp 到折叠后内容尾', () {
      final r = spinInlineMarks(content('**bold**'),
          caret: 7, guardAtCaret: false); // 闭 ** 中间
      expect(r.content.text, 'bold');
      expect(r.caret, 4);
    });

    test('守卫开(默认):caret 在字面对内部不折(光标驻留展开态)', () {
      final src = content('**bold**');
      final r = spinInlineMarks(src, caret: 4);
      expect(identical(r.content, src), isTrue,
          reason: '光标在字面内 = 正在编辑,保持字面');
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

    test('内容含空行不折(不可跨段落成对)', () {
      final r = spinInlineMarks(content('**a\n\nb**'), caret: 0);
      expect(r.content.text, '**a\n\nb**');
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

    test('link 字面折叠为 link mark(caret 守卫:光标在内不折)', () {
      // 光标在字面区间外(caret 0 == m.start 不算内部)→ 折叠
      final folded = spinInlineMarks(content('a [text](https://x) b'), caret: 0);
      expect(folded.content.text, 'a text b');
      final link =
          folded.content.marks.firstWhere((m) => m.kind == MarkKind.link);
      expect(link.attr, 'https://x');
      // 光标在字面区间内部(正在编辑 href)→ 守卫挡住不折
      final guarded =
          spinInlineMarks(content('a [text](https://x) b'), caret: 12);
      expect(guarded.content.marks, isEmpty);
      expect(guarded.content.text, 'a [text](https://x) b');
    });

    test('图片字面不折叠(原子语义,交给 input rules/cook)', () {
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

  group('v2:mark 与字面混合重解析(物化 → 重折叠)', () {
    test('link 编辑闭环:光标进入即物化 → 改 href → 光标离开折叠回 link', () {
      final s = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: 'go here now',
            marks: const [
              MarkSpan(start: 3, end: 7, kind: MarkKind.link, attr: '/t/1'),
            ],
          ),
        ),
      ])
        ..mode = EditorMode.ir;
      addTearDown(s.dispose);
      // 光标落进 label 中间 → updateSelection 单点收口自动物化
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 5)));
      var c = (s.blocks.first as TextBlock).content;
      expect(c.text, 'go [here](/t/1) now');
      expect(c.marks, isEmpty);
      expect(s.selection!.extent.offset, 6, reason: 'label 内原位平移 +1');
      // 光标在字面内移动/编辑:caret 守卫挡住,不折
      final closeParen = c.text.indexOf(')');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: closeParen)));
      s.insertText('23');
      c = (s.blocks.first as TextBlock).content;
      expect(c.text, 'go [here](/t/123) now', reason: 'href 直接可编辑');
      // 光标离开 → updateSelection 收口折叠回 link
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: c.length)));
      c = (s.blocks.first as TextBlock).content;
      expect(c.text, 'go here now');
      final link = c.marks.singleWhere((m) => m.kind == MarkKind.link);
      expect(link.attr, '/t/123');
      // undo:物化/折叠不进历史,一步回到「编辑 href 之前」;快照是
      // 编辑发生时的物化态(光标也恢复在字面区内 = 展开态成立),字面
      // 保持显示;光标移开后照常折叠回原 link。
      s.undo();
      var r = (s.blocks.first as TextBlock).content;
      expect(r.text, 'go [here](/t/1) now');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: r.length)));
      r = (s.blocks.first as TextBlock).content;
      expect(r.text, 'go here now');
      expect(r.marks.single.attr, '/t/1');
    });

    test('wysiwyg:光标进 link 不物化', () {
      final s = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: 'here',
            marks: const [
              MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: '/a'),
            ],
          ),
        ),
      ]);
      addTearDown(s.dispose);
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 2)));
      expect((s.blocks.first as TextBlock).content.marks, isNotEmpty);
      expect((s.blocks.first as TextBlock).content.text, 'here');
    });

    test('em 前后各补一个 * → strong(用户场景:*1* 升级 **1**)', () {
      // 字面`*` + em(1) + 字面`*`:v1 纯字面扫描看不见 mark,序列化是
      // **1** 却永远不渲染粗体;v2 物化 em 得 `**1**` 整体重折叠。
      final r = spinInlineMarks(
        content('*1*',
            marks: const [MarkSpan(start: 1, end: 2, kind: MarkKind.em)]),
        caret: 3,
      );
      expect(r.content.text, '1');
      expect(r.content.marks.single.kind, MarkKind.strong);
    });

    test('中间态:em 前打 * 折不回 → 放弃本轮,保持字面+mark 混合', () {
      // `*` + em(1) = 字面 `**1*`:em 规则 lookbehind 拒绝、strong 内容
      // 非空要求拒绝 —— 折叠产出 0 结构 < 输入 1 结构,回归防线放弃,
      // 视觉与 CommonMark 对 `**1*` 的解析一致(等补全再折)。
      final input = content('*1',
          marks: const [MarkSpan(start: 1, end: 2, kind: MarkKind.em)]);
      final r = spinInlineMarks(input, caret: 1);
      expect(identical(r.content, input), isTrue);
    });

    test('strong 内容中补 ~~ 对 → 嵌套折叠(光标在外/收口)', () {
      // strong("a~~x~~b") 物化 → `**a~~x~~b**`。光标在外层内容区(a 后)
      // 但不在内层 `~~x~~` 里:内层照折、外层守卫保持(Vditor「光标所在
      // 节点展开,其余折叠」);收口(guardAtCaret: false)全折成嵌套 mark。
      final src = content('a~~x~~b',
          marks: const [MarkSpan(start: 0, end: 7, kind: MarkKind.strong)]);
      final held = spinInlineMarks(src, caret: 1);
      expect(held.content.text, '**axb**',
          reason: '内层 ~~x~~ 折叠,外层(光标驻留)保持字面');
      expect(held.content.marks.single.kind, MarkKind.lineThrough);
      final folded = spinInlineMarks(src, caret: 7, guardAtCaret: false);
      expect(folded.content.text, 'axb');
      expect(folded.content.marks, hasLength(2));
      expect(folded.content.marks.map((m) => m.kind).toSet(),
          {MarkKind.strong, MarkKind.lineThrough});
    });

    test('往返不动点:纯 mark 内容 spin 后 identical', () {
      final input = content('a bold b',
          marks: const [MarkSpan(start: 2, end: 6, kind: MarkKind.strong)]);
      final r = spinInlineMarks(input, caret: 4);
      expect(identical(r.content, input), isTrue);
      expect(r.caret, 4);
    });

    test('嵌套序保真:同区间列表序不翻转', () {
      // smallStyle 外 lineThrough 内(列表序承载 DOM 方向)物化再折叠
      // 后方向不变(compareSameSpanMarkOpen 同源发射)。
      final input = content('x', marks: const [
        MarkSpan(start: 0, end: 1, kind: MarkKind.smallStyle),
        MarkSpan(start: 0, end: 1, kind: MarkKind.lineThrough),
      ]);
      final r = spinInlineMarks(input, caret: 0);
      expect(identical(r.content, input), isTrue,
          reason: '往返等价 → identical(嵌套方向翻转的话 marks 序会变)');
    });

    test('link 不物化:锚文本与 href 完好,区间随外部折叠平移', () {
      final r = spinInlineMarks(
        content('**b** go',
            marks: const [
              MarkSpan(start: 6, end: 8, kind: MarkKind.link, attr: '/t/1'),
            ]),
        caret: 0,
      );
      expect(r.content.text, 'b go');
      final link = r.content.marks.firstWhere((m) => m.kind == MarkKind.link);
      expect(link.attr, '/t/1');
      expect(link.start, 2);
      expect(link.end, 4);
    });

    test('inlineCode 不物化:code 内容里的 * 不与外部字面配对', () {
      // code("a*b") + 后面字面 `*x*`:code 不物化,内容里的 `*` 不裸奔;
      // 后面的 `*x*` 照折 em。
      final r = spinInlineMarks(
        content('a*b *x* d',
            marks: const [
              MarkSpan(start: 0, end: 3, kind: MarkKind.inlineCode),
            ]),
        caret: 9,
      );
      expect(r.content.text, 'a*b x d');
      expect(r.content.marks.map((m) => m.kind).toSet(),
          {MarkKind.inlineCode, MarkKind.em});
      final code =
          r.content.marks.firstWhere((m) => m.kind == MarkKind.inlineCode);
      expect(code.start, 0);
      expect(code.end, 3, reason: 'code 区间原封不动');
    });

    test('atoms 随物化-折叠平移保真', () {
      const emoji = EmojiRun(name: 'smile', url: 'u');
      // em("x￼y") + 后补字面对:物化重折叠后原子身份/相对位置不变
      final input = EditableTextContent(
        text: '*x￼y*',
        marks: const [MarkSpan(start: 1, end: 4, kind: MarkKind.em)],
        atoms: const {2: emoji},
      );
      final r = spinInlineMarks(input, caret: 5);
      expect(r.content.text, 'x￼y');
      expect(r.content.marks.single.kind, MarkKind.strong);
      expect(r.content.atoms[1], emoji);
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
