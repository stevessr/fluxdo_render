import 'dart:ui';

import '../model/editor_state.dart';

/// Distinguishes editing from reading and layout-only changes. The editor
/// combines keyboard and host overlay bounds before consulting this policy.
class EditorCaretRevealTracker {
  EditorCaretRevealKey? _key;
  Rect? _viewport;
  bool _followingLayout = false;
  EditorCaretRevealKey? _suppressedKey;

  void reset() {
    _key = null;
    _viewport = null;
    _followingLayout = false;
    _suppressedKey = null;
  }

  /// Ending a floating-caret gesture already establishes the viewport position.
  void suppressNext(EditorCaretRevealKey key) => _suppressedKey = key;

  bool shouldReveal({
    required EditorCaretRevealKey key,
    required Rect caret,
    required Rect viewport,
    bool userScrolling = false,
    bool autoScrolling = false,
  }) {
    final visible =
        caret.top >= viewport.top && caret.bottom <= viewport.bottom;
    final requested =
        key != _key || (viewport != _viewport && _followingLayout);
    final reveal = requested && !userScrolling && key != _suppressedKey;
    _key = key;
    _viewport = viewport;
    _suppressedKey = null;
    // Follow an already visible caret through a keyboard animation. An explicit
    // scroll away cancels that intent, including during an unfinished reveal.
    _followingLayout =
        visible ||
        (!userScrolling && (reveal || (autoScrolling && _followingLayout)));
    return reveal;
  }
}
