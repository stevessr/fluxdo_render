import 'package:flutter/widgets.dart';

/// 内容中的可点击区域。光标跟随点击命中范围，子控件可以指定自己的光标。
class ContentTapTarget extends StatelessWidget {
  const ContentTapTarget({
    super.key,
    required this.onTap,
    required this.child,
    this.onTapDown,
    this.behavior,
    this.cursor = SystemMouseCursors.click,
  });

  final VoidCallback? onTap;
  final GestureTapDownCallback? onTapDown;
  final HitTestBehavior? behavior;
  final MouseCursor cursor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
    return MouseRegion(
      cursor: cursor,
      hitTestBehavior: HitTestBehavior.deferToChild,
      child: GestureDetector(
        onTap: onTap,
        onTapDown: onTapDown,
        behavior: behavior,
        child: child,
      ),
    );
  }
}
