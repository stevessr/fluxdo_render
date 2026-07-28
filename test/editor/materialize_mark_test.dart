/// 物化事务(阶段 B)测试:mark.end 闭端退格把 mark 还原为字面定界符,
/// undo 一步整体回滚,物化后改字面由 input rules 重新折叠。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/input_rules.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

EditorState makeState(EditableTextContent content) {
  // 本文件测的是 ir 模式语义(退格物化/边界二态);wysiwyg 门控回归
  // 见 editor_mode_test.dart。
  final s = EditorState(blocks: [TextBlock(id: 'e_0', content: content)])
    ..mode = EditorMode.ir;
  addTearDown(s.dispose);
  return s;
}

void caretAt(EditorState s, int offset) {
  s.updateSelection(EditorSelection.collapsed(
    EditorPosition(blockId: 'e_0', offset: offset),
  ));
}

TextBlock first(EditorState s) => s.blocks.first as TextBlock;

void main() {
  group('materializeMarkAt', () {
    test('strong 物化:mark 摘除、字面定界符进文本、光标落闭定界符末尾', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);
      expect(s.selection!.extent.offset, 8, reason: '闭定界符末尾');
    });

    test('undo 一步整体回滚(文本/marks/光标全还原);redo 重做', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      s.undo();
      expect(first(s).content.text, 'bold');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 4, reason: '光标还原到物化前');
      s.redo();
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);
    });

    test('嵌套:只物化目标 mark,其他 mark 区间随插入平移', () {
      // 'abc':em 覆盖全段 [0,3),strong 覆盖 'bc' [1,3)
      final s = makeState(EditableTextContent(
        text: 'abc',
        marks: const [
          MarkSpan(start: 0, end: 3, kind: MarkKind.em),
          MarkSpan(start: 1, end: 3, kind: MarkKind.strong),
        ],
      ));
      final strong = first(s)
          .content
          .marks
          .firstWhere((m) => m.kind == MarkKind.strong);
      s.materializeMarkAt('e_0', strong);
      final c = first(s).content;
      expect(c.text, 'a**bc**');
      expect(c.marks.single.kind, MarkKind.em);
      // 开定界符插在 em 内部(start<1<end)→ em 拉伸;闭定界符插在
      // em.end 边界 → 不延续(insert 的边界语义)
      expect(c.marks.single.start, 0);
      expect(c.marks.single.end, 5);
    });

    test('mark 后方的原子随插入平移,身份保留', () {
      const emoji = EmojiRun(name: 'heart', url: 'u');
      final s = makeState(EditableTextContent(
        text: 'hi$kAtomChar',
        marks: const [MarkSpan(start: 0, end: 2, kind: MarkKind.em)],
        atoms: const {2: emoji},
      ));
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      final c = first(s).content;
      expect(c.text, '*hi*$kAtomChar');
      expect(c.atoms[4], emoji);
      expect(c.marks, isEmpty);
    });

    test('link 物化:字面 [text](href),href 原样', () {
      final s = makeState(EditableTextContent(
        text: 'text',
        marks: const [
          MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
        ],
      ));
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      expect(first(s).content.text, '[text](https://x)');
      expect(first(s).content.marks, isEmpty);
    });

    test('陈旧 span(不在 content.marks 里)无操作', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      final rev = s.docRevision;
      s.materializeMarkAt(
          'e_0', const MarkSpan(start: 1, end: 3, kind: MarkKind.strong));
      expect(s.docRevision, rev);
      expect(first(s).content.text, 'bold');
    });

    test('物化后序列化 = 字面文本(定界符按普通文本转义,不再是样式)', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      expect(docToMarkdown(s.blocks), r'\*\*bold\*\*');
    });
  });

  group('闭端退格触发(B2)+ 边界二态', () {
    // 语义更新(边界二态):inclusive mark.end 上的退格物化只在**外侧**
    // 停位触发(caretAt 默认内侧,先右移一次切外侧);内侧退格 = 删格式
    // 内最后一个字符,mark 自然收缩。
    //
    // 复合退格(ir spin 阶段):一次外侧退格 = 物化 + 同一事务删掉闭
    // 定界符末一个字符(Vditor「退格删格式符字符」语义)。
    test('外侧停位退格 → 物化并吃掉闭定界符末字符', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1); // 内侧 → 外侧(内容坐标不动)
      expect(s.caretOutsideMarkEnd, isTrue);
      expect(s.selection!.extent.offset, 4);
      s.backspace();
      expect(first(s).content.text, '**bold*', reason: '物化 + 删闭定界符末字符');
      expect(first(s).content.marks, isEmpty);
      expect(s.selection!.extent.offset, 7);
      expect(s.caretOutsideMarkEnd, isFalse, reason: '物化后复位内侧');
    });

    test('内侧停位退格 = 删最后一个字符,mark 收缩不物化', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4); // updateSelection 默认内侧
      s.backspace();
      expect(first(s).content.text, 'bol');
      expect(first(s).content.marks.single.end, 3, reason: 'mark 自然收缩');
      expect(s.selection!.extent.offset, 3);
    });

    test('复合退格后继续退格 = 删字面字符', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1);
      s.backspace(); // 物化+吃字符 → '**bold*'
      s.backspace();
      expect(first(s).content.text, '**bold');
      expect(s.selection!.extent.offset, 6);
    });

    test('非闭端(mark 中部/开端)退格 = 普通删字符', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 3);
      s.backspace();
      expect(first(s).content.text, 'bod');
      expect(first(s).content.marks.single.end, 3, reason: 'mark 自然收缩');
    });

    test('非 inclusive mark(link)end 退格:无内侧停位,直接物化+吃字符', () {
      final s = makeState(EditableTextContent(
        text: 'text',
        marks: const [
          MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
        ],
      ));
      caretAt(s, 4); // link 不参与二态,视为外侧
      s.backspace();
      expect(first(s).content.text, '[text](https://x', reason: '尾 `)` 被吃');
      expect(first(s).content.marks, isEmpty);
      expect(s.selection!.extent.offset, 16);
    });

    test('undo:一次复合退格 = 一步回滚(mark 完好 + 光标在 end)', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1);
      s.backspace();
      s.undo();
      expect(first(s).content.text, 'bold');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 4);
    });

    test('多 mark 同 end:按嵌套序取最内层,一次退格拆一层', () {
      // em 在 kMarkNestingOrder 里比 strong 靠后 = 更内层
      // (序列化形态 ***abc*** 的内层是 em)
      final s = makeState(EditableTextContent(
        text: 'abc',
        marks: const [
          MarkSpan(start: 0, end: 3, kind: MarkKind.strong),
          MarkSpan(start: 0, end: 3, kind: MarkKind.em),
        ],
      ));
      caretAt(s, 3);
      s.moveCaretHorizontal(1); // 切外侧
      s.backspace();
      final c = first(s).content;
      expect(c.text, '*abc', reason: '拆内层 em 并吃掉闭 `*`');
      expect(c.marks.single.kind, MarkKind.strong, reason: '只拆内层 em');
      // 开定界符插在 strong.start 前 → strong 整体右移
      expect(c.marks.single.start, 1);
      expect(c.marks.single.end, 4);
      expect(s.selection!.extent.offset, 4);
    });

    test('start 更大者为内层(不同区间同 end)', () {
      final s = makeState(EditableTextContent(
        text: 'abc',
        marks: const [
          MarkSpan(start: 0, end: 3, kind: MarkKind.em),
          MarkSpan(start: 1, end: 3, kind: MarkKind.strong),
        ],
      ));
      caretAt(s, 3);
      s.moveCaretHorizontal(1); // 切外侧
      s.backspace();
      final c = first(s).content;
      expect(c.text, 'a**bc*', reason: '拆内层 strong 并吃掉一个闭 `*`');
      expect(c.marks.single.kind, MarkKind.em, reason: '外层 em 保持');
    });

    test('非折叠选区退格不物化(走 deleteSelection)', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      s.updateSelection(const EditorSelection(
        base: EditorPosition(blockId: 'e_0', offset: 2),
        extent: EditorPosition(blockId: 'e_0', offset: 4),
      ));
      s.backspace();
      expect(first(s).content.text, 'bo');
    });
  });

  group('物化 → 改字面 → input rules / spin 重新折叠', () {
    test('复合退格出破坏态 → 补回闭定界符(打字)→ 折叠回 strong', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1); // 边界二态:切外侧,退格才物化
      s.backspace(); // 复合物化 → '**bold*',caret 7
      s.insertText('*'); // 补回 → '**bold**'
      expect(
        tryApplyInputRules(s, 'e_0', typedChar: '*'),
        InputRuleOutcome.applied,
      );
      final c = first(s).content;
      expect(c.text, 'bold');
      expect(c.marks.single.kind, MarkKind.strong);
    });

    test('**bold** 改成 *bold* → em(现有规则)', () {
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1); // 边界二态:切外侧,退格才物化
      s.backspace(); // 复合物化 → '**bold*',caret 7
      s.backspace(); // '**bold'
      caretAt(s, 2);
      s.backspace(); // '*bold'
      caretAt(s, 5);
      s.insertText('*'); // '*bold*'
      expect(
        tryApplyInputRules(s, 'e_0', typedChar: '*'),
        InputRuleOutcome.applied,
      );
      final c = first(s).content;
      expect(c.text, 'bold');
      expect(c.marks.single.kind, MarkKind.em);
    });

    test('spec 链:复合退格 → 破坏态删成另一合法形态 → spin 折叠', () {
      // `**bold**` 复合退格 → `**bold*`;删掉开定界符一个 `*` →
      // `*bold*` 是完整 em 字面对,backspace 落地即被 spin 折叠,
      // 不存在「语法合法但不渲染」的滞留态。
      final s = makeState(EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ));
      caretAt(s, 4);
      s.moveCaretHorizontal(1);
      s.backspace(); // 复合物化 → '**bold*'
      caretAt(s, 2);
      s.backspace(); // 删一个开 `*` → '*bold*' → spin 折叠
      final c = first(s).content;
      expect(c.text, 'bold');
      expect(c.marks.single.kind, MarkKind.em);
      expect(s.selection!.extent.offset, 0,
          reason: '删除点在开定界符后,折叠后落内容前');
    });

    test('deleteForward 删出完整对同样折叠', () {
      // '**bo*ld**' 前删掉中间的 `*` → '**bold**' → spin 折叠 strong
      final s = makeState(EditableTextContent(text: '**bo*ld**'));
      caretAt(s, 4);
      s.deleteForward();
      final c = first(s).content;
      expect(c.text, 'bold');
      expect(c.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 2);
    });

    test('deleteSelection(单块)删出完整对同样折叠', () {
      // '**bo xx ld**' 选中 ' xx ' 删除 → '**bold**' → 折叠
      final s = makeState(EditableTextContent(text: '**bo xx ld**'));
      s.updateSelection(const EditorSelection(
        base: EditorPosition(blockId: 'e_0', offset: 4),
        extent: EditorPosition(blockId: 'e_0', offset: 8),
      ));
      s.deleteSelection();
      final c = first(s).content;
      expect(c.text, 'bold');
      expect(c.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 2);
    });

    test('undo 一步:spin 折叠随所在事务整体回滚', () {
      final s = makeState(EditableTextContent(text: '**bold***'));
      caretAt(s, 9);
      s.sealHistory();
      s.backspace(); // 删尾 `*` → '**bold**' → spin 折叠
      expect(first(s).content.text, 'bold');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      s.undo();
      expect(first(s).content.text, '**bold***', reason: '删字+折叠一步回滚');
      expect(first(s).content.marks, isEmpty);
    });
  });
}
