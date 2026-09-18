/// In-place image-group editing: immediate mouse drag, touch long-press drag,
/// explicit insertion targets, mode controls and a per-image action surface.
library;

import 'dart:math' as math;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';

import '../../node/node.dart';
import '../../render/image_handler.dart';
import '../../render/node_factory.dart';
import 'editor_table_grid.dart' show kEditorSelfManagedRegion;

/// 图片组内的单图目标，同时用于就地菜单、查看器和选中几何。
@immutable
class GridImageSelection {
  const GridImageSelection({
    required this.islandId,
    required this.imageIndex,
    required this.image,
    required this.globalRect,
  });

  /// grid 岛块 id。
  final String islandId;

  /// 在 ImageGridNode.images 中的下标。
  final int imageIndex;

  final ImageRun image;

  /// 瓦片全局矩形。
  final Rect globalRect;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GridImageSelection &&
          islandId == other.islandId &&
          imageIndex == other.imageIndex &&
          image == other.image &&
          globalRect == other.globalRect;

  @override
  int get hashCode => Object.hash(islandId, imageIndex, image, globalRect);
}

class EditorImageGrid extends StatefulWidget {
  const EditorImageGrid({
    super.key,
    required this.node,
    required this.islandId,
    required this.nodeFactory,
    this.selectedIndex,
    this.onImageTap,
    this.onImageOpen,
    this.onModeChange,
    this.onRemoveGrid,
    this.onRemoveImage,
    this.onMoveImageOut,
    this.onAltChanged,
    this.onReorder,
    this.showSelectionControls = true,
    this.onContextMenu,
    this.onSelectGrid,
    this.onSecondaryMenu,
    this.onImageMenu,
    this.onAddImages,
    this.addingImages = false,
    this.pendingUploads = const [],
    this.controlSurfaceBuilder,
  });

  final void Function(GridImageSelection image, Rect anchor)? onImageMenu;
  final VoidCallback? onAddImages;
  final bool addingImages;
  final List<Widget> pendingUploads;
  final Widget Function(BuildContext, Widget)? controlSurfaceBuilder;

  final ImageGridNode node;
  final String islandId;
  final NodeFactory nodeFactory;
  final bool showSelectionControls;
  final VoidCallback? onContextMenu;
  final VoidCallback? onSelectGrid;
  final void Function(GridImageSelection selection, Offset position)?
  onSecondaryMenu;

  /// 当前子选中的图下标(FluxdoEditor 持有;null = 无子选中)。
  final int? selectedIndex;

  /// 瓦片单击(未选中态)→ 请求子选中。
  final ValueChanged<GridImageSelection>? onImageTap;

  /// 点击查看按钮 → 请求打开查看器(宿主)。
  final ValueChanged<GridImageSelection>? onImageOpen;

  /// 头部常驻的 [网格|轮播] 模式切换。
  final ValueChanged<ImageGridMode>? onModeChange;

  /// 容器右下 [移除网格](拆壳保图)。
  final VoidCallback? onRemoveGrid;

  /// 子选中瓦片工具条:删除本图。
  final ValueChanged<int>? onRemoveImage;

  /// 子选中瓦片工具条:移出网格。
  final ValueChanged<int>? onMoveImageOut;

  /// 瓦片 alt 原位编辑保存(index, 新 alt)。
  final void Function(int index, String alt)? onAltChanged;

  /// 瓦片拖拽排序:第 [from] 张拖放到第 [to] 张瓦片上(落位 to 下标,
  /// 目标侧让位)。null = 不可排序。
  final void Function(int from, int to)? onReorder;

  @override
  State<EditorImageGrid> createState() => EditorImageGridState();
}

class EditorImageGridState extends State<EditorImageGrid> {
  final Map<int, GlobalKey> _tileKeys = {};
  final _carouselScroll = ScrollController();
  ScrollableState? _carouselScrollable;
  EdgeDraggingAutoScroller? _outerAutoScroll;
  EdgeDraggingAutoScroller? _carouselAutoScroll;
  int? _hovered;
  int? _dragging;
  (int, bool)? _dropTarget;

  bool get _hasImageActions =>
      widget.onImageMenu != null ||
      widget.onSecondaryMenu != null ||
      widget.onContextMenu != null ||
      widget.onImageOpen != null ||
      widget.onReorder != null ||
      widget.onAltChanged != null ||
      widget.onMoveImageOut != null ||
      widget.onRemoveImage != null;

