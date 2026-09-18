/// 可选文本块的通用包装器 —— 把「注册 handle + 选区高亮」封装一处,
/// 供 InlineSpanText(段落/标题/列表/表格 cell)和代码块共用,避免重复。
///
/// 用法:包住一个内部含 RichText/RenderParagraph 的 child,提供该块的
/// [projectionGetter](渲染偏移↔逻辑投影映射表)与 [documentOrder]/[chunkIndex]
/// (文档序,见 SelectableBlockId)。wrapper 自己:
/// - didChangeDependencies 用 (chunkIndex, documentOrder) 建 id 注册到 registry;
///   dispose 注销;每次 build 刷新逻辑块表 projection 快照(回收后保留)。
/// - paragraph getter 实时从 child 子树找第一个 RenderParagraph(虚拟化安全);
/// - 在 child 底下叠选区高亮层。
///
/// [codeLanguage] 非 null 时,写入逻辑块表 → 导出选区时带出 language
/// (代码块复制 ```lang)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../selection/block_text_geometry.dart';
import '../selection/projection.dart';
import '../selection/selectable_block_handle.dart';
import '../selection/selection_geometry.dart';
import '../selection/selection_highlight_painter.dart';
import '../selection/selection_registry.dart';
import '../selection/selection_scope.dart';
import 'inline_code_painter.dart';

class SelectableTextBox extends StatefulWidget {
  const SelectableTextBox({
    super.key,
    required this.projectionGetter,
    required this.documentOrder,
    required this.child,
    this.chunkIndex = 0,
    this.codeLanguage,
    this.clipBoundsKey,
    this.debugLabel,
    this.paintSelection = true,
  });

  /// 取当前块的映射表(InlineSpanText 每次 flatten 变;代码块静态)。
  final RenderTextProjection Function() projectionGetter;

  /// 块在 chunk 内的文档序(深度优先 build 递增,见 NodeFactory)。
  final int documentOrder;

  /// 所属 chunk 的文档序号(整帖渲染时 0)。
  final int chunkIndex;

  /// 内部含 RichText 的 child(Text.rich / highlighter 输出)。
  final Widget child;

  /// 非 null = 代码块,导出选区带此 language。
  final String? codeLanguage;

  /// 可视区裁剪边界的 GlobalKey(代码块传其限高 SizedBox 的 key)。块内有独立
  /// 滚动时,RenderParagraph.size 是完整内容尺寸 → 命中框溢出;用此 key 的
  /// RenderBox 全局矩形把命中框裁到可视区。null = 不裁剪(普通段落)。
  final GlobalKey? clipBoundsKey;

  final String? debugLabel;
  final bool paintSelection;

  @override
  State<SelectableTextBox> createState() => _SelectableTextBoxState();
}

class _SelectableTextBoxState extends State<SelectableTextBox> {
  final GlobalKey _childKey = GlobalKey();
  SelectableBlockHandle? _handle;
  SelectionController? _controller;
  bool _active = true;

  SelectableBlockId get _id => SelectableBlockId(
    widget.documentOrder,
    chunkIndex: widget.chunkIndex,
    debugLabel: widget.debugLabel,
  );

