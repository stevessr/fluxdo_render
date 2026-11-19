/// 投影式行内标记显形(live markdown preview)+ ir「进入物化/离开
/// 折叠」测试。
///
/// 两套机制的分工(ir 大一统后):
/// - **进入物化**:可物化 mark(strong/em/link/bbcode…)在 collapsed
///   光标落进 [start,end] 闭区间时整簇物化为**真实字面**(文档文本
///   就是 `**bold**`),字面区内是纯文本编辑;光标离开由 spin 折叠回
///   mark。物化/折叠是语义保持变换,不进 undo;
/// - **投影显形**:不可物化 mark(inlineCode 等)保持 mark 态,光标
///   贴近时两端显形**零逻辑宽**的渲染投影定界符 —— 文档模型/IME/
///   复制/序列化/undo 全部无感知,本文件的投影用例钉这个不变量。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
          '`\u{00A0}x\u{00A0}`', // NBSP 粘性内边距(codePad)在定界符内侧
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
    test('inlineCode 在 ir 下不物化:末端打字延伸、移动逐字符、退格删字', () {
      // inlineCode 不可物化(物化后内容里的 `*` 等会裸奔与外部配对),
      // ir 下保持 mark 态走投影显形;交互与 wysiwyg 完全一致。
      final state = EditorState(blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: 'a code b',
            marks: const [
              MarkSpan(start: 2, end: 6, kind: MarkKind.inlineCode)
            ],
          ),
        ),
      ])
        ..mode = EditorMode.ir;
      addTearDown(state.dispose);
      // 光标进 mark:不物化,文本原样
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 4)));
      var c = (state.blocks.first as TextBlock).content;
      expect(c.text, 'a code b', reason: 'inlineCode 不物化');
      expect(c.marks.single.kind, MarkKind.inlineCode);
      // 末端打字延伸(ProseMirror code mark 默认 inclusive)
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 6)));
      state.insertText('X');
      c = (state.blocks.first as TextBlock).content;
      expect(c.marks.single.end, 7, reason: '代码尾打字 = 继续代码');
      state.undo();
      // 移动逐字符,无停位
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 5)));
      state.moveCaretHorizontal(1);
      expect(state.selection!.extent.offset, 6);
      state.moveCaretHorizontal(1);
      expect(state.selection!.extent.offset, 7);
      // 末端退格 = 删字收缩
      state.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 6)));
      state.backspace();
      c = (state.blocks.first as TextBlock).content;
      expect(c.text, 'a cod b');
      expect(c.marks.single.end, 5);
    });

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

    // 注:inlineCode 现为 inclusive(ProseMirror code mark 默认/Typora
    // 同款),末端打字延伸,不在本用例;仅 link 与带 attr 的 mark 不延伸。
    test('link/带 attr 的 mark 末端不延伸', () {
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

  group('ir 进入物化/离开折叠(状态层)', () {
    EditorState makeState(EditableTextContent content,
        {EditorMode mode = EditorMode.ir}) {
      final s = EditorState(blocks: [TextBlock(id: 'e_0', content: content)])
        ..mode = mode;
      addTearDown(s.dispose);
      return s;
    }

    void caretAt(EditorState s, int offset) {
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: offset)));
    }

    TextBlock first(EditorState s) => s.blocks.first as TextBlock;

    EditableTextContent midMark() => EditableTextContent(
          text: 'ab bold cd',
          marks: const [MarkSpan(start: 3, end: 7, kind: MarkKind.strong)],
        );

    test('光标落进 mark → 整簇物化为字面,caret 映射到字面坐标', () {
      final s = makeState(midMark());
      caretAt(s, 5); // 'ab bo|ld cd'
      final c = first(s).content;
      expect(c.text, 'ab **bold** cd', reason: '文本变真实字面');
      expect(c.marks, isEmpty, reason: 'mark 摘除');
      expect(s.selection!.extent.offset, 7,
          reason: '开定界符 `**` 在光标前插入 → +2');
      expect(s.canUndo, isFalse, reason: '物化不进 undo');
    });

    test('延迟收口:down 落进 mark 不物化,定性单击后才物化', () {
      // 手势按下路径(deferIrReconcile):按下瞬间分不清点击/拖选起点,
      // 不得立即物化 —— 从 mark 内部起拖时文本回流会让选区锚点错位。
      final s = makeState(midMark());
      s.updateSelection(
        const EditorSelection.collapsed(
            EditorPosition(blockId: 'e_0', offset: 5)),
        deferIrReconcile: true,
      );
      expect(first(s).content.text, 'ab bold cd',
          reason: 'down 阶段形态不变');
      expect(first(s).content.marks, hasLength(1));

      // 定性为拖选:扩成 range,cancel 延迟收口 → 全程不物化
      s.cancelDeferredIrReconcile();
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 5),
          extent: EditorPosition(blockId: 'e_0', offset: 9),
        ),
        deferIrReconcile: true,
      );
      s.commitDeferredIrReconcile(); // panEnd:终态 range → no-op
      expect(first(s).content.text, 'ab bold cd',
          reason: '选择存续期间不展开');
      expect(first(s).content.marks, hasLength(1));

      // 定性为单击(tapUp):补收口 → 物化
      final s2 = makeState(midMark());
      s2.updateSelection(
        const EditorSelection.collapsed(
            EditorPosition(blockId: 'e_0', offset: 5)),
        deferIrReconcile: true,
      );
      s2.commitDeferredIrReconcile();
      expect(first(s2).content.text, 'ab **bold** cd');
      expect(s2.selection!.extent.offset, 7);
      // 重复 commit 幂等(无挂起 = no-op,不会把驻留态错误重物化)
      s2.commitDeferredIrReconcile();
      expect(first(s2).content.text, 'ab **bold** cd');
    });

    test('边界含语义:贴 start/end 也进入物化,光标落定界符外侧', () {
      final sStart = makeState(midMark());
      caretAt(sStart, 3); // 贴 start
      expect(first(sStart).content.text, 'ab **bold** cd');
      expect(sStart.selection!.extent.offset, 3,
          reason: 'start 处物化停开定界符前(外侧)');

      final sEnd = makeState(midMark());
      caretAt(sEnd, 7); // 贴 end
      expect(first(sEnd).content.text, 'ab **bold** cd');
      expect(sEnd.selection!.extent.offset, 11,
          reason: 'end 处物化停闭定界符后(外侧)—— 此处打字落格式外');
    });

    test('字面区内左右移动逐字符;移出区间边界即折叠', () {
      final s = makeState(midMark());
      caretAt(s, 6); // 物化,caret 8('ab **bol|d** cd')
      expect(s.selection!.extent.offset, 8);
      s.moveCaretHorizontal(1); // 9 = 内容尾
      expect(s.selection!.extent.offset, 9);
      s.moveCaretHorizontal(1); // 10 = 闭定界符中间,真实坐标
      expect(s.selection!.extent.offset, 10);
      expect(first(s).content.text, 'ab **bold** cd',
          reason: '仍在区间内部,守卫保持展开');
      s.moveCaretHorizontal(1); // 11 = 区间边界:闭区间守卫,仍驻留
      expect(first(s).content.text, 'ab **bold** cd',
          reason: '贴边不折(在边界补字符是正当编辑)');
      s.moveCaretHorizontal(1); // 12 = 彻底离开 → 折叠
      expect(first(s).content.text, 'ab bold cd');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 8, reason: '折叠后回内容坐标');
      // 左移:8 在 mark.end(7)之外一格 → 再左移落 7(闭区间)重新物化
      s.moveCaretHorizontal(-1);
      expect(first(s).content.text, 'ab **bold** cd',
          reason: '左移回落 mark 区间即再物化');
    });

    test('字面区内退格删格式符字符,残余语法移出后按新语法折叠', () {
      final s = makeState(midMark());
      caretAt(s, 4); // 物化 'ab **bold** cd'
      caretAt(s, 5); // 'ab **|bold** cd'(开定界符后)
      s.backspace(); // 删掉一个开 `*`
      var c = first(s).content;
      expect(c.text, 'ab *bold** cd', reason: '格式符也是字符,退格即删');
      expect(c.marks, isEmpty, reason: '光标驻留,字面保持不折');
      expect(s.canUndo, isTrue, reason: '字面区内真实编辑记历史');
      // 移出 → spin 按新语法折:*bold* 成 em,残尾 `*` 留字面
      caretAt(s, c.length);
      c = first(s).content;
      expect(c.text, 'ab bold* cd');
      expect(c.marks.single.kind, MarkKind.em, reason: '降级为斜体');
      expect(c.marks.single.start, 3);
      expect(c.marks.single.end, 7);
    });

    test('字面区内打字 = 纯文本插入(含末端)', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4); // 物化 '**bold**',caret 8(闭定界符后 = 外侧)
      expect(s.selection!.extent.offset, 8);
      caretAt(s, 6); // 移回内容尾(闭区间守卫,字面保持)
      s.insertText('x');
      var c = first(s).content;
      expect(c.text, '**boldx**', reason: '字面后追加纯文本,无延伸特判');
      expect(c.marks, isEmpty);
      // 字面占满整块,块内任意位置均驻留 → 失焦收口折叠
      s.updateSelection(null);
      c = first(s).content;
      expect(c.text, 'boldx');
      expect(c.marks.single.kind, MarkKind.strong);
      expect(c.marks.single.end, 5);
    });

    test('mark 末端进入后打字落格式外(Vditor 语义)', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4); // 物化,caret 8 = 闭 `**` 后
      s.insertText('x'); // 光标已在字面对外 → spin 折叠,x 是普通文本
      final c = first(s).content;
      expect(c.text, 'boldx');
      expect(c.marks.single.kind, MarkKind.strong);
      expect(c.marks.single.end, 4, reason: '新打的 x 不在粗体内');
      expect(s.selection!.extent.offset, 5);
    });

    test('link 进入物化:label/href 全量可编辑,离开折叠', () {
      final s = makeState(EditableTextContent(
        text: 'go here now',
        marks: const [
          MarkSpan(start: 3, end: 7, kind: MarkKind.link, attr: '/t/1'),
        ],
      ));
      caretAt(s, 5);
      var c = first(s).content;
      expect(c.text, 'go [here](/t/1) now');
      expect(c.marks, isEmpty);
      expect(s.selection!.extent.offset, 6, reason: 'label 内原位平移 +1');
      // 编辑 href
      final closeParen = c.text.indexOf(')');
      s.updateSelection(EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: closeParen)));
      s.insertText('23');
      // 光标移出 → 折叠回 link,href 更新
      caretAt(s, first(s).content.length);
      c = first(s).content;
      expect(c.text, 'go here now');
      expect(c.marks.single.kind, MarkKind.link);
      expect(c.marks.single.attr, '/t/123');
    });

    test('inlineCode 不物化(投影显形兜底)', () {
      final s = makeState(EditableTextContent(
        text: 'a code b',
        marks: const [MarkSpan(start: 2, end: 6, kind: MarkKind.inlineCode)],
      ));
      caretAt(s, 4);
      final c = first(s).content;
      expect(c.text, 'a code b');
      expect(c.marks.single.kind, MarkKind.inlineCode);
    });

    test('嵌套簇整体物化;交错折不回的簇不物化(路过不毁格式)', () {
      // 中部嵌套:strong 包 em,可安全往返 → 整簇展开
      final nested = makeState(EditableTextContent(
        text: 'abcd tail',
        marks: const [
          MarkSpan(start: 0, end: 4, kind: MarkKind.strong),
          MarkSpan(start: 1, end: 3, kind: MarkKind.em),
        ],
      ));
      caretAt(nested, 2);
      expect(first(nested).content.text, '**a*bc*d** tail');
      expect(first(nested).content.marks, isEmpty);
      caretAt(nested, 14); // 移到 mark 外(闭区间之外)
      final back = first(nested).content;
      expect(back.text, 'abcd tail', reason: '离开后整簇折回');
      expect(back.marks, hasLength(2));

      // 交错(em[0,3) + strong[1,3)):字面 `*a**bc***`。em 规则的
      // 闭端 lookahead(cook 对齐)下该组合可正确折回原结构 —— 整簇
      // 往返探针放行物化,离开后无损折回。
      final skewed = makeState(EditableTextContent(
        text: 'abc',
        marks: const [
          MarkSpan(start: 0, end: 3, kind: MarkKind.em),
          MarkSpan(start: 1, end: 3, kind: MarkKind.strong),
        ],
      ));
      caretAt(skewed, 2);
      expect(first(skewed).content.text, '*a**bc***');
      skewed.updateSelection(null); // 失焦收口
      final c = first(skewed).content;
      expect(c.text, 'abc', reason: '往返无损');
      expect(c.marks, hasLength(2));
    });

    test('undo:字面区内编辑记历史,快照回到编辑时刻的物化态', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 2); // 物化 '**bold**',caret 4
      s.insertText('X'); // '**boXld**'
      s.sealHistory();
      s.updateSelection(null); // 字面占满整块,失焦收口 → boXld + strong
      expect(first(s).content.text, 'boXld');
      s.undo();
      final c = first(s).content;
      expect(c.text, '**bold**',
          reason: 'undo 快照 = 编辑时刻的物化态字面(折叠不进历史)');
      expect(c.marks, isEmpty);
      expect(s.selection!.extent.offset, 4,
          reason: '光标回编辑点 = 守卫成立,字面保持');
      // 字面占满整块 → 失焦收口照常折叠回 mark
      s.updateSelection(null);
      expect(first(s).content.text, 'bold');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
    });

    test('imeReplace 纯移动(平台方向键)同样走进入物化/离开折叠', () {
      final s = makeState(EditableTextContent(
        text: 'bold tail',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 2); // 物化 '**bold** tail'
      expect(first(s).content.text, '**bold** tail');
      s.imeReplace('e_0', 12, 12, '', caretOffset: 12); // 纯移动出区间
      expect(first(s).content.text, 'bold tail', reason: '纯移动收口折叠');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
    });

    test('range 选区不触发物化;物化字面在扩选期间保持(布局稳定)', () {
      // mark 态起手:range 覆盖 mark 不物化(选择中不动布局)
      final s = makeState(midMark());
      s.updateSelection(const EditorSelection(
        base: EditorPosition(blockId: 'e_0', offset: 2),
        extent: EditorPosition(blockId: 'e_0', offset: 8),
      ));
      expect(first(s).content.text, 'ab bold cd');
      expect(first(s).content.marks, hasLength(1));

      // 物化态起手:shift 扩选期间字面保持(真实文本,端点真实坐标),
      // collapse 到区间外才折叠
      final s2 = makeState(midMark());
      caretAt(s2, 5); // 物化,caret 7
      s2.moveCaretHorizontal(1, extend: true);
      expect(first(s2).content.text, 'ab **bold** cd', reason: '扩选不折');
      expect(s2.selection!.extent.offset, 8);
      caretAt(s2, 13); // collapse 到区外(字面坐标)
      expect(first(s2).content.text, 'ab bold cd');
      expect(first(s2).content.marks.single.kind, MarkKind.strong);
    });

    test('wysiwyg:光标进 mark 不物化,文档形态恒定', () {
      final s = makeState(midMark(), mode: EditorMode.wysiwyg);
      caretAt(s, 5);
      expect(first(s).content.text, 'ab bold cd');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      caretAt(s, 3);
      s.backspace(); // 删 mark 前的空格,mark 完好左移
      final c = first(s).content;
      expect(c.text, 'abbold cd');
      expect(c.marks.single.kind, MarkKind.strong, reason: 'mark 完好');
      expect(c.marks.single.start, 2);
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
      required EditableTextContent content,
      EditorMode mode = EditorMode.ir,
      int caretOffset = 2,
    }) async {
      final state = EditorState(
        blocks: [TextBlock(id: 'e_0', content: content)],
      )..mode = mode;
      addTearDown(state.dispose);
      state.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: caretOffset),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FluxdoEditor(
              state: state,
              autofocus: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return state;
    }

    EditableTextContent strongContent() => EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        );

    EditableTextContent codeContent() => EditableTextContent(
          text: 'a code b',
          marks: const [MarkSpan(start: 2, end: 6, kind: MarkKind.inlineCode)],
        );

    String paragraphText(WidgetTester tester) => tester
        .widget<RichText>(
          find.descendant(
            of: find.byType(EditableParagraph),
            matching: find.byType(RichText),
          ),
        )
        .text
        .toPlainText();

    testWidgets('可物化 mark:光标进出时字面出现/消失(物化非投影)',
        (tester) async {
      // ir 下光标在 offset 2 → 物化,渲染文本 = 模型文本 = 真实字面
      final state = await pumpEditor(tester, content: strongContent());
      expect(paragraphText(tester), '**bold** tail');
      expect((state.blocks.first as TextBlock).content.text, '**bold** tail',
          reason: '字面在模型里(物化),不是渲染投影');

      // 光标移出字面对区间 → 折叠
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 10),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), 'bold tail');
      expect((state.blocks.first as TextBlock).content.marks, hasLength(1));

      // 回到 mark 边界(offset 4 = mark.end,闭区间)→ 重新物化
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 4),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), '**bold** tail');
    });

    testWidgets('inlineCode:投影显形出现/消失,range 立即折叠',
        (tester) async {
      final state = await pumpEditor(
        tester,
        content: codeContent(),
        caretOffset: 4,
      );
      // NBSP 粘性内边距(codePad)恒在;显形加反引号
      expect(paragraphText(tester), 'a `\u{00A0}code\u{00A0}` b');
      expect((state.blocks.first as TextBlock).content.text, 'a code b',
          reason: '投影零模型泄漏');

      // 光标移出 → 显形消失(NBSP pad 保留)
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 8),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), 'a \u{00A0}code\u{00A0} b');

      // range 选区 → 不显形(Vditor 语义:显形只跟随 collapsed 光标,
      // 选择过程不显示格式符 —— 高亮不框进定界符,选择全程布局稳定)
      state.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 3),
          extent: EditorPosition(blockId: 'e_0', offset: 5),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), 'a \u{00A0}code\u{00A0} b');
    });

    testWidgets('wysiwyg 模式(默认)不显形不物化', (tester) async {
      final state = await pumpEditor(
        tester,
        content: strongContent(),
        mode: EditorMode.wysiwyg,
      );
      expect(paragraphText(tester), 'bold tail');
      expect((state.blocks.first as TextBlock).content.text, 'bold tail');
    });

    testWidgets('wysiwyg:任意选区序列渲染文本永不含定界符', (tester) async {
      final state = await pumpEditor(
        tester,
        content: strongContent(),
        mode: EditorMode.wysiwyg,
      );
      expect(paragraphText(tester), 'bold tail');
      // collapsed 进 mark → range → 折叠回,全程无定界符
      for (final sel in const [
        EditorSelection.collapsed(EditorPosition(blockId: 'e_0', offset: 4)),
        EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 1),
          extent: EditorPosition(blockId: 'e_0', offset: 3),
        ),
        EditorSelection.collapsed(EditorPosition(blockId: 'e_0', offset: 2)),
      ]) {
        state.updateSelection(sel);
        await tester.pump();
        expect(paragraphText(tester), 'bold tail');
      }
    });

    testWidgets('ir:Shift 扩选期间物化字面保持(真实文本,布局稳定)',
        (tester) async {
      // 光标 offset 2 → 物化 '**bold** tail',caret 4
      final state = await pumpEditor(tester, content: strongContent());
      expect(paragraphText(tester), '**bold** tail');

      // Shift+ArrowRight 扩选成 range:字面是真实文本,扩选期间保持
      // (不像投影显形会折叠)—— 端点在同一布局上逐字符推进
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(state.selection!.isCollapsed, isFalse);
      expect(paragraphText(tester), '**bold** tail');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(state.selection!.extent.offset, 7, reason: '真实坐标逐字符');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      // collapse 到区间外 → 折叠
      state.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 12),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), 'bold tail');
    });

    testWidgets('ir:mark 态起手的程序化 range 不物化(选择中无格式符)',
        (tester) async {
      // 光标先放 mark 外(不物化)
      final state = await pumpEditor(
        tester,
        content: strongContent(),
        caretOffset: 6,
      );
      expect(paragraphText(tester), 'bold tail');

      // 直接 updateSelection 到覆盖 mark 的 range(拖选松手后的稳态)
      state.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 1),
          extent: EditorPosition(blockId: 'e_0', offset: 3),
        ),
      );
      await tester.pump();
      expect(paragraphText(tester), 'bold tail',
          reason: '选择态不物化不显形');

      // 多帧后依旧
      await tester.pump();
      await tester.pump();
      expect(paragraphText(tester), 'bold tail');
    });

    testWidgets('composing 期间不显形(IME 预编辑不受扰,inlineCode 投影)',
        (tester) async {
      final state = await pumpEditor(
        tester,
        content: codeContent(),
        caretOffset: 4,
      );
      expect(paragraphText(tester), 'a `\u{00A0}code\u{00A0}` b');

      state.updateComposing(const TextRange(start: 0, end: 2));
      await tester.pump();
      expect(paragraphText(tester), 'a \u{00A0}code\u{00A0} b');

      state.updateComposing(TextRange.empty);
      await tester.pump();
      expect(paragraphText(tester), 'a `\u{00A0}code\u{00A0}` b');
    });

    testWidgets('IME 窗口喂的文本 = content.text 原文(投影定界符不混入)',
        (tester) async {
      final state = await pumpEditor(
        tester,
        content: codeContent(),
        caretOffset: 4,
      );
      expect(paragraphText(tester), 'a `\u{00A0}code\u{00A0}` b');

      // 捕获最后一次 setEditingState:平台侧文本 = pad + 原文,零投影
      // 定界符/零 NBSP pad
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
      expect(sent!.text.contains('`'), isFalse);
      expect(sent.text, ' ${tb.content.text}'); // 段首 pad + 原文
    });
  });
}
