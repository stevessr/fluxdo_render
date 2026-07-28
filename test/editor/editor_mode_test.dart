/// EditorMode(wysiwyg/ir 双模)门控测试。
///
/// 契约:两模式共享文档模型/序列化/输入规则,只在格式边界交互分叉 ——
/// - wysiwyg(默认):无显形、无 mark 末端二态停位、退格恒删字符
///   (任何 mark,含非 inclusive 的 link/inlineCode/带 attr,均不物化);
/// - ir:显形 + 二态 + 退格物化(细粒度语义见 materialize_mark_test /
///   live_markdown_preview_test,本文件只钉门控差异与两模式一致项)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

EditorState makeState(
  EditableTextContent content, {
  required EditorMode mode,
}) {
  final s = EditorState(blocks: [TextBlock(id: 'e_0', content: content)])
    ..mode = mode;
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
  test('mode 默认 wysiwyg;setter 同值早退、切换清外侧停位并通知', () {
    final s = EditorState.fromTexts(['bold']);
    addTearDown(s.dispose);
    expect(s.mode, EditorMode.wysiwyg);

    var notified = 0;
    s.addListener(() => notified++);
    s.mode = EditorMode.wysiwyg; // 同值早退,不通知
    expect(notified, 0);
    s.mode = EditorMode.ir;
    expect(notified, 1);

    // ir 下切到外侧停位,再切回 wysiwyg:残留必须清掉
    final s2 = makeState(
      EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ),
      mode: EditorMode.ir,
    );
    caretAt(s2, 4);
    s2.moveCaretHorizontal(1);
    expect(s2.caretOutsideMarkEnd, isTrue);
    s2.mode = EditorMode.wysiwyg;
    expect(s2.caretOutsideMarkEnd, isFalse);
  });

  for (final mode in EditorMode.values) {
    group('两模式一致($mode)', () {
      test('inclusive mark 末端打字延伸格式', () {
        final s = makeState(
          EditableTextContent(
            text: 'bold tail',
            marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
          ),
          mode: mode,
        );
        caretAt(s, 4);
        s.insertText('X');
        final c = first(s).content;
        expect(c.text, 'boldX tail');
        expect(c.marks.single.end, 5, reason: '末端打字延伸,两模式一致');
      });

      test('非 inclusive mark(link)末端打字不延伸', () {
        final s = makeState(
          EditableTextContent(
            text: 'link',
            marks: const [
              MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
            ],
          ),
          mode: mode,
        );
        caretAt(s, 4);
        s.insertText('Y');
        final c = first(s).content;
        expect(c.text, 'linkY');
        expect(c.marks.single.end, 4, reason: '链接尾打字不长出链接');
      });

      test('mark 中部退格 = 删字符、mark 收缩', () {
        final s = makeState(
          EditableTextContent(
            text: 'bold',
            marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
          ),
          mode: mode,
        );
        caretAt(s, 3);
        s.backspace();
        expect(first(s).content.text, 'bod');
        expect(first(s).content.marks.single.end, 3);
      });
    });
  }

  group('wysiwyg 门控:二态停位关闭', () {
    test('右移直接过 mark.end,caretOutsideMarkEnd 恒 false', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 3);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 4);
      expect(s.caretOutsideMarkEnd, isFalse);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 5, reason: '无外侧停位,直接过界');
      expect(s.caretOutsideMarkEnd, isFalse);
    });

    test('左移落 mark.end 不补置外侧', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 5);
      s.moveCaretHorizontal(-1);
      expect(s.selection!.extent.offset, 4);
      expect(s.caretOutsideMarkEnd, isFalse, reason: 'wysiwyg 落点恒内侧');
      s.moveCaretHorizontal(-1);
      expect(s.selection!.extent.offset, 3, reason: '再左移直接进 mark');
    });
  });

  group('wysiwyg 门控:退格不物化', () {
    test('inclusive mark(strong)end 退格 = 删字、mark 收缩', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.backspace();
      expect(first(s).content.text, 'bol');
      expect(first(s).content.marks.single.end, 3);
      expect(first(s).content.text.contains('*'), isFalse,
          reason: '不出现字面定界符');
    });

    test('回归:link end 退格不物化(ir 下会物化的缺口在 wysiwyg 必须关死)',
        () {
      final s = makeState(
        EditableTextContent(
          text: 'text',
          marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
          ],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.backspace();
      final c = first(s).content;
      expect(c.text, 'tex', reason: '恒删字,不还原 [text](href) 字面');
      expect(c.marks.single.kind, MarkKind.link);
      expect(c.marks.single.end, 3);
    });

    test('回归:inlineCode end 退格不物化', () {
      final s = makeState(
        EditableTextContent(
          text: 'code',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.inlineCode)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.backspace();
      final c = first(s).content;
      expect(c.text, 'cod');
      expect(c.marks.single.end, 3);
      expect(c.text.contains('`'), isFalse);
    });

    test('回归:带 attr(size)end 退格不物化', () {
      final s = makeState(
        EditableTextContent(
          text: 'big',
          marks: const [
            MarkSpan(start: 0, end: 3, kind: MarkKind.size, attr: '150'),
          ],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 3);
      s.backspace();
      final c = first(s).content;
      expect(c.text, 'bi');
      expect(c.marks.single.end, 2);
      expect(c.text.contains('['), isFalse);
    });
  });

  group('wysiwyg 门控:spin 不触发', () {
    test('退格删出完整字面对不折叠(ir 才折)', () {
      // '**bold***' 删尾 `*` → '**bold**'
      final s = makeState(
        EditableTextContent(text: '**bold***'),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 9);
      s.backspace();
      expect(first(s).content.text, '**bold**', reason: 'wysiwyg 无 spin');
      expect(first(s).content.marks, isEmpty);

      final ir = makeState(
        EditableTextContent(text: '**bold***'),
        mode: EditorMode.ir,
      );
      caretAt(ir, 9);
      ir.backspace();
      expect(first(ir).content.text, 'bold', reason: 'ir 下同操作折叠');
      expect(first(ir).content.marks.single.kind, MarkKind.strong);
    });

    test('deleteForward / deleteSelection 删出完整对同样不折叠', () {
      final s = makeState(
        EditableTextContent(text: '**bo*ld**'),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.deleteForward();
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);

      final s2 = makeState(
        EditableTextContent(text: '**bo xx ld**'),
        mode: EditorMode.wysiwyg,
      );
      s2.updateSelection(const EditorSelection(
        base: EditorPosition(blockId: 'e_0', offset: 4),
        extent: EditorPosition(blockId: 'e_0', offset: 8),
      ));
      s2.deleteSelection();
      expect(first(s2).content.text, '**bold**');
      expect(first(s2).content.marks, isEmpty);
    });

    test('imeReplace 删出完整对不折叠', () {
      final s = makeState(
        EditableTextContent(text: '**bold**x'),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 9);
      s.imeReplace('e_0', 8, 9, '', caretOffset: 8);
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);
    });
  });

  group('ir 门控:既有语义保持(抽查,细粒度见 materialize_mark_test)', () {
    test('四步序列:内 → end内 → end外 → 下一字符;外侧退格物化', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 3);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 4);
      expect(s.caretOutsideMarkEnd, isFalse);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 4);
      expect(s.caretOutsideMarkEnd, isTrue);
      s.backspace();
      expect(first(s).content.text, '**bold* tail',
          reason: '外侧退格复合物化:字面化 + 吃掉闭定界符末字符');
      expect(first(s).content.marks, isEmpty);
    });

    test('link end 退格直接物化+吃字符(无内侧停位)', () {
      final s = makeState(
        EditableTextContent(
          text: 'text',
          marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
          ],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 4);
      s.backspace();
      expect(first(s).content.text, '[text](https://x');
      expect(first(s).content.marks, isEmpty);
    });
  });
}
