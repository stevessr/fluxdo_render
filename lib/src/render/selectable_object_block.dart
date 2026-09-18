/// Non-text content participates in the same registry as paragraphs, as one
/// indivisible document unit. Children keep their own controls and gestures.
library;

import 'dart:ui' show BoxHeightStyle;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../selection/block_text_geometry.dart';
import '../selection/projection.dart';
import '../selection/selection_registry.dart';
import '../selection/selection_scope.dart';
import 'selectable_text_box.dart';

class SelectableObjectBlock extends StatefulWidget {
  const SelectableObjectBlock({
    super.key,
    required this.documentOrder,
    required this.text,
    required this.child,
    this.chunkIndex = 0,
    this.isolateChildren = false,
    this.copyText,
    this.paintSelection = true,
    this.codeLanguage,
  });
  final int documentOrder;
  final int chunkIndex;
  final String text;
  final bool isolateChildren;
  final String? copyText;
  final bool paintSelection;
  final String? codeLanguage;
  final Widget child;

  @override
  State<SelectableObjectBlock> createState() => _SelectableObjectBlockState();
}

class _SelectableObjectBlockState extends State<SelectableObjectBlock> {
  // Labels inside a card are not additional document blocks. In particular,
  // editor islands may contain their own independent text-selection scope.
  final _children = SelectionController(SelectionRegistry());

  @override
  void dispose() {
    _children.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SelectableTextBox(
    documentOrder: widget.documentOrder,
    chunkIndex: widget.chunkIndex,
    paintSelection: widget.paintSelection,
    codeLanguage: widget.codeLanguage,
    projectionGetter: () => RenderTextProjection([
      ProjectionEntry(
        renderStart: 0,
        renderLen: 1,
        logicalText: widget.text,
        copyText: widget.copyText,
        kind: ProjectionKind.blockObject,
      ),
    ]),
    child: _ObjectBox(
      child: widget.isolateChildren
          ? SelectionScope(controller: _children, child: widget.child)
          : widget.child,
    ),
  );
}

class _ObjectBox extends SingleChildRenderObjectWidget {
  const _ObjectBox({required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderObjectBox();
}

class _RenderObjectBox extends RenderProxyBox with BlockTextGeometry {
  @override
  RenderBox get renderBox => this;
  @override
  String get plainText => '\uFFFC';
  @override
  bool get isAtomic => true;
  @override
  TextPosition getPositionForOffset(Offset local) =>
      TextPosition(offset: local.dy < size.height / 2 ? 0 : 1);
  @override
  TextRange getWordBoundary(TextPosition position) =>
      const TextRange(start: 0, end: 1);
  @override
  List<TextBox> getBoxesForSelection(
    TextSelection selection, {
    BoxHeightStyle boxHeightStyle = BoxHeightStyle.tight,
  }) => selection.start < 1 && selection.end > 0
      ? [TextBox.fromLTRBD(0, 0, size.width, size.height, TextDirection.ltr)]
      : const [];
  @override
  Rect caretRectAt(int offset) => Rect.fromLTWH(
    offset == 0 ? 0 : size.width,
    offset == 0 ? 0 : (size.height - 20).clamp(0, double.infinity),
    0,
    size.height.clamp(0, 20),
  );
}
