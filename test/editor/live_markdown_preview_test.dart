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

    test('嵌套 mark 定界符按序列化固定序排列(外开内闭)', () {
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
      // kMarkNestingOrder:strong 先于 em → 开 `**` `*`、闭 `*` `**`
      expect(result.span.toPlainText(), '***x***');
      final inlines =
          content.toInlines(forEditing: true, revealMarkdownAt: 0);
      final delims =
          inlines.whereType<EditingDelimiterRun>().map((d) => d.text).toList();
      expect(delims, ['**', '*', '*', '**']);
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
