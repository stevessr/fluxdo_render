import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

void main() {
  const url = 'https://github.com';
  const raw = '[$url]($url)';

  EditorState expandedLink() {
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(
            text: url,
            marks: const [
              MarkSpan(
                start: 0,
                end: url.length,
                kind: MarkKind.link,
                attr: url,
                isAutoLink: false,
              ),
            ],
          ),
        ),
      ],
    )..mode = EditorMode.ir;
    addTearDown(state.dispose);
    state.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: 4),
      ),
    );
    expect((state.blocks.single as TextBlock).content.text, raw);
    return state;
  }

  test('展开态重复导出不改变正文、选区、IME、修订及撤销栈', () {
    final state = expandedLink();
    state.updateComposing(const TextRange(start: 4, end: 6));
    final blocks = state.blocks;
    final selection = state.selection;
    final composing = state.composing;
    final revision = state.docRevision;
    final undo = state.canUndo;
    final redo = state.canRedo;
    var notifications = 0;
    state.addListener(() => notifications++);
    for (var i = 0; i < 4; i++) {
      expect(state.exportMarkdown(), raw);
    }
    expect(identical(state.blocks, blocks), isTrue);
    expect(state.selection, selection);
    expect(state.composing, composing);
    expect(state.docRevision, revision);
    expect(state.canUndo, undo);
    expect(state.canRedo, redo);
    expect(notifications, 0);
  });

  test('选区先按展开态坐标切片，整链复制保留语法、局部不补网址', () {
    final state = expandedLink();
    void select(int start, int end) => state.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: 'e_0', offset: start),
        extent: EditorPosition(blockId: 'e_0', offset: end),
      ),
    );
    select(0, raw.length);
    expect(state.copySelectionAsMarkdown(), raw);
    select(1, 1 + url.length);
    expect(state.copySelectionAsMarkdown(), url);
    select(0, 5);
    expect(state.copySelectionAsMarkdown(), r'\[http');
  });

  test('修改展开态目标后导出保留新值，导出不消费撤销', () {
    final state = expandedLink();
    state.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: raw.length - 1),
      ),
    );
    state.insertText('/issues');
    expect(state.exportMarkdown(), '[$url]($url/issues)');
    state.undo();
    expect(state.exportMarkdown(), raw);
    state.redo();
    expect(state.exportMarkdown(), '[$url]($url/issues)');
  });

  test('WYSIWYG 字面 Markdown 不得在导出时重新解析', () {
    final state = EditorState.fromTexts([raw, '**字面**']);
    addTearDown(state.dispose);
    expect(
      state.exportMarkdown(),
      r'\[https://github.com\](https://github.com)'
      '\n\n'
      r'\*\*字面\*\*',
    );
  });

  test('未闭合语法不补全，不改变正在输入的文本', () {
    final state = EditorState.fromTexts(['[label](https://github.com', '**abc'])
      ..mode = EditorMode.ir;
    addTearDown(state.dispose);
    final blocks = state.blocks;
    expect(
      state.exportMarkdown(),
      r'\[label\](https://github.com'
      '\n\n'
      r'\*\*abc',
    );
    expect(identical(blocks, state.blocks), isTrue);
  });

  test('长段落超过32对完整语法也全部导出，容器属性保留', () {
    final text = List.generate(
      40,
      (i) => '[L$i](https://example.com/$i)',
    ).join(' ');
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: text),
          containers: const [QuoteFrame(groupId: 'q')],
        ),
      ],
    )..mode = EditorMode.ir;
    addTearDown(state.dispose);
    expect(state.exportMarkdown(), '> $text');
  });
}
