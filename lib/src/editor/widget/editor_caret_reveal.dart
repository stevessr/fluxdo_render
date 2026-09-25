import 'dart:ui';

import '../model/editor_state.dart';

/// Distinguishes editing from reading and layout-only changes. The editor
/// combines keyboard and host overlay bounds before consulting this policy.
class EditorRectRevealTracker<T> {
  T? _key;
  Rect? _viewport;
  bool _followingLayout = false;
  T? _suppressedKey;
  T? _cancelledKey;

  void reset() {
    _key = null;
    _viewport = null;
    _followingLayout = false;
    _suppressedKey = null;
    _cancelledKey = null;
  }

  /// Ending a floating-caret gesture already establishes the viewport position.
  void suppressNext(T key) => _suppressedKey = key;

  bool shouldReveal({
    required T key,
    required Rect caret,
    required Rect viewport,
    bool userScrolling = false,
    bool autoScrolling = false,
  }) {
    final visible =
        caret.top >= viewport.top && caret.bottom <= viewport.bottom;
    final keyChanged = key != _key;
    if (keyChanged) _cancelledKey = null;
    if (userScrolling) _cancelledKey = key;
    final cancelled = key == _cancelledKey;
    final requested = keyChanged || (viewport != _viewport && _followingLayout);
    final reveal =
        requested && !userScrolling && !cancelled && key != _suppressedKey;
    _key = key;
    _viewport = viewport;
    _suppressedKey = null;
    // Follow an already visible target through a keyboard animation. Once the
    // user explicitly scrolls away, the same editing key stays cancelled even
    // if a temporary viewport expansion makes it visible again. A new key
    // (typing/caret move/table cell switch) re-arms following.
    _followingLayout =
        !cancelled &&
        (visible ||
            (!userScrolling &&
                (reveal || (autoScrolling && _followingLayout))));
    return reveal;
  }
}

/// 正文光标专用别名。表格 cell 等其他编辑目标复用同一状态机时使用
/// [EditorRectRevealTracker] 并传自己的稳定 identity/revision key。
class EditorCaretRevealTracker
    extends EditorRectRevealTracker<EditorCaretRevealKey> {}
