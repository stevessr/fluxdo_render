/// 投影式行内标记显形(live markdown preview)测试。
///
/// 核心契约:定界符是**纯渲染投影**(EditingDelimiterRun 零逻辑宽),
/// 文档模型/IME/复制/序列化/undo 全部无感知 —— 每条反向固化都在钉死
/// 这个不变量。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/widget/editable_paragraph.dart';
import 'package:fluxdo_render/src/flatten/inline_flattener.dart';
import 'package:fluxdo_render/src/node/inline_node.dart'
    show EditingDelimiterRun, EmojiRun;

void main() {
  const flattener = InlineFlattener();

  group('投影双向映射', () {
    test('定界符只围绕光标命中的 mark 展开,零逻辑宽', () {
      final content = EditableTextContent(
        text: 'beforeboldafter',
        marks: const [MarkSpan(start: 6, end: 10, kind: MarkKind.strong)],
      );

      // 不显形:与阅读态同文本
      final collapsed = flattener.flatten(
        content.toInlines(forEditing: true),
        const TextStyle(fontSize: 14),
      );
      expect(collapsed.span.toPlainText(), content.text);
      expect(collapsed.projection.projectAll(), content.text);
      expect(collapsed.projection.contentLength, content.length);

      // 光标在 mark 内:两端显形,投影/内容长度不变
      final expanded = flattener.flatten(
        content.toInlines(forEditing: true, revealMarkdownAt: 8),
        const TextStyle(fontSize: 14),
      );
      expect(expanded.span.toPlainText(), 'before**bold**after');
      expect(expanded.projection.projectAll(), content.text);
      expect(expanded.projection.contentLength, content.length);
      // 内容→渲染:边界跳过零宽定界符
      expect(expanded.projection.renderOffsetForContent(6), 8);
      expect(expanded.projection.renderOffsetForContent(10), 14);
      // 末端语义(装饰框右界):恰在 mark.end 时归属到内容 entry 末端,
      // 不把随后的闭定界符 `**` 框进装饰(before**bold|**after → 12)
      expect(expanded.projection.renderEndForContent(10), 12);
      expect(expanded.projection.renderEndForContent(6), 6);
      // 渲染→内容:定界符内部坍缩(光标进不了定界符)
      expect(expanded.projection.contentOffsetForRender(6), 6);
      expect(expanded.projection.contentOffsetForRender(7), 6);
      expect(expanded.projection.contentOffsetForRender(12), 10);
      expect(expanded.projection.contentOffsetForRender(13), 10);

      // 光标在 mark 外:不显形
      final outside = flattener.flatten(
        content.toInlines(forEditing: true, revealMarkdownAt: 5),
        const TextStyle(fontSize: 14),
      );
      expect(outside.span.toPlainText(), content.text);
    });

    test('revealableMarksAt 边界含语义:贴 start/end 显形,移出消失', () {
      final content = EditableTextContent(
        text: 'ab bold cd',
        marks: const [MarkSpan(start: 3, end: 7, kind: MarkKind.strong)],
      );
      expect(content.revealableMarksAt(2), isEmpty);
      expect(content.revealableMarksAt(3), hasLength(1)); // 贴 start
      expect(content.revealableMarksAt(5), hasLength(1)); // 内部
      expect(content.revealableMarksAt(7), hasLength(1)); // 贴 end
      expect(content.revealableMarksAt(8), isEmpty);
    });
  });

  group('MarkKind 定界符文案(与序列化 _openTag/_closeTag 同源)', () {
    test('各 kind 显形形态与投影不变量', () {
      final cases = <(MarkSpan, String)>[
        (const MarkSpan(start: 0, end: 1, kind: MarkKind.strong), '**x**'),
        (const MarkSpan(start: 0, end: 1, kind: MarkKind.em), '*x*'),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.inlineCode),
          '` x `', // NBSP 粘性内边距(codePad)在定界符内侧
        ),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.underline),
          '[u]x[/u]',
        ),
        (const MarkSpan(start: 0, end: 1, kind: MarkKind.lineThrough), '~~x~~'),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.spoilerInline),
          '[spoiler]x[/spoiler]',
        ),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.link, attr: '/t/1'),
          '[x](/t/1)',
        ),
        // attr 类:定界符带原样 attr(mark.attr 存原文)
        (
          const MarkSpan(
              start: 0, end: 1, kind: MarkKind.textColor, attr: 'red'),
          '[color=red]x[/color]',
        ),
        (
          const MarkSpan(
              start: 0, end: 1, kind: MarkKind.bgColor, attr: '#F00'),
          '[bgcolor=#F00]x[/bgcolor]',
        ),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.size, attr: '150'),
          '[size=150]x[/size]',
        ),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.smallStyle),
          '<small>x</small>',
        ),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.bigStyle),
          '<big>x</big>',
        ),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.markStyle),
          '<mark>x</mark>',
        ),
        // sup/sub 内容渲染为 WidgetSpan(占 1 ￼),定界符是普通文本
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.superscript),
          '<sup>￼</sup>',
        ),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.subscript),
          '<sub>￼</sub>',
        ),
        (
          const MarkSpan(start: 0, end: 1, kind: MarkKind.monospaceStyle),
          '<kbd>x</kbd>',
        ),
      ];

      for (final (mark, rendered) in cases) {
        final content = EditableTextContent(text: 'x', marks: [mark]);
        final result = flattener.flatten(
          content.toInlines(forEditing: true, revealMarkdownAt: 1),
          const TextStyle(fontSize: 14),
        );
        expect(result.span.toPlainText(), rendered, reason: '${mark.kind}');
        expect(result.projection.projectAll(), 'x', reason: '${mark.kind}');
        expect(result.projection.contentLength, 1, reason: '${mark.kind}');
      }
    });

    test('嵌套 mark 定界符尊重列表序(外开内闭,与序列化同源)', () {
      // marks 列表序承载原 DOM 嵌套方向(parser 摊平时外层先入表):
      // [em, strong] = em 外 strong 内 → 开 `*` `**`、闭 `**` `*`。
      final content = EditableTextContent(
        text: 'x',
        marks: const [
          MarkSpan(start: 0, end: 1, kind: MarkKind.em),
          MarkSpan(start: 0, end: 1, kind: MarkKind.strong),
        ],
      );
      final result = flattener.flatten(
        content.toInlines(forEditing: true, revealMarkdownAt: 0),
        const TextStyle(fontSize: 14),
      );
      expect(result.span.toPlainText(), '***x***');
      final inlines =
          content.toInlines(forEditing: true, revealMarkdownAt: 0);
      final delims =
          inlines.whereType<EditingDelimiterRun>().map((d) => d.text).toList();
      expect(delims, ['*', '**', '**', '*']);

      // 反向列表序 [strong, em] = strong 外 em 内。
      final reversed = EditableTextContent(
        text: 'x',
        marks: const [
          MarkSpan(start: 0, end: 1, kind: MarkKind.strong),
          MarkSpan(start: 0, end: 1, kind: MarkKind.em),
        ],
      );
      final rDelims = reversed
          .toInlines(forEditing: true, revealMarkdownAt: 0)
          .whereType<EditingDelimiterRun>()
          .map((d) => d.text)
          .toList();
      expect(rDelims, ['**', '*', '*', '**']);
    });
  });

  group('末端打字延伸(inclusive marks)', () {
    test('insertText 在 mark 末端:格式延伸覆盖新字符', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: 'bold tail',
            marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
          ),
        ),
      ]);
      addTearDown(state.dispose);
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 4)));
      state.insertText('X');
      final c = (state.blocks.first as TextBlock).content;
      expect(c.text, 'boldX tail');
      expect(c.marks.single, isA<MarkSpan>());
      expect(c.marks.single.end, 5, reason: '粗体末尾打字 = 继续粗体');
    });

    test('imeReplace 纯插入在 mark 末端:同样延伸', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: 'bold',
            marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
          ),
        ),
      ]);
      addTearDown(state.dispose);
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 4)));
      state.imeReplace('e_0', 4, 4, '呀', caretOffset: 5);
      final c = (state.blocks.first as TextBlock).content;
      expect(c.text, 'bold呀');
      expect(c.marks.single.end, 5);
    });

    test('link/inlineCode/带 attr 的 mark 末端不延伸', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: 'abcd',
            marks: const [
              MarkSpan(start: 0, end: 2, kind: MarkKind.link, attr: 'https://x'),
              MarkSpan(start: 2, end: 4, kind: MarkKind.size, attr: '150'),
            ],
          ),
        ),
      ]);
      addTearDown(state.dispose);
      // link 末端
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 2)));
      state.insertText('Y');
      var c = (state.blocks.first as TextBlock).content;
      final link = c.marks.firstWhere((m) => m.kind == MarkKind.link);
      expect(link.end, 2, reason: '链接尾打字不长出链接');
      // size(带 attr)末端
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 5)));
      state.insertText('Z');
      c = (state.blocks.first as TextBlock).content;
      final size = c.marks.firstWhere((m) => m.kind == MarkKind.size);
      expect(size.end, 5, reason: '带 attr 的 mark 不隐式延伸');
    });

    test('mark 内部/前端插入语义不变(回归)', () {
      final state = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: 'bold',
            marks: const [MarkSpan(start: 1, end: 3, kind: MarkKind.strong)],
          ),
        ),
      ]);
      addTearDown(state.dispose);
      // mark.start 处插入:mark 右移不吸收
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1)));
      state.insertText('P');
      final c = (state.blocks.first as TextBlock).content;
      expect(c.marks.single.start, 2);
      expect(c.marks.single.end, 4);
    });
  });

  group('mark 末端边界二态(内侧/外侧)', () {
    EditorState makeState(EditableTextContent content) {
      final s = EditorState(blocks: [TextBlock(id: 'e_0', content: content)]);
      addTearDown(s.dispose);
      return s;
    }

    void caretAt(EditorState s, int offset) {
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: offset)));
    }

    test('右移序列:mark 内 → end 内侧 → end 外侧 → 下一字符;左移对称', () {
      // 'bold tail',strong [0,4):3 → 4内 → 4外 → 5;5 → 4外 → 4内 → 3
      final s = makeState(EditableTextContent(
        text: 'bold tail',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 3);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 4);
      expect(s.caretOutsideMarkEnd, isFalse, reason: '先停内侧');
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 4, reason: '内容坐标不动');
      expect(s.caretOutsideMarkEnd, isTrue, reason: '第二步切外侧');
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 5);
      expect(s.caretOutsideMarkEnd, isFalse, reason: '离开 end 复位');
      // 左移对称
      s.moveCaretHorizontal(-1);
      expect(s.selection!.extent.offset, 4);
      expect(s.caretOutsideMarkEnd, isTrue, reason: '左移落 end 先停外侧');
      s.moveCaretHorizontal(-1);
      expect(s.selection!.extent.offset, 4, reason: '内容坐标不动');
      expect(s.caretOutsideMarkEnd, isFalse, reason: '再一步切内侧');
      s.moveCaretHorizontal(-1);
      expect(s.selection!.extent.offset, 3);
    });

    test('内侧打字延伸格式;外侧打字不延伸(段末追加普通文本的出口)', () {
      // 内侧
      final sIn = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(sIn, 4);
      sIn.insertText('X');
      var c = (sIn.blocks.first as TextBlock).content;
      expect(c.text, 'boldX');
      expect(c.marks.single.end, 5, reason: '内侧打字延伸');

      // 外侧(mark 到段末:这是「格式后加普通文本」的唯一出口)
      final sOut = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(sOut, 4);
      sOut.moveCaretHorizontal(1); // 切外侧
      expect(sOut.caretOutsideMarkEnd, isTrue);
      sOut.insertText('Y');
      c = (sOut.blocks.first as TextBlock).content;
      expect(c.text, 'boldY');
      expect(c.marks.single.end, 4, reason: '外侧打字不延伸,追加普通文本');
      expect(sOut.caretOutsideMarkEnd, isFalse,
          reason: '插入落地后复位(光标已在普通文本内)');
    });

    test('imeReplace 纯插入:外侧同样不延伸', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1); // 切外侧
      s.imeReplace('e_0', 4, 4, '呀', caretOffset: 5);
      final c = (s.blocks.first as TextBlock).content;
      expect(c.text, 'bold呀');
      expect(c.marks.single.end, 4, reason: '外侧 IME 打字不延伸');
      expect(s.caretOutsideMarkEnd, isFalse);
    });

    test('点击/updateSelection 重置为内侧(含同位置重设)', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1);
      expect(s.caretOutsideMarkEnd, isTrue);
      // 同位置重设(点击同一坐标):早退前也要切回内侧
      caretAt(s, 4);
      expect(s.caretOutsideMarkEnd, isFalse);
      // 再切外侧后跳到别处
      s.moveCaretHorizontal(1);
      expect(s.caretOutsideMarkEnd, isTrue);
      caretAt(s, 1);
      expect(s.caretOutsideMarkEnd, isFalse);
    });

    test('扩选不参与二态:shift 右移直接按内容坐标扩', () {
      final s = makeState(EditableTextContent(
        text: 'bold tail',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1, extend: true);
      expect(s.selection!.extent.offset, 5, reason: '扩选跳过边界二态');
      expect(s.selection!.isCollapsed, isFalse);
    });

    test('非 inclusive mark(link)end 不参与二态:右移直接过', () {
      final s = makeState(EditableTextContent(
        text: 'link tail',
        marks: const [
          MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
        ],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 5, reason: 'link 无内侧停位');
      expect(s.caretOutsideMarkEnd, isFalse);
    });
  });

  group('反向固化:显形零模型泄漏', () {
    test('显形态 docToMarkdown 输出无虚拟定界符(字面 ** 邻居场景)', () {
      // 'x**2 bold':字面 ** 与真 strong mark 共存(打穿字面替换方案的
      // 场景)—— 显形是渲染投影,序列化前后字节不变。
      final block = TextBlock(
        id: 'e_0',
        content: EditableTextContent(
          text: 'x**2 bold',
          marks: const [MarkSpan(start: 5, end: 9, kind: MarkKind.strong)],
        ),
      );
      final state = EditorState(blocks: [block]);
      addTearDown(state.dispose);

      final before = docToMarkdown(state.blocks);
      // 进入显形态(光标进 mark)再序列化 —— 输出必须逐字节相同
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 6),
        ),
      );
      final during = docToMarkdown(state.blocks);
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 0),
        ),
      );
      final after = docToMarkdown(state.blocks);

      expect(during, before);
      expect(after, before);
      // 字面 ** 被转义、真 mark 写定界符;显形的虚拟定界符不混入
      expect(before, r'x\*\*2 **bold**');
    });

    test('显形态打字 = 普通编辑结果,无定界符混入', () {
      final state = EditorState(
        blocks: [
          TextBlock(
            id: 'e_0',
            content: EditableTextContent(
              text: 'bold tail',
              marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
            ),
          ),
        ],
      );
      addTearDown(state.dispose);
      // 光标在 mark 内(显形态)打字
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 2),
        ),
      );
      state.insertText('X');
      final tb = state.blocks.first as TextBlock;
      expect(tb.content.text, 'boXld tail');
      expect(tb.content.marks, const [
        MarkSpan(start: 0, end: 5, kind: MarkKind.strong),
      ]);
      expect(tb.content.text.contains('*'), isFalse);
    });

    test('显形态 undo 回到上一编辑状态,无显形残留物', () {
      final state = EditorState(
        blocks: [
          TextBlock(
            id: 'e_0',
            content: EditableTextContent(
              text: 'bold tail',
              marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
            ),
          ),
        ],
      );
      addTearDown(state.dispose);
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 2),
        ),
      );
      state.insertText('X');
      state.sealHistory();
      state.undo();
      final tb = state.blocks.first as TextBlock;
      expect(tb.content.text, 'bold tail');
      expect(tb.content.marks, const [
        MarkSpan(start: 0, end: 4, kind: MarkKind.strong),
      ]);
    });

    test('fromInlines 防御:EditingDelimiterRun 不落进文档模型', () {
      final content = EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      );
      // 显形产物直接喂回 fromInlines(理论不该发生的路径)——
      // 虚拟定界符必须被剥掉,不能变成字面 `**`。
      final revealed = content.toInlines(forEditing: true, revealMarkdownAt: 2);
      final round = EditableTextContent.fromInlines(revealed);
      expect(round.text, 'bold');
    });

    test('纯 emoji 段显形不掉出大表情档', () {
      final emoji = EmojiRun(name: 'heart', url: 'u', isOnlyEmoji: true);
      final content = EditableTextContent(
        text: '￼',
        marks: const [
          MarkSpan(start: 0, end: 1, kind: MarkKind.spoilerInline),
        ],
        atoms: {0: emoji},
      );
      final inlines = content.toInlines(forEditing: true, revealMarkdownAt: 0);
      final e = inlines.whereType<EmojiRun>().single;
      expect(e.isOnlyEmoji, isTrue);
    });
  });

  group('widget 级:焦点/选区/开关/IME', () {
    Future<EditorState> pumpEditor(
      WidgetTester tester, {
      bool liveMarkdownPreview = true,
    }) async {
      final state = EditorState(
        blocks: [
          TextBlock(
            id: 'e_0',
            content: EditableTextContent(
              text: 'bold tail',
              marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
            ),
          ),
        ],
      );
      addTearDown(state.dispose);
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 2),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FluxdoEditor(
              state: state,
              autofocus: true,
              liveMarkdownPreview: liveMarkdownPreview,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return state;
    }

    String paragraphText(WidgetTester tester) => tester
        .widget<RichText>(
          find.descendant(
            of: find.byType(EditableParagraph),
            matching: find.byType(RichText),
          ),
        )
        .text
        .toPlainText();

    testWidgets('光标进出 mark 时定界符出现/消失', (tester) async {
      final state = await pumpEditor(tester);
      expect(paragraphText(tester), '**bold** tail');

      // 光标移出 mark(offset 6 在 mark 外)→ 折叠
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 6),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), 'bold tail');

      // 回到边界(offset 4 = mark.end)→ 显形
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 4),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), '**bold** tail');

      // range 选区 → 不显形(仅 collapsed)
      state.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 1),
          extent: EditorPosition(blockId: 'e_0', offset: 3),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), 'bold tail');
    });

    testWidgets('liveMarkdownPreview=false 关闭显形', (tester) async {
      await pumpEditor(tester, liveMarkdownPreview: false);
      expect(paragraphText(tester), 'bold tail');
    });

    testWidgets('composing 期间不显形(IME 预编辑不受扰)', (tester) async {
      final state = await pumpEditor(tester);
      expect(paragraphText(tester), '**bold** tail');

      state.updateComposing(const TextRange(start: 0, end: 2));
      await tester.pump();
      expect(paragraphText(tester), 'bold tail');

      state.updateComposing(TextRange.empty);
      await tester.pump();
      expect(paragraphText(tester), '**bold** tail');
    });

    testWidgets('IME 窗口喂的文本 = content.text 原文(无定界符)',
        (tester) async {
      final state = await pumpEditor(tester);
      expect(paragraphText(tester), '**bold** tail');

      // 捕获最后一次 setEditingState:平台侧文本 = pad + 原文,零定界符
      TextEditingValue? sent;
      for (final call in tester.testTextInput.log) {
        if (call.method == 'TextInput.setEditingState') {
          sent = TextEditingValue.fromJSON(
            (call.arguments as Map).cast<String, dynamic>(),
          );
        }
      }
      expect(sent, isNotNull);
      final tb = state.blocks.first as TextBlock;
      expect(sent!.text.contains('*'), isFalse);
      expect(sent.text, ' ${tb.content.text}'); // 段首 pad + 原文
    });
  });
}
