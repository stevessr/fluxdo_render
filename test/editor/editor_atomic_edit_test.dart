import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/node/node.dart';

class _Binding implements EditorDocumentBinding {
  int calls = 0;
  int? rejectAt;
  @override
  Object prepare(Object? previousState, List<EditorBlock> blocks) {
    calls++;
    if (calls == rejectAt) throw const EditorDocumentRejection('拒绝后半提交');
    return List<EditorBlock>.unmodifiable(blocks);
  }
}

void main() {
  late EditorState state;
  late _Binding binding;
  const caret = EditorSelection.collapsed(
    EditorPosition(blockId: 'a', offset: 1),
  );
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
    state.updateSelection(caret);
  });
  tearDown(() => state.dispose());

  test('选区删除成功但原子拒绝时全部恢复且无中间通知', () {
    state.insertText('x');
    state.undo();
    state.updateSelection(
      const EditorSelection(
        base: EditorPosition(blockId: 'a', offset: 0),
        extent: EditorPosition(blockId: 'a', offset: 2),
      ),
    );
    state.updateComposing(const TextRange(start: 0, end: 2));
    final blocks = state.blocks;
    final snapshot = state.documentBindingState;
    final selection = state.selection;
    final revision = state.docRevision;
    final calls = binding.calls;
    var notifications = 0;
    state.addListener(() => notifications++);
    binding.rejectAt = calls + 2;
    expect(
      () => state.insertAtom(const EmojiRun(name: 'x', url: 'x')),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(binding.calls, calls + 2);
    expect(state.blocks, same(blocks));
    expect(state.documentBindingState, same(snapshot));
    expect(state.selection, selection);
    expect(state.docRevision, revision);
    expect(state.composing, const TextRange(start: 0, end: 2));
    expect(state.canUndo, isFalse);
    expect(state.canRedo, isTrue);
    expect(notifications, 0);
    state.redo();
    expect(state.textBlockById('a')!.content.text, 'axbc');
  });

  test('成功复合提交只通知一次且单次撤销重做', () {
    var notifications = 0;
    state.addListener(() => notifications++);
    final before = state.documentBindingState;
    final result = state.runAtomicEdit(() {
      state.insertText('1');
      state.sealHistory();
      state.insertText('2');
      expect(notifications, 0);
      return 42;
    });
    expect(result, 42);
    expect(notifications, 1);
    expect(state.docRevision, 2);
    final after = state.documentBindingState;
    state.undo();
    expect(state.documentBindingState, same(before));
    expect(state.canUndo, isFalse);
    state.redo();
    expect(state.textBlockById('a')!.content.text, 'a12bc');
    expect(state.documentBindingState, same(after));
  });

  test('绑定选区原子替换成功只产生一个独立undo', () {
    state.updateSelection(
      const EditorSelection(
        base: EditorPosition(blockId: 'a', offset: 0),
        extent: EditorPosition(blockId: 'a', offset: 2),
      ),
    );
    var notifications = 0;
    state.addListener(() => notifications++);
    state.insertAtom(const EmojiRun(name: 'x', url: 'x'));
    expect(notifications, 1);
    expect(state.textBlockById('a')!.content.isAtomAt(0), isTrue);
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'abc');
    expect(state.canUndo, isFalse);
  });

  test('嵌套加入外层且失败恢复先前undo redo栈', () {
    state.insertText('1');
    state.sealHistory();
    state.insertText('2');
    state.undo();
    final before = state.blocks;
    var notifications = 0;
    state.addListener(() => notifications++);
    expect(
      () => state.runAtomicEdit(() {
        state.redo();
        state.runAtomicEdit(() => state.insertText('3'));
        state.undo();
        throw StateError('失败');
      }),
      throwsStateError,
    );
    expect(notifications, 0);
    expect(state.blocks, same(before));
    expect(state.canUndo, isTrue);
    expect(state.canRedo, isTrue);
    state.redo();
    expect(state.textBlockById('a')!.content.text, 'a12bc');
    state.undo();
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'abc');
  });

  test('显式无绑定事务恢复pending请求、IME、发号、模式及历史', () {
    state.dispose();
    state = EditorState.fromTexts(['abc']);
    state.updateSelection(
      const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: 1),
      ),
    );
    state.toggleMark(MarkKind.strong);
    state.updateComposing(const TextRange(start: 0, end: 1));
    state.pendingCalloutType = 'note';
    state.requestIslandEdit('old');
    final pending = state.pendingMarks;
    final failure = StateError('回滚');
    expect(
      () => state.runAtomicEdit(() {
        state.insertText('x');
        state.nextBlockId();
        state.pendingCalloutType = 'warning';
        state.consumeIslandEditRequest('old');
        state.requestIslandEdit('new');
        state.mode = EditorMode.ir;
        throw failure;
      }),
      throwsA(same(failure)),
    );
    expect(state.pendingMarks, same(pending));
    expect(state.composing, const TextRange(start: 0, end: 1));
    expect(state.pendingCalloutType, 'note');
    expect(state.consumeIslandEditRequest('old'), isTrue);
    expect(state.consumeIslandEditRequest('new'), isFalse);
    expect(state.mode, EditorMode.wysiwyg);
    expect(state.nextBlockId(), 'e_1');
    expect(state.canUndo, isFalse);
    state.runAtomicEdit(() {
      state.insertText('1');
      state.insertText('2');
    });
    state.undo();
    expect(state.textBlockById('e_0')!.content.text, 'abc');
    expect(state.canUndo, isFalse);
  });

  testWidgets('回滚保留原计时截止点与连续输入位置', (tester) async {
    state.insertText('1');
    final last = state.lastEditPos;
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      () => state.runAtomicEdit(() {
        state.sealHistory();
        state.insertText('丢弃');
        throw StateError('失败');
      }),
      throwsStateError,
    );
    expect(state.lastEditPos, last);
    await tester.pump(const Duration(milliseconds: 301));
    state.insertText('2');
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'a1bc');
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'abc');
  });

  testWidgets('失败不会遗留新计时器，成功续期最后一次计时意图', (tester) async {
    expect(
      () => state.runAtomicEdit(() {
        state.insertText('丢弃');
        throw StateError('失败');
      }),
      throwsStateError,
    );
    await tester.pump(const Duration(milliseconds: 500));
    state.runAtomicEdit(() {
      state.insertText('1');
      state.insertText('2');
    });
    await tester.pump(const Duration(milliseconds: 400));
    state.insertText('3');
    state.undo();
    expect(state.textBlockById('a')!.content.text, 'abc');
    expect(state.canUndo, isFalse);
  });
}
