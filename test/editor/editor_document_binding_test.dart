import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/document.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';

class _Binding implements EditorDocumentBinding {
  int calls = 0;
  bool reject = false;

  @override
  Object prepare(Object? previousState, List<EditorBlock> normalizedBlocks) {
    calls++;
    if (reject) throw const EditorDocumentRejection('测试拒绝');
    return List<EditorBlock>.unmodifiable(normalizedBlocks);
  }
}

void main() {
  late _Binding binding;
  late EditorState state;
  setUp(() {
    binding = _Binding();
    state = EditorState(
      blocks: [
        TextBlock(
          id: 'a',
          content: EditableTextContent(text: 'abc'),
        ),
      ],
      documentBinding: binding,
    );
    state.updateSelection(
      const EditorSelection.collapsed(EditorPosition(blockId: 'a', offset: 1)),
    );
  });
  tearDown(() => state.dispose());

  test('显式合并保留左块属性且与连续输入分别撤销', () {
    final session = SemanticEditorSession(
      SemanticNode(
        'doc',
        content: [
          SemanticNode(
            'paragraph',
            attrs: {'x': 1},
            content: [SemanticNode('text', text: 'a')],
          ),
          SemanticNode(
            'paragraph',
            attrs: {'x': 2},
            content: [SemanticNode('text', text: 'b')],
          ),
        ],
      ),
    );
    addTearDown(session.dispose);
    final editor = session.editor;
    editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: editor.blocks.first.id, offset: 1),
      ),
    );
    editor.insertText('1');
    final beforeMerge = editor.documentBindingState;
    editor.mergeWithPrevious(editor.blocks.last.id);
    expect(session.tree.content.single.attrs, {'x': 1});
    editor.undo();
    expect(editor.documentBindingState, same(beforeMerge));
    expect(editor.blocks.length, 2);
    editor.undo();
    expect(editor.textBlockById(editor.blocks.first.id)!.content.text, 'a');
  });

  for (final command in <String, void Function(EditorState)>{
    '分块': (s) => s.splitBlock(),
    '修改块属性': (s) => s.setHeading(2),
    '插入段落': (s) => s.continueAfterDocument(),
    '替换块范围': (s) => s.replaceBlockRange(0, 0, [
      s.textBlockById('a')!.copyWith(content: EditableTextContent(text: '替换')),
    ]),
    '粘贴': (s) => s.pasteBlocks([
      TextBlock(
        id: 'p',
        content: EditableTextContent(text: '粘贴'),
      ),
    ]),
  }.entries) {
    test('${command.key}拒绝保留连续输入和pending锚点', () {
      state.insertText('1');
      state.toggleMark(MarkKind.strong);
      final pending = state.pendingMarks;
      binding.reject = true;
      expect(
        () => command.value(state),
        throwsA(isA<EditorDocumentRejection>()),
      );
      expect(state.pendingMarks, same(pending));
      binding.reject = false;
      state.insertText('2');
      expect(
        state.textBlockById('a')!.content.marks.single.kind,
        MarkKind.strong,
      );
      state.undo();
      expect(state.textBlockById('a')!.content.text, 'abc');
      expect(state.canUndo, isFalse);
    });
  }

  testWidgets('拒绝分块不取消原有800ms空闲封组计时', (tester) async {
    state.insertText('1');
    await tester.pump(const Duration(milliseconds: 500));
    binding.reject = true;
    expect(() => state.splitBlock(), throwsA(isA<EditorDocumentRejection>()));
    await tester.pump(const Duration(milliseconds: 301));
    binding.reject = false;
    state.insertText('2');
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'a1bc');
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'abc');
  });

  test('跨块替换拒绝保留选区且不封组', () {
    state.dispose();
    state = EditorState(
      blocks: [
        TextBlock(
          id: 'a',
          content: EditableTextContent(text: 'a'),
        ),
        TextBlock(
          id: 'b',
          content: EditableTextContent(text: 'b'),
        ),
      ],
      documentBinding: binding,
    );
    state.updateSelection(
      const EditorSelection.collapsed(EditorPosition(blockId: 'a', offset: 1)),
    );
    state.insertText('1');
    state.updateSelection(
      const EditorSelection(
        base: EditorPosition(blockId: 'a', offset: 1),
        extent: EditorPosition(blockId: 'b', offset: 1),
      ),
    );
    final selection = state.selection;
    binding.reject = true;
    expect(
      () => state.replaceCrossBlockSelection('替换', caretOffset: 2),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(state.selection, selection);
    binding.reject = false;
    state.updateSelection(
      const EditorSelection.collapsed(EditorPosition(blockId: 'a', offset: 2)),
    );
    state.insertText('2');
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'a');
    expect(state.textBlockById('b')!.content.text, 'b');
  });

  test('拒绝IME事务不改变正文、选区、预编辑、历史或通知', () {
    state.updateComposing(const TextRange(start: 0, end: 1));
    final blocks = state.blocks;
    final selection = state.selection;
    final snapshot = state.documentBindingState;
    var notifications = 0;
    state.addListener(() => notifications++);
    binding.reject = true;
    expect(
      () => state.imeReplace('a', 0, 1, '拒绝', caretOffset: 2),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(state.blocks, same(blocks));
    expect(state.selection, selection);
    expect(state.composing, const TextRange(start: 0, end: 1));
    expect(state.documentBindingState, same(snapshot));
    expect(state.docRevision, 0);
    expect(state.canUndo, isFalse);
    expect(notifications, 0);
  });

  test('撤销重做恢复已批准语义快照，不重新投影', () {
    final before = state.documentBindingState;
    state.insertText('x');
    final after = state.documentBindingState;
    final calls = binding.calls;
    binding.reject = true;
    state.undo();
    expect(state.documentBindingState, same(before));
    state.redo();
    expect(state.documentBindingState, same(after));
    expect(binding.calls, calls);
  });

  test('隔离粘贴最终提交仍经过门禁且保留redo', () {
    state.insertText('x');
    state.undo();
    final blocks = state.blocks;
    final selection = state.selection;
    binding.reject = true;
    expect(
      () => state.pasteBlocks([
        TextBlock(
          id: 'fragment',
          content: EditableTextContent(text: '粘贴'),
        ),
      ]),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(state.blocks, same(blocks));
    expect(state.selection, selection);
    expect(state.canRedo, isTrue);
    expect(state.canUndo, isFalse);
  });

  test('IR无历史物化只向绑定提供折叠后的语义副本', () {
    state.dispose();
    state = EditorState(
      blocks: [
        TextBlock(
          id: 'a',
          content: EditableTextContent(
            text: 'bold',
            marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
          ),
        ),
      ],
      documentBinding: binding,
    );
    state.mode = EditorMode.ir;
    state.updateSelection(
      const EditorSelection.collapsed(EditorPosition(blockId: 'a', offset: 2)),
    );
    expect(state.textBlockById('a')!.content.text, '**bold**');
    final normalized = state.documentBindingState! as List<EditorBlock>;
    expect((normalized.single as TextBlock).content.text, 'bold');
    expect(
      (normalized.single as TextBlock).content.marks.single.kind,
      MarkKind.strong,
    );
    expect(state.canUndo, isFalse);
  });

  test('绑定历史不允许只清理块而留下失配语义快照', () {
    state.insertText('x');
    expect(
      () => state.forgetTransientBlockInHistory('a'),
      throwsA(isA<EditorDocumentRejection>()),
    );
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'abc');
  });
}
