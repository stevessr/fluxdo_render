import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/model/inline_spin.dart';

void main() {
  test('跨软换行强调显式物化后导出仍保持语义与偏移', () {
    final original = EditableTextContent(
      text: '甲\n乙',
      softBreaks: {1},
    ).applyMark(0, 3, MarkKind.strong);
    final state = EditorState(
      blocks: [TextBlock(id: 'p', content: original)],
    );
    addTearDown(state.dispose);
    state.mode = EditorMode.ir;
    state.materializeMarkAt('p', original.marks.single, caretOffset: 4);
    expect(state.textBlockById('p')!.content.softBreaks, {3});
    expect(state.exportMarkdown(), '**甲\n乙**');
    state.mode = EditorMode.wysiwyg;
    expect(state.textBlockById('p')!.content, original);
  });

  test('跨行强调扫描、守卫及回收一致，软硬换行来源不变', () {
    for (final delimiter in ['**', '__', '*', '_', '~~']) {
      final source = EditableTextContent(
        text: '$delimiter甲\n乙\n丙$delimiter',
        softBreaks: {delimiter.length + 1},
      );
      expect(scanInlineSyntax(source).single.contentLen, 5);
      expect(
        spinInlineMarks(source, caret: delimiter.length + 2).content,
        same(source),
      );
      final folded = spinInlineMarks(
        source,
        caret: source.length,
        guardAtCaret: false,
      );
      expect(folded.content.text, '甲\n乙\n丙');
      expect(folded.content.softBreaks, {1});
      expect(folded.caret, 5);
      expect(
        isRefoldableMark(folded.content, folded.content.marks.single),
        isTrue,
      );
    }
  });

  test('空行隔离段落且不吞掉后段合法标记，未闭合不匹配', () {
    for (final separator in ['\n\n', '\n \t\n', '\r\n\r\n']) {
      final source = EditableTextContent(text: '**甲$separator乙** 后 **好**');
      final hits = scanInlineSyntax(source);
      expect(hits.length, 1);
      expect(hits.single.contentLen, 1);
    }
    for (final text in ['**甲\n乙', '*甲\n乙', '**甲\n乙*', '**甲\n乙\n']) {
      final source = EditableTextContent(text: text);
      expect(scanInlineSyntax(source), isEmpty);
      expect(spinInlineMarks(source, caret: 0).content, same(source));
    }
  });

  test('链接与代码不扩展跨行语法，强调可完整包住既有链接', () {
    for (final text in ['[甲\n乙](https://example.com)', '`甲\n乙`']) {
      expect(scanInlineSyntax(EditableTextContent(text: text)), isEmpty);
    }
    final source = EditableTextContent(text: '**甲\n乙**', softBreaks: {3})
        .applyMark(
          4,
          5,
          MarkKind.link,
          attr: 'https://example.com',
          isAutoLink: false,
        );
    final folded = spinInlineMarks(source, caret: 0).content;
    expect(folded.text, '甲\n乙');
    expect(folded.softBreaks, {1});
    expect(
      folded.marks.where((m) => m.kind == MarkKind.link).single,
      const MarkSpan(
        start: 2,
        end: 3,
        kind: MarkKind.link,
        attr: 'https://example.com',
        isAutoLink: false,
      ),
    );
  });
}
