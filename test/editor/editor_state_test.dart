import 'dart:ui' show TextRange;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

void main() {
  EditorState makeState() => EditorState.fromTexts(const ['第一段', 'second', '三']);

  void placeCaret(EditorState s, int blockIndex, int offset) {
    s.updateSelection(EditorSelection.collapsed(
      EditorPosition(blockId: s.blocks[blockIndex].id, offset: offset),
    ));
  }

  group('基本事务', () {
    test('insertText 折叠光标处插入', () {
      final s = makeState();
      placeCaret(s, 0, 3);
      s.insertText('!');
      expect((s.blocks[0] as TextBlock).content.text, '第一段!');
      expect(s.selection!.extent.offset, 4);
    });

    test('splitParagraph 段中分段', () {
      final s = makeState();
      placeCaret(s, 1, 3);
      s.splitBlock();
      expect(s.blocks.length, 4);
      expect((s.blocks[1] as TextBlock).content.text, 'sec');
      expect((s.blocks[2] as TextBlock).content.text, 'ond');
      expect(s.selection!.extent.blockId, s.blocks[2].id);
      expect(s.selection!.extent.offset, 0);
    });

    test('mergeWithPrevious 段首合并,光标停 join 点', () {
      final s = makeState();
      s.mergeWithPrevious(s.blocks[1].id);
      expect(s.blocks.length, 2);
      expect((s.blocks[0] as TextBlock).content.text, '第一段second');
      expect(s.selection!.extent.offset, 3);
    });

    test('backspace 段首触发合并;段中删 grapheme', () {
      final s = makeState();
      placeCaret(s, 1, 0);
      s.backspace();
      expect(s.blocks.length, 2);
      expect((s.blocks[0] as TextBlock).content.text, '第一段second');

      // emoji(代理对)按 grapheme 整删
      final s2 = EditorState.fromTexts(const ['a👨‍👩‍👧‍👦b']);
      placeCaret(s2, 0, 'a👨‍👩‍👧‍👦'.length);
      s2.backspace();
      expect((s2.blocks[0] as TextBlock).content.text, 'ab');
    });

    test('deleteForward 段尾并下一段', () {
      final s = makeState();
      placeCaret(s, 0, 3);
      s.deleteForward();
      expect(s.blocks.length, 2);
      expect((s.blocks[0] as TextBlock).content.text, '第一段second');
      expect(s.selection!.extent.offset, 3);
    });

    test('deleteSelection 跨段:首尾残余合并、中段整删', () {
      final s = makeState();
      s.updateSelection(EditorSelection(
        base: EditorPosition(blockId: s.blocks[0].id, offset: 1),
        extent: EditorPosition(blockId: s.blocks[2].id, offset: 1),
      ));
      s.deleteSelection();
      expect(s.blocks.length, 1);
      expect((s.blocks[0] as TextBlock).content.text, '第');
      expect(s.selection!.isCollapsed, true);
      expect(s.selection!.extent.offset, 1);
    });

    test('deleteSelection 反向选区(extent 在前)同样生效', () {
      final s = makeState();
      s.updateSelection(EditorSelection(
        base: EditorPosition(blockId: s.blocks[2].id, offset: 1),
        extent: EditorPosition(blockId: s.blocks[0].id, offset: 1),
      ));
      s.deleteSelection();
      expect(s.blocks.length, 1);
      expect((s.blocks[0] as TextBlock).content.text, '第');
    });
  });

  group('光标移动', () {
    test('跨段衔接:段尾右移到下段首', () {
      final s = makeState();
      placeCaret(s, 0, 3);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.blockId, s.blocks[1].id);
      expect(s.selection!.extent.offset, 0);
      s.moveCaretHorizontal(-1);
      expect(s.selection!.extent.blockId, s.blocks[0].id);
      expect(s.selection!.extent.offset, 3);
    });

    test('非扩选时选区折叠到方向端点', () {
      final s = makeState();
      s.updateSelection(EditorSelection(
        base: EditorPosition(blockId: s.blocks[0].id, offset: 0),
        extent: EditorPosition(blockId: s.blocks[0].id, offset: 2),
      ));
      s.moveCaretHorizontal(-1);
      expect(s.selection!.isCollapsed, true);
      expect(s.selection!.extent.offset, 0);
    });

    test('shift 扩选', () {
      final s = makeState();
      placeCaret(s, 0, 0);
      s.moveCaretHorizontal(1, extend: true);
      expect(s.selection!.isCollapsed, false);
      expect(s.selection!.extent.offset, 1);
    });
  });

  group('undo/redo 与 seal', () {
    test('连续 insertText 合并为一个 undo 步', () {
      final s = makeState();
      placeCaret(s, 0, 3);
      s.insertText('a');
      s.insertText('b');
      s.insertText('c');
      expect((s.blocks[0] as TextBlock).content.text, '第一段abc');
      s.undo();
      expect((s.blocks[0] as TextBlock).content.text, '第一段');
      expect(s.canUndo, false);
    });

    test('seal 后的输入是新 undo 步', () {
      final s = makeState();
      placeCaret(s, 0, 3);
      s.insertText('a');
      s.sealHistory();
      s.insertText('b');
      s.undo();
      expect((s.blocks[0] as TextBlock).content.text, '第一段a');
      s.undo();
      expect((s.blocks[0] as TextBlock).content.text, '第一段');
    });

    test('结构操作(split)独立成步且可 redo', () {
      final s = makeState();
      placeCaret(s, 0, 1);
      s.insertText('x');
      s.splitBlock();
      expect(s.blocks.length, 4);
      s.undo(); // 撤 split
      expect(s.blocks.length, 3);
      expect((s.blocks[0] as TextBlock).content.text, '第x一段');
      s.undo(); // 撤 insert
      expect((s.blocks[0] as TextBlock).content.text, '第一段');
      s.redo();
      expect((s.blocks[0] as TextBlock).content.text, '第x一段');
      s.redo();
      expect(s.blocks.length, 4);
    });

    test('undo 后新编辑清空 redo 栈', () {
      final s = makeState();
      placeCaret(s, 0, 0);
      s.insertText('a');
      s.undo();
      expect(s.canRedo, true);
      s.insertText('b');
      expect(s.canRedo, false);
    });

    // 工具栏撤销/恢复按钮的置灰态由 canUndo/canRedo 驱动,且只在
    // notifyListeners 时重算 —— 三个跃迁点必须都发通知,否则移动端
    // (无快捷键,按钮是唯一入口)会出现「能撤销但按钮灰着」的死锁。
    test('canUndo/canRedo 跃迁均发出通知(驱动工具栏按钮置灰)', () {
      final s = makeState();
      var notifications = 0;
      s.addListener(() => notifications++);
      placeCaret(s, 0, 0);

      expect(s.canUndo, false);
      expect(s.canRedo, false);

      // false → true(首次编辑)
      notifications = 0;
      s.insertText('a');
      expect(s.canUndo, true);
      expect(notifications, greaterThan(0), reason: '首次编辑后要通知');

      // canRedo false → true(撤销)
      notifications = 0;
      s.undo();
      expect(s.canUndo, false);
      expect(s.canRedo, true);
      expect(notifications, greaterThan(0), reason: 'undo 后要通知');

      // canRedo true → false(恢复到栈顶)
      notifications = 0;
      s.redo();
      expect(s.canUndo, true);
      expect(s.canRedo, false);
      expect(notifications, greaterThan(0), reason: 'redo 后要通知');
    });
  });

  group('imeReplace', () {
    test('文本变更 + composing 透传', () {
      final s = makeState();
      final id = s.blocks[0].id;
      placeCaret(s, 0, 3);
      s.imeReplace(id, 3, 3, 'ni', caretOffset: 5,
          composing: const TextRange(start: 3, end: 5));
      expect((s.blocks[0] as TextBlock).content.text, '第一段ni');
      expect(s.composing, const TextRange(start: 3, end: 5));
      expect(s.selection!.extent.offset, 5);
    });

    test('纯光标更新(无文本变化)不记历史', () {
      final s = makeState();
      final id = s.blocks[0].id;
      placeCaret(s, 0, 3);
      s.sealHistory();
      final undoBefore = s.canUndo;
      s.imeReplace(id, 0, 0, '', caretOffset: 1);
      expect(s.canUndo, undoBefore);
      expect(s.selection!.extent.offset, 1);
    });
  });
}
