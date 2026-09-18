import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 块与容器共用的浅色选中背景，不增加 padding，不改变正文布局。
class EditorObjectFrame extends StatelessWidget {
  const EditorObjectFrame({
    super.key,
    required this.selected,
    required this.child,
    this.onLayout,
  });
  final bool selected;
  final Widget child;
  final VoidCallback? onLayout;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(6),
      color: selected
          ? Theme.of(context).colorScheme.primary.withValues(
              alpha: MediaQuery.highContrastOf(context) ? .24 : .12,
            )
          : Colors.transparent,
    ),
    child: _ObjectLayoutObserver(onLayout: onLayout, child: child),
  );
}

class _ObjectLayoutObserver extends SingleChildRenderObjectWidget {
  const _ObjectLayoutObserver({required this.onLayout, required super.child});
  final VoidCallback? onLayout;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ObjectLayoutBox(onLayout);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _ObjectLayoutBox renderObject,
  ) {
    renderObject.onLayout = onLayout;
  }
}

class _ObjectLayoutBox extends RenderProxyBox {
  _ObjectLayoutBox(this.onLayout);
  VoidCallback? onLayout;
  @override
  void performLayout() {
    super.performLayout();
    onLayout?.call();
  }
}