  bool get _desktop => switch (Theme.of(context).platform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };

  @override
  void dispose() {
    _stopAutoScroll();
    _carouselScroll.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(int index) => _tileKeys.putIfAbsent(index, GlobalKey.new);

  GridImageSelection? selectionFor(int index) {
    if (index < 0 || index >= widget.node.images.length) return null;
    final box = _tileKeys[index]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    if (!topLeft.dx.isFinite || !topLeft.dy.isFinite) return null;
    return GridImageSelection(
      islandId: widget.islandId,
      imageIndex: index,
      image: widget.node.images[index],
      globalRect: topLeft & box.size,
    );
  }

  void _select(int index) {
    final selection = selectionFor(index);
    if (selection != null) widget.onImageTap?.call(selection);
  }

  void _menu(int index, Rect anchor, {bool secondary = false}) {
    final selection = selectionFor(index);
    if (selection == null) return;
    _select(index);
    if (secondary && widget.onSecondaryMenu != null) {
      widget.onSecondaryMenu!(selection, anchor.topLeft);
    } else if (widget.onImageMenu != null) {
      widget.onImageMenu!(selection, anchor);
    } else if (widget.onContextMenu != null) {
      widget.onContextMenu!();
    } else {
      _showFallbackMenu(index, anchor);
    }
  }

  Future<void> _showFallbackMenu(int index, Rect anchor) async {
    if (!_hasImageActions) return;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          overlay.globalToLocal(anchor.topLeft),
          overlay.globalToLocal(anchor.bottomRight),
        ),
        Offset.zero & overlay.size,
      ),
      items: [
        if (widget.onImageOpen != null)
          const PopupMenuItem(value: 'view', child: Text('查看图片')),
        if (widget.onReorder != null) ...[
          PopupMenuItem(
            value: 'previous',
            enabled: index > 0,
            child: const Text('前移一张'),
          ),
          PopupMenuItem(
            value: 'next',
            enabled: index < widget.node.images.length - 1,
            child: const Text('后移一张'),
          ),
        ],
        if (widget.onAltChanged != null)
          const PopupMenuItem(value: 'alt', child: Text('替代文本')),
        if (widget.onMoveImageOut != null)
          const PopupMenuItem(value: 'out', child: Text('移出网格')),
        if (widget.onRemoveImage != null)
          const PopupMenuItem(value: 'delete', child: Text('删除图片')),
      ],
    );
    if (!mounted || index >= widget.node.images.length) return;
    switch (action) {
      case 'view':
        final image = selectionFor(index);
        if (image != null) widget.onImageOpen?.call(image);
      case 'previous':
        widget.onReorder?.call(index, index - 1);
      case 'next':
        widget.onReorder?.call(index, index + 1);
      case 'out':
        widget.onMoveImageOut?.call(index);
      case 'delete':
        widget.onRemoveImage?.call(index);
      case 'alt':
        var text = widget.node.images[index].alt;
        final value = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('替代文本'),
            content: TextFormField(
              initialValue: text,
              autofocus: true,
              onChanged: (value) => text = value,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, text),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        if (mounted && value != null) widget.onAltChanged?.call(index, value);
      default:
        break;
    }
  }

  Widget _surface(Widget child) =>
      widget.controlSurfaceBuilder?.call(context, child) ??
      Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
        child: child,
      );

  void _startDrag(int index) {
    _select(index);
    final outer = Scrollable.maybeOf(context);
    if (outer != null) {
      _outerAutoScroll = EdgeDraggingAutoScroller(outer, velocityScalar: 30);
    }
    if (widget.node.mode == ImageGridMode.carousel &&
        _carouselScrollable != null) {
      _carouselAutoScroll = EdgeDraggingAutoScroller(
        _carouselScrollable!,
        velocityScalar: 30,
      );
    }
    setState(() {
      _dragging = index;
      _hovered = null;
    });
  }

  void _stopAutoScroll() {
    _outerAutoScroll?.stopAutoScroll();
    _carouselAutoScroll?.stopAutoScroll();
    _outerAutoScroll = null;
    _carouselAutoScroll = null;
  }

  void _endDrag() {
    _stopAutoScroll();
    if (mounted) {
      setState(() {
        _dragging = null;
        _dropTarget = null;
      });
    }
  }

  bool _accepts(_GridImageDrag data) =>
      data.islandId == widget.islandId &&
      listEquals(data.images, widget.node.images);

  int _destination(_GridImageDrag data, int index, Offset point) {
    final rect = selectionFor(index)?.globalRect;
    final after = rect != null && point.dx >= rect.center.dx;
    final boundary = index + (after ? 1 : 0);
    return (boundary - (data.from < boundary ? 1 : 0)).clamp(
      0,
      widget.node.images.length - 1,
    );
  }

  Widget _tile(int index, double size, ImageContentBuilder builder) {
    final image = widget.node.images[index];
    final selected = widget.selectedIndex == index;
    final toolsVisible =
        _hasImageActions &&
        _dragging == null &&
        (_hovered == index || selected) &&
        ModalRoute.of(context)?.isCurrent != false;
    final scheme = Theme.of(context).colorScheme;
    final buttonSize = _desktop ? 32.0 : 48.0;
    Widget photo() => ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox.square(
        dimension: size,
        child: FittedBox(
          fit: BoxFit.cover,
          child: AbsorbPointer(
            child: builder(context, image, widget.node.images.length),
          ),
        ),
      ),
    );
    final controls = Positioned(
      right: 4,
      top: 4,
      child: Visibility(
        visible: toolsVisible,
        maintainState: true,
        child: TextFieldTapRegion(
          child: _surface(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('grid-image-view-${widget.islandId}-$index'),
                  tooltip: '查看图片',
                  style: IconButton.styleFrom(
                    minimumSize: Size.square(buttonSize),
                    maximumSize: Size.square(buttonSize),
                    padding: const EdgeInsets.all(6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: widget.onImageOpen == null
                      ? null
                      : () {
                          final selected = selectionFor(index);
                          if (selected != null) {
                            widget.onImageOpen!(selected);
                          }
                        },
                  icon: const Icon(Icons.open_in_full_rounded, size: 18),
                ),
                Builder(
                  builder: (buttonContext) => IconButton(
                    key: ValueKey('grid-image-more-${widget.islandId}-$index'),
                    tooltip: '图片操作',
                    style: IconButton.styleFrom(
                      minimumSize: Size.square(buttonSize),
                      maximumSize: Size.square(buttonSize),
                      padding: const EdgeInsets.all(6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () {
                      final box = buttonContext.findRenderObject() as RenderBox;
                      _menu(index, box.localToGlobal(Offset.zero) & box.size);
                    },
                    icon: const Icon(Icons.more_horiz_rounded, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final body = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(index),
      onSecondaryTapUp: (details) =>
          _menu(index, details.globalPosition & Size.zero, secondary: true),
      child: SizedBox(
        key: _keyFor(index),
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            photo(),
            if (selected)
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            Positioned(
              left: 6,
              bottom: 6,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .5),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Text(
                      '${index + 1}',
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    // Keep the keyed tile (and its Tooltip/OverlayPortal) under the same
    // parents when dragging starts or a second image is added.
    final canReorder =
        widget.onReorder != null && widget.node.images.length > 1;
    final dragChild = Opacity(
      opacity: _dragging == index ? .25 : 1,
      child: body,
    );
    final data = _GridImageDrag(
      widget.islandId,
      index,
      List.of(widget.node.images),
    );
    final feedback = Builder(
      builder: (context) {
        final previewSize = size * .65;
        final screen = MediaQueryData.fromView(View.of(context)).size;
        final dx = data.pointer.dx + previewSize + 16 < screen.width
            ? 16.0
            : -previewSize - 16;
        final dy = data.pointer.dy > previewSize + 16
            ? -previewSize - 16
            : 16.0;
        // Keep the pointer and drop edge unobscured, including on touch screens.
        return Transform.translate(
          offset: data.anchor + Offset(dx, dy),
          child: Material(
            color: Colors.transparent,
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: SizedBox.square(
              dimension: previewSize,
              child: FittedBox(fit: BoxFit.cover, child: photo()),
            ),
          ),
        );
      },
    );
    void update(DragUpdateDetails details) {
      data.pointer = details.globalPosition;
      final area = Rect.fromCenter(
        center: details.globalPosition,
        width: 72,
        height: 72,
      );
      _outerAutoScroll?.startAutoScrollIfNecessary(area);
      _carouselAutoScroll?.startAutoScrollIfNecessary(area);
    }

    final draggable = _desktop
        ? Draggable<_GridImageDrag>(
            data: data,
            maxSimultaneousDrags: canReorder ? 1 : 0,
            dragAnchorStrategy: (d, c, p) {
              data.pointer = p;
              return data.anchor = childDragAnchorStrategy(d, c, p);
            },
            allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
            feedback: feedback,
            onDragStarted: () => _startDrag(index),
            onDragUpdate: update,
            onDragEnd: (_) => _endDrag(),
            child: dragChild,
          )
        : LongPressDraggable<_GridImageDrag>(
            data: data,
            maxSimultaneousDrags: canReorder ? 1 : 0,
            dragAnchorStrategy: (d, c, p) {
              data.pointer = p;
              return data.anchor = childDragAnchorStrategy(d, c, p);
            },
            delay: const Duration(milliseconds: 300),
            feedback: feedback,
            onDragStarted: () => _startDrag(index),
            onDragUpdate: update,
            onDragEnd: (_) => _endDrag(),
            child: dragChild,
          );
    return MouseRegion(
      cursor: widget.onReorder != null
          ? SystemMouseCursors.grab
          : SystemMouseCursors.click,
      onEnter: (_) {
        if (_desktop && _dragging == null) setState(() => _hovered = index);
      },
      onExit: (_) {
        if (_hovered == index) setState(() => _hovered = null);
      },
      child: DragTarget<_GridImageDrag>(
        onWillAcceptWithDetails: (details) =>
            canReorder && _accepts(details.data),
        onMove: (details) {
          if (!_accepts(details.data)) return;
          final rect = selectionFor(index)?.globalRect;
          if (rect == null) return;
          final next = (
            index,
            (details.offset + details.data.anchor).dx >= rect.center.dx,
          );
          if (_dropTarget != next) setState(() => _dropTarget = next);
        },
        onLeave: (_) {
          if (_dropTarget?.$1 == index) setState(() => _dropTarget = null);
        },
        onAcceptWithDetails: (details) {
          if (!canReorder || !_accepts(details.data)) return;
          widget.onReorder!(
            details.data.from,
            _destination(
              details.data,
              index,
              details.offset + details.data.anchor,
            ),
          );
        },
        builder: (context, candidates, _) => Stack(
          clipBehavior: Clip.none,
          children: [
            draggable,
            // Controls are siblings of the drag surface: a press on a button
            // never registers with Draggable, even if the pointer then moves.
            controls,
            if (candidates.isNotEmpty && _dropTarget?.$1 == index)
              Positioned(
                top: 0,
                bottom: 0,
                left: _dropTarget!.$2 ? null : -5,
                right: _dropTarget!.$2 ? -5 : null,
                width: 3,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: ValueKey('grid-drop-${widget.islandId}-$index'),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final images = widget.node.images;
    if (images.isEmpty) return const SizedBox.shrink();
    final carousel = widget.node.mode == ImageGridMode.carousel;
    final builder =
        widget.nodeFactory.imageContentBuilder ?? defaultImageContentBuilder;
    return MetaData(
      metaData: kEditorSelfManagedRegion,
      behavior: HitTestBehavior.opaque,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = math.max(0.0, constraints.maxWidth - 24);
          final small = constraints.maxWidth < 640;
          final preferred = small ? 150.0 : 200.0;
          final slots = images.length + widget.pendingUploads.length + (widget.onAddImages == null ? 0 : 1);
          final columns = math.min(
            slots,
            math.max(1, ((available + 8) / (small ? 120 : 184)).floor()),
          );
          final tileSize = carousel
              ? math.min(available, preferred)
              : math.min(preferred, (available - 8 * (columns - 1)) / columns);
          Widget addButton() {
            final icon = widget.addingImages
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_photo_alternate_outlined, size: 18);
            if (available < 300 ||
                MediaQuery.textScalerOf(context).scale(14) > 18) {
              return IconButton(
                key: ValueKey('grid-add-${widget.islandId}'),
                tooltip: widget.addingImages ? '正在添加' : '添加图片',
                onPressed: widget.addingImages ? null : widget.onAddImages,
                icon: icon,
              );
            }
            return TextButton.icon(
              key: ValueKey('grid-add-${widget.islandId}'),
              onPressed: widget.addingImages ? null : widget.onAddImages,
              icon: icon,
              label: Text(widget.addingImages ? '正在添加' : '添加图片'),
            );
          }

          final modeControl = widget.onModeChange == null
              ? Text(
                  carousel ? '轮播' : '网格',
                  style: Theme.of(context).textTheme.labelLarge,
                )
              : _ModeSegment(
                  mode: widget.node.mode,
                  onChange: widget.onModeChange!,
                );
          final count = Text(
            '${images.length} 张',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          );
          final more = widget.onSelectGrid == null
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: '图片组操作',
                  onPressed: widget.onSelectGrid,
                  icon: const Icon(Icons.more_horiz_rounded, size: 20),
                );
          final header = available < 460
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: modeControl),
                    Row(
                      children: [
                        count,
                        const Spacer(),
                        if (widget.onAddImages != null) addButton(),
                        more,
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    modeControl,
                    const SizedBox(width: 10),
                    count,
                    const Spacer(),
                    if (widget.onAddImages != null) addButton(),
                    more,
                  ],
                );
          final tiles = [
            for (var i = 0; i < images.length; i++) _tile(i, tileSize, builder),
            for (final pending in widget.pendingUploads)
              SizedBox.square(dimension: tileSize, child: pending),
            if (widget.onAddImages != null)
              SizedBox.square(
                dimension: tileSize,
                child: OutlinedButton(
                  key: ValueKey('grid-add-tile-${widget.islandId}'),
                  onPressed: widget.addingImages ? null : widget.onAddImages,
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    side: BorderSide(color: scheme.outlineVariant),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add_rounded, size: 26),
                      const SizedBox(height: 8),
                      Text(widget.addingImages ? '正在添加' : '添加图片'),
                    ],
                  ),
                ),
              ),
          ];
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  const SizedBox(height: 8),
                  // Mode changes must not reparent keyed image subtrees while
                  // this LayoutBuilder is laying out. Tooltips may have active
                  // overlay children outside this subtree at that moment.
                  Scrollbar(
                    controller: _carouselScroll,
                    thumbVisibility: carousel && _desktop,
                    child: SingleChildScrollView(
                      key: ValueKey('grid-viewport-${widget.islandId}'),
                      controller: _carouselScroll,
                      scrollDirection: Axis.horizontal,
                      physics: carousel
                          ? const ClampingScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      padding: EdgeInsets.only(bottom: carousel ? 12 : 0),
                      child: Builder(
                        builder: (context) {
                          _carouselScrollable = Scrollable.maybeOf(context);
                          return SizedBox(
                            width: carousel
                                ? tileSize * tiles.length +
                                      8 * (tiles.length - 1)
                                : available,
                            child: Wrap(
                              key: ValueKey('grid-wrap-${widget.islandId}'),
                              spacing: 8,
                              runSpacing: 8,
                              children: tiles,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _desktop ? '拖动图片排序 · 悬停显示操作' : '点选图片操作 · 长按拖动排序',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      if (carousel) ...[
                        IconButton(
                          tooltip: '向前浏览',
                          onPressed: () => _scrollCarousel(-tileSize - 8),
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        IconButton(
                          tooltip: '向后浏览',
                          onPressed: () => _scrollCarousel(tileSize + 8),
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ],
                      if (widget.showSelectionControls &&
                          widget.onRemoveGrid != null)
                        TextButton(
                          onPressed: widget.onRemoveGrid,
                          child: const Text('移除网格'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _scrollCarousel(double delta) {
    if (!_carouselScroll.hasClients) return;
    _carouselScroll.animateTo(
      (_carouselScroll.offset + delta).clamp(
        0,
        _carouselScroll.position.maxScrollExtent,
      ),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }
}

class _GridImageDrag {
  _GridImageDrag(this.islandId, this.from, this.images);
  Offset anchor = Offset.zero;
  Offset pointer = Offset.zero;
  final String islandId;
  final int from;
  final List<ImageRun> images;
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({required this.mode, required this.onChange});
  final ImageGridMode mode;
  final ValueChanged<ImageGridMode> onChange;
  @override
  Widget build(BuildContext context) => SegmentedButton<ImageGridMode>(
    segments: const [
      ButtonSegment(
        value: ImageGridMode.grid,
        icon: Icon(Icons.grid_view_rounded, size: 16),
        label: Text('网格'),
      ),
      ButtonSegment(
        value: ImageGridMode.carousel,
        icon: Icon(Icons.view_carousel_outlined, size: 16),
        label: Text('轮播'),
      ),
    ],
    selected: {mode},
    showSelectedIcon: false,
    style: SegmentedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      minimumSize: const Size(0, 40),
    ),
    onSelectionChanged: (value) => onChange(value.single),
  );
}
