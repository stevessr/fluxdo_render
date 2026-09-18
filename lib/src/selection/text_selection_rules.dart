import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'block_text_geometry.dart';

enum TextSelectionSurface { editable, readOnly }

/// Common policy used by both adapters. Source: Flutter's
/// TextSelectionGestureDetector and SelectableRegion. Their platform rules
/// intentionally differ; document coordinates and UI remain adapter-owned.
class TextSelectionRules {
  const TextSelectionRules(this.platform, this.surface);
  final TargetPlatform platform;
  final TextSelectionSurface surface;

  int tapCount(int raw, PointerDeviceKind? kind) {
    final readOnly = surface == TextSelectionSurface.readOnly;
    return switch (platform) {
      TargetPlatform.android || TargetPlatform.fuchsia =>
        (raw - 1) % (readOnly && kind != PointerDeviceKind.mouse ? 2 : 3) + 1,
      TargetPlatform.linux => (raw - 1) % 3 + 1,
      TargetPlatform.windows =>
        readOnly
            ? math.min(raw, 3)
            : raw < 2
            ? raw
            : 2 + raw % 2,
      TargetPlatform.macOS || TargetPlatform.iOS => math.min(raw, 3),
    };
  }

  bool get tripleSelectsLine =>
      surface == TextSelectionSurface.editable &&
      platform == TargetPlatform.linux;

  bool supportsTripleTap(PointerDeviceKind? kind) =>
      surface == TextSelectionSurface.editable ||
      ![
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ].contains(platform) ||
      kind == PointerDeviceKind.mouse;

  TextRange wordBoundary(
    BlockTextGeometry geometry,
    TextPosition position, {
    bool endOfDocument = false,
  }) {
    if (surface == TextSelectionSurface.editable &&
        endOfDocument &&
        position.offset >= geometry.plainText.length) {
      return TextRange.collapsed(position.offset);
    }
    final range = geometry.getWordBoundary(position);
    return surface == TextSelectionSurface.readOnly &&
            position.offset > range.end
        ? TextRange.collapsed(position.offset)
        : range;
  }

  TextRange paragraphBoundary(String text, TextPosition position) {
    final boundary = ParagraphBoundary(text);
    final leading =
        position.offset == text.length ||
            (surface == TextSelectionSurface.readOnly &&
                position.affinity == TextAffinity.upstream)
        ? position.offset - 1
        : position.offset;
    return TextRange(
      start: boundary.getLeadingTextBoundaryAt(leading) ?? 0,
      end: boundary.getTrailingTextBoundaryAt(position.offset) ?? text.length,
    );
  }

  /// Preserve the anchor unit while crossing it in either direction. This
  /// operates on either rendered positions or editable model positions.
  static ({T base, T extent}) extendUnit<T>({
    required T anchorStart,
    required T anchorEnd,
    required T targetStart,
    required T targetEnd,
    required int Function(T, T) compare,
  }) => compare(anchorStart, targetEnd) < 0
      ? (base: anchorStart, extent: targetEnd)
      : (base: anchorEnd, extent: targetStart);
}

/// Reusable SDK recognizers with a pre-arena hit filter. Returning from a drag
/// callback is too late to protect links, embedded editors or image controls.
class RegionTapAndPanGestureRecognizer extends TapAndPanGestureRecognizer {
  RegionTapAndPanGestureRecognizer({
    this.canStartAt,
    super.debugOwner,
    super.supportedDevices,
  });
  final bool Function(Offset)? canStartAt;
  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) &&
      (canStartAt?.call(event.position) ?? true);
}

class RegionTapAndHorizontalDragGestureRecognizer
    extends TapAndHorizontalDragGestureRecognizer {
  RegionTapAndHorizontalDragGestureRecognizer({
    this.canStartAt,
    super.debugOwner,
    super.supportedDevices,
  });
  final bool Function(Offset)? canStartAt;
  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) &&
      (canStartAt?.call(event.position) ?? true);
}
