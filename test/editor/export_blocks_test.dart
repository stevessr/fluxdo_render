import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

void main() {
  const url = 'https://github.com';
  const raw = '[$url]($url)';

  EditorState activeLink() {
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

  test('活动显式链接多轮语义导出只读，不更改任何编辑状态', () {
    final state = activeLink();
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
      final snapshot = state.exportBlocks();
      final content = (snapshot.single as TextBlock).content;
      expect(content.text, url);
      expect(content.marks, const [
        MarkSpan(
          start: 0,
          end: url.length,
          kind: MarkKind.link,
          attr: url,
          isAutoLink: false,
        ),
      ]);
      expect(() => snapshot.clear(), throwsUnsupportedError);
      expect(
        state.exportBlocks(fragment: snapshot).single is TextBlock,
        isTrue,
      );
      expect(state.exportMarkdown(), raw);
    }
    expect(identical(state.blocks, blocks), isTrue);
    expect(identical(state.selection, selection), isTrue);
    expect(state.composing, composing);
    expect(state.docRevision, revision);
    expect(state.canUndo, undo);
    expect(state.canRedo, redo);
    expect(notifications, 0);
  });

  test('片段先按展开坐标切片，局部链接不补全且空片段保持为空', () {
    final state = activeLink();
    for (final (start, end, text, linked) in [
      (0, raw.length, url, true),
      (1, 1 + url.length, url, false),
      (0, 5, '[http', false),
    ]) {
      state.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: start),
          extent: EditorPosition(blockId: 'e_0', offset: end),
        ),
      );
      final fragment = state.copySelectionAsBlocks();
      final content =
          (state.exportBlocks(fragment: fragment).single as TextBlock).content;
      expect(content.text, text);
      expect(content.marks.any((m) => m.kind == MarkKind.link), linked);
    }
    expect(state.exportBlocks(fragment: []), isEmpty);
  });

  test('跨行格式、原始属性与软换行随快照保留，超过32轮完整折叠', () {
    final repeated = List.generate(40, (i) => '**$i**').join(' ');
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'e_0',
          kind: TextBlockKind.listItem,
          ordered: true,
          depth: 2,
          listStart: 7,
          listLoose: true,
          containers: const [QuoteFrame(groupId: 'q')],
          content: EditableTextContent(
            text: '甲\n乙',
            softBreaks: {1},
            marks: const [
              MarkSpan(start: 0, end: 3, kind: MarkKind.strong, attr: '__'),
              MarkSpan(
                start: 0,
                end: 3,
                kind: MarkKind.textColor,
                attr: '#F00',
              ),
            ],
          ),
        ),
        TextBlock(
          id: 'e_1',
          content: EditableTextContent(text: repeated),
        ),
      ],
    )..mode = EditorMode.ir;
    addTearDown(state.dispose);
    final source = state.blocks.first as TextBlock;
    final snapshot = state.exportBlocks();
    final first = snapshot.first as TextBlock;
    expect(first.content, source.content);
    expect(first.content.softBreaks, {1});
    expect(first.kind, source.kind);
    expect(first.id, source.id);
    expect(first.ordered, source.ordered);
    expect(first.depth, source.depth);
    expect(first.listStart, source.listStart);
    expect(first.listLoose, source.listLoose);
    expect(first.containers, source.containers);
    final last = (snapshot.last as TextBlock).content;
    expect(last.text, List.generate(40, (i) => '$i').join(' '));
    expect(last.marks.length, 40);
    expect(
      (state.exportBlocks(fragment: snapshot).last as TextBlock).content,
      last,
    );
  });

  test('WYSIWYG 字面语法不解析，快照不随外部片段列表改变', () {
    final state = EditorState.fromTexts([raw, '**字面**']);
    addTearDown(state.dispose);
    final fragment = [...state.blocks];
    final snapshot = state.exportBlocks(fragment: fragment);
    fragment.clear();
    expect(snapshot.length, 2);
    expect(identical(snapshot.first, state.blocks.first), isTrue);
    expect((snapshot.first as TextBlock).content.text, raw);
    expect((snapshot.last as TextBlock).content.text, '**字面**');
    expect((snapshot.last as TextBlock).content.marks, isEmpty);
    expect(() => snapshot.clear(), throwsUnsupportedError);
  });

  test('导出不消费或污染实际撤销与重做快照', () {
    final state = activeLink();
    state.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: raw.length - 1),
      ),
    );
    state.insertText('/issues');
    String? target() =>
        (state.exportBlocks().single as TextBlock).content.marks.single.attr;
    expect(target(), '$url/issues');
    final snapshot = state.exportBlocks();
    state.undo();
    expect(target(), url);
    state.redo();
    expect(target(), '$url/issues');
    expect(
      (snapshot.single as TextBlock).content.marks.single.attr,
      '$url/issues',
    );
  });
}
