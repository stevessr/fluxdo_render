/// 编辑器移动端上下文动作条(复制/剪切/粘贴/全选)。
///
/// 壳照 SelectionToolbar 模式:OverlayEntry 浮层、选区上方定位、滚动
/// yCompensation 消抖;内容用 [AdaptiveTextSelectionToolbar.buttonItems]
/// —— iOS/Material 双形态、暗色、触控高度全部系统免费。
///
/// 与选区手柄配套(拖手柄时上层 hide,松手 show);定位 clamp 进
/// 键盘上方安全区。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

class EditorContextBar {
  EditorContextBar({
    required this.context,
    this.tapRegionGroupId,
  });

  final BuildContext context;

  /// 与编辑器选区层同 groupId:点条不触发 onTapOutside 清选区。
  final Object? tapRegionGroupId;

  static const double _barHeight = 44;

  OverlayEntry? _entry;
  Rect? _anchorGlobal;
  double _yComp = 0;
  List<ContextMenuButtonItem> _items = const [];

  bool get isShowing => _entry != null;

  /// 在 [selectionBounds](全局)上方显示。重复调用 = 刷新。
  void show({
    required Rect selectionBounds,
    required List<ContextMenuButtonItem> items,
  }) {
    _anchorGlobal = selectionBounds;
    _items = items;
    _yComp = 0;
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _entry = OverlayEntry(builder: _build);
    overlay.insert(_entry!);
  }

  /// 滚动跟随([yCompensation] = 本帧 scroll delta,消一帧几何滞后)。
  void reposition({Rect? selectionBounds, double yCompensation = 0}) {
    if (_entry == null) return;
    if (selectionBounds != null) _anchorGlobal = selectionBounds;
    _yComp = yCompensation;
    _entry!.markNeedsBuild();
  }

  void hide() {
    _entry?.remove();
    _entry = null;
  }

  Widget _build(BuildContext ctx) {
    final anchor = _anchorGlobal;
    if (anchor == null || _items.isEmpty) return const SizedBox.shrink();
    final overlayBox =
        Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return const SizedBox.shrink();

    final tl = overlayBox.globalToLocal(anchor.topLeft);
    final selRect = Rect.fromLTWH(
      tl.dx,
      tl.dy - _yComp,
      anchor.width,
      anchor.height,
    );

    final mq = MediaQuery.maybeOf(ctx);
    final screenH = mq?.size.height ?? overlayBox.size.height;
    final minTop = (mq?.viewPadding.top ?? 0) + kToolbarHeight;
    // 键盘上方安全底
    final safeBottom =
        screenH - (mq?.viewInsets.bottom ?? 0) - (mq?.viewPadding.bottom ?? 0);

    // AdaptiveTextSelectionToolbar 按 anchors 自定位(primary 上方优先,
    // 放不下翻 secondary 下方);锚点竖直 clamp 进安全区。
    final primary = Offset(
      selRect.center.dx,
      selRect.top.clamp(minTop, math.max(minTop, safeBottom - _barHeight)),
    );
    final secondary = Offset(
      selRect.center.dx,
      selRect.bottom
          .clamp(minTop, math.max(minTop, safeBottom - _barHeight)),
    );

    final bar = AdaptiveTextSelectionToolbar.buttonItems(
      anchors: TextSelectionToolbarAnchors(
        primaryAnchor: primary,
        secondaryAnchor: secondary,
      ),
      buttonItems: _items,
    );

    final child = tapRegionGroupId == null
        ? bar
        : TapRegion(groupId: tapRegionGroupId, child: bar);

    return Positioned.fill(child: child);
  }
}