  /// 从 child 子树向下找第一个 RenderParagraph(代码块 highlighter 输出嵌套深)。
  RenderParagraph? _findParagraph() {
    if (!_active || !mounted) return null;
    final ctx = _childKey.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro == null) return null;
    return _firstParagraph(ro);
  }

  RenderParagraph? _firstParagraph(RenderObject node) {
    if (node is BlockTextGeometry && (node as BlockTextGeometry).isAtomic) {
      return null;
    }
    if (node is RenderParagraph) return node;
    RenderParagraph? found;
    node.visitChildren((child) {
      found ??= _firstParagraph(child);
    });
    return found;
  }

  /// 从 child 子树找第一个几何提供者:直绘 RenderObject(自实现
  /// BlockTextGeometry)优先,否则 RenderParagraph 包适配。两路径互斥
  /// (一个块只有一种文本渲染),深度优先首个命中即返回。
  BlockTextGeometry? _findGeometry() {
    if (!_active || !mounted) return null;
    final ctx = _childKey.currentContext;
    if (ctx == null) return null;
    final ro = ctx.findRenderObject();
    if (ro == null) return null;
    return _firstGeometry(ro);
  }

  BlockTextGeometry? _firstGeometry(RenderObject node) {
    if (node is BlockTextGeometry) return node as BlockTextGeometry;
    if (node is RenderParagraph) return ParagraphGeometry(node);
    BlockTextGeometry? found;
    node.visitChildren((child) {
      found ??= _firstGeometry(child);
    });
    return found;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = SelectionScope.maybeOfNoDepend(context);
    if (controller == _controller) return;
    _unregister();
    _controller = controller;
    _register();
  }

  @override
  void didUpdateWidget(covariant SelectableTextBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 文档序变化(罕见:内容重排)→ 换 id 重注册,逻辑块表跟着换键。
    if (oldWidget.documentOrder != widget.documentOrder ||
        oldWidget.chunkIndex != widget.chunkIndex) {
      _unregister();
      _register();
    }
  }

  /// 可视区裁剪矩形(代码块用 clipBoundsKey 指向的限高 SizedBox 的全局框)。
  Rect? _clipBounds() {
    if (!_active || !mounted) return null;
    final key = widget.clipBoundsKey;
    if (key == null) return null;
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    return ro.localToGlobal(Offset.zero) & ro.size;
  }

  /// 块自身 → SelectionScope 之间的全部祖先 Scrollable(实时走 Element 树,
  /// 不缓存 —— 虚拟化安全)。代码块 = [横滚, 限高纵滚],表格 cell = [表格横滚],
  /// 普通段落 = [](页面级滚动在 Scope 之上,不会被收进来)。拖选/拖托柄到
  /// 其视口边缘时,选区层驱动它们边缘自动滚(SelectionEdgeAutoScroller),
  /// 对齐 SDK 每个 Scrollable 自带 _ScrollableSelectionContainerDelegate
  /// 自滚自轴的行为 —— 否则代码块横向溢出部分永远选不到。
  List<ScrollableState> _interiorScrollables() {
    if (!_active || !mounted) return const [];
    final result = <ScrollableState>[];
    context.visitAncestorElements((el) {
      if (el.widget is SelectionScope) return false; // 作用域边界,到此为止
      if (el is StatefulElement && el.state is ScrollableState) {
        result.add(el.state as ScrollableState);
      }
      return true;
    });
    return result;
  }

  void _register() {
    final controller = _controller;
    if (controller == null) return;
    final id = _id;
    final clipGetter = widget.clipBoundsKey != null ? _clipBounds : null;
    _handle = CallbackBlockHandle(
      id: id,
      paragraphGetter: _findParagraph,
      projectionGetter: widget.projectionGetter,
      geometryGetter: _findGeometry,
      clipBoundsGetter: clipGetter,
      interiorScrollablesGetter: _interiorScrollables,
    );
    controller.registry.register(_handle!);
    // 初始写逻辑块表(projection 在 build 持续刷新,回收后保留最后值)。
    controller.registry.updateLogical(
      id,
      widget.projectionGetter(),
      codeLanguage: widget.codeLanguage,
    );
  }

  void _unregister() {
    final controller = _controller;
    final handle = _handle;
    if (controller != null && handle != null) {
      controller.registry.unregister(handle);
    }
    _handle = null;
  }

  @override
  void deactivate() {
    _active = false;
    // A deleted/reparented paragraph can remain mounted until the end of this
    // frame. It must stop participating in hit testing and selection painting
    // before dispose, otherwise a newly reused document-order id finds it.
    _unregister();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    _register();
  }

  @override
  void dispose() {
    _unregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget keyedChild = KeyedSubtree(key: _childKey, child: widget.child);

    // 行内代码背景:文字下层自绘圆角灰底(跨行 RRect 合并),与选区无关 →
    // selectionEnabled 与否都画。代码**块**(codeLanguage != null,整块自带背景)
    // 不画;**本段无行内代码区间时也不挂**(绝大多数段落,省一个
    // RenderCustomPaint 与其空跑 paint)。用 painter(非 foregroundPainter)
    // → 画在文字底下,文字照常透出;painter 内部自 clip 到块边界(对齐
    // legacy overlay 的 ClipRect,防 padding 出血画到相邻块文字上,见
    // InlineCodeBackgroundPainter 顶部说明)。内容变化(重新 flatten 产生
    // 新 projection)会触发本 build 重跑,挂载条件随之重估。
    // TextSpan 版 mention 的药丸底色同管线(mentionText 区间),条件并入。
    final projection = widget.projectionGetter();
    if (widget.codeLanguage == null &&
        (projection.hasInlineCode || projection.hasSpanMention)) {
      final scheme = Theme.of(context).colorScheme;
      keyedChild = CustomPaint(
        painter: InlineCodeBackgroundPainter(
          paragraphGetter: _findParagraph,
          projectionGetter: widget.projectionGetter,
          color: scheme.surfaceContainerHighest,
          mentionColor: scheme.surfaceContainerHigh,
        ),
        child: keyedChild,
      );
    }

    final controller = _controller;
    if (controller == null) return keyedChild;
    // 每次 build 刷新逻辑块表 projection 快照(内容变即更新;块回收后保留)。
    final handle = _handle;
    if (handle != null) {
      controller.registry.updateLogical(
        handle.id,
        widget.projectionGetter(),
        codeLanguage: widget.codeLanguage,
      );
    }
    // 高亮画在内容**上层**(盖 emoji/图片),必须用低透明度主题色,不能用
    // DefaultSelectionStyle.selectionColor —— 后者透明度不可控(某些主题接近
    // 不透明),画上层会糊住文字。统一用 primary @0.3,可控且文字/占位符透出。
    final highlightColor = Theme.of(
      context,
    ).colorScheme.primary.withValues(alpha: 0.3);
    if (!widget.paintSelection) return keyedChild;
    return SelectionHighlight(
      controller: controller,
      blockHandleGetter: () => _handle,
      color: highlightColor,
      child: keyedChild,
    );
  }
}
