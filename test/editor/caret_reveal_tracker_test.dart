import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

void main() {
  const key = (
    EditorSelection.collapsed(EditorPosition(blockId: 'text', offset: 1)),
    null,
  );
  const screen = Rect.fromLTWH(0, 0, 400, 600);
  const keyboard = Rect.fromLTWH(0, 0, 400, 300);
  const visibleCaret = Rect.fromLTWH(20, 550, 2, 24);
  const distantCaret = Rect.fromLTWH(20, 2000, 2, 24);

  test('阅读滚离后，键盘开合和视口变化不重新追光标', () {
    final tracker = EditorCaretRevealTracker();
    expect(
      tracker.shouldReveal(key: key, caret: visibleCaret, viewport: screen),
      isTrue,
    );
    expect(
      tracker.shouldReveal(key: key, caret: distantCaret, viewport: screen),
      isFalse,
    );
    expect(
      tracker.shouldReveal(key: key, caret: distantCaret, viewport: keyboard),
      isFalse,
    );
    expect(
      tracker.shouldReveal(key: key, caret: distantCaret, viewport: screen),
      isFalse,
    );
  });

  test('已在编辑的光标跟随键盘连续收缩，动画中不会丢失跟随意图', () {
    final tracker = EditorCaretRevealTracker();
    tracker.shouldReveal(key: key, caret: visibleCaret, viewport: screen);
    expect(
      tracker.shouldReveal(key: key, caret: visibleCaret, viewport: keyboard),
      isTrue,
    );
    expect(
      tracker.shouldReveal(
        key: key,
        caret: visibleCaret,
        viewport: keyboard,
        autoScrolling: true,
      ),
      isFalse,
    );
    expect(
      tracker.shouldReveal(
        key: key,
        caret: visibleCaret,
        viewport: const Rect.fromLTWH(0, 0, 400, 250),
        autoScrolling: true,
      ),
      isTrue,
    );
  });

  test('用户中断尚未完成的跟随，后续布局变化不能继续拉回', () {
    final tracker = EditorCaretRevealTracker();
    tracker.shouldReveal(key: key, caret: distantCaret, viewport: screen);
    tracker.shouldReveal(
      key: key,
      caret: distantCaret,
      viewport: screen,
      userScrolling: true,
    );
    expect(
      tracker.shouldReveal(key: key, caret: distantCaret, viewport: keyboard),
      isFalse,
    );
  });

  test('虚拟光标结束吸收一次布局变化，新输入仍可触发跟随', () {
    final tracker = EditorCaretRevealTracker();
    tracker.suppressNext(key);
    expect(
      tracker.shouldReveal(key: key, caret: distantCaret, viewport: screen),
      isFalse,
    );
    const next = (
      EditorSelection.collapsed(EditorPosition(blockId: 'text', offset: 2)),
      null,
    );
    expect(
      tracker.shouldReveal(key: next, caret: distantCaret, viewport: screen),
      isTrue,
    );
  });
}
