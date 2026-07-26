/// 段落布局缓存 + 直绘 widget —— 正文版 TopicCardLayout 的文本层。
///
/// ## 模型(对齐 TopicCardLayout 的全局 LRU + ensureWidth)
///
/// [ParagraphLayoutCache]:(FlattenResult 身份, 环境样式, 宽度桶) → 已
/// layout 的 ui.Paragraph。FlattenResult 已按 (inlines, baseStyle, theme)
/// 全局缓存(FlattenCache),其身份携带内容+样式+主题;这里再叠**环境**
/// (DefaultTextStyle/方向/缩放/对齐)与宽度。
///
/// [CachedParagraphText]:直绘 widget。layout 阶段从缓存取(或建)
/// ui.Paragraph → performLayout 查表报尺寸;paint = drawParagraph。
/// **sliver 回收重进 = 缓存命中 = 零排版零测量**,笔3 收益主体。
///
/// ## RenderParagraph 布局语义对齐(golden 像素级验证)
///
/// 直绘必须是 Text.rich 的 drop-in,四个关键语义逐一复刻:
/// 1. **DefaultTextStyle 外层合并**:Text.rich 实际渲染的根 span 是
///    `TextSpan(style: DefaultTextStyle.of(ctx).style, children: [我们的
///    span])`,ParagraphStyle 也从这个外层 style 派生 —— 直绘同构;
/// 2. **宽度收缩**(TextWidthBasis.parent):layout(maxWidth) 后
///    contentWidth = clamp(maxIntrinsicWidth, minWidth, maxWidth),
///    与约束宽不同则按 contentWidth 重排(短文本不占满整列,否则
///    居中/对齐全部失真);
/// 3. **内在尺寸**:表格 IntrinsicColumnWidth 靠子树 min/maxIntrinsicWidth,
///    不实现列宽直接坍塌;
/// 4. **基线**:列表 marker 对齐读 alphabeticBaseline。
///
/// ## 适用面(分路判据,由 InlineSpanText 把关)
///
/// 只吃纯 TextSpan 段落(hasPlaceholders == false):WidgetSpan 原子
/// ui.Paragraph 画不出。链接可点(命中反查 recognizer,见下)。
///
/// ## 链接命中
///
/// RichText 的 recognizer 分发是 RenderParagraph 的能力,直绘自建等价物:
/// hitTestSelf 命中后经 getPositionForOffset 拿偏移,从 span 树
/// getSpanForPosition 反查 recognizer,addPointer 转发(SDK 同款语义)。
///
/// ## 选区 / 语义
///
/// 实现 [BlockTextGeometry](ui.Paragraph 原语)接入现有选区;semantics
/// 上报整段纯文本 label(a11y 朗读;粒度粗于 RenderParagraph 的逐 span,
/// 阅读态足够)。
library;

import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../flatten/inline_flattener.dart';
import '../selection/block_text_geometry.dart';
import 'paragraph_warmup.dart';

/// 直绘环境:除 FlattenResult 外影响排版结果的全部输入。
@immutable
class ParagraphEnv {
  const ParagraphEnv({
    required this.rootStyle,
    required this.textAlign,
    required this.textDirection,
    required this.textScaler,
  });

  /// DefaultTextStyle.of(ctx).style —— Text.rich 的外层合并语义(见库注释)。
  final TextStyle rootStyle;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final TextScaler textScaler;

  @override
  bool operator ==(Object other) =>
      other is ParagraphEnv &&
      other.rootStyle == rootStyle &&
      other.textAlign == textAlign &&
      other.textDirection == textDirection &&
      other.textScaler == textScaler;

  @override
  int get hashCode =>
      Object.hash(rootStyle, textAlign, textDirection, textScaler);
}

/// 已排版段落的缓存条目。
class ParagraphLayoutEntry {
  ParagraphLayoutEntry({
    required this.paragraph,
    required this.size,
  });

  final ui.Paragraph paragraph;

  /// 内容尺寸(宽 = contentWidth 收缩结果,高 = paragraph.height),
  /// performLayout 直接 constrain,零测量。
  final Size size;

  void dispose() => paragraph.dispose();
}

/// 段落的内在宽度度量(表格列宽用;按 env 缓存,与具体约束宽无关)。
class ParagraphIntrinsics {
  const ParagraphIntrinsics({
    required this.minIntrinsicWidth,
    required this.maxIntrinsicWidth,
  });

  final double minIntrinsicWidth;
  final double maxIntrinsicWidth;
}

/// (FlattenResult 身份, env, 宽度桶) → ParagraphLayoutEntry 的全局 LRU。
class ParagraphLayoutCache {
  ParagraphLayoutCache._();

  /// 条目上限。单条 = 一个已排版 ui.Paragraph(行盒 + 字形定位,数 KB~
  /// 数十 KB),512 条覆盖数个长帖的纯文字段落。
  static const int _cap = 512;

  static final LinkedHashMap<_LayoutKey, ParagraphLayoutEntry> _entries =
      LinkedHashMap();

  /// 内在度量缓存(与宽度无关,条目远少于布局缓存,跟随 evictAll 清)。
  static final Map<_MetricsKey, ParagraphIntrinsics> _metrics = {};

  static int hits = 0;
  static int misses = 0;
  static int get length => _entries.length;

  /// miss 时的排版计时上报钩子(主项目接 noteSpan;不设零成本)。
  static void Function(int micros)? profileHook;

  /// 取(或排)某段落在 [minWidth]..[maxWidth] 约束下的布局。
  /// 宽度桶 0.5px(TopicCardLayout.ensureWidth 同款阈值);tight 约束
  /// (minWidth == maxWidth)单独成桶(不收缩)。
  static ParagraphLayoutEntry obtain(
    FlattenResult flat,
    ParagraphEnv env,
    double minWidth,
    double maxWidth,
  ) {
    // 无界宽兜底:IntrinsicWidth/IntrinsicHeight 会以 infinity 询问内在尺寸,
    // 未约束的 Row / 横向 Scrollable 里布局也会给到无穷 maxWidth。此时退化成
    // 段落自身的内在宽度(语义 = 「有多宽排多宽」)。不兜底的话下面的宽度桶
    // `(inf * 2).round()` 会抛 "Unsupported operation: Infinity or NaN toInt",
    // 整棵内容子树布局失败 —— 表现就是正文一个像素都画不出来。
    if (!maxWidth.isFinite) {
      final natural = intrinsics(flat, env).maxIntrinsicWidth;
      maxWidth = natural < minWidth ? minWidth : natural;
    }
    final tight = minWidth == maxWidth;
    final key = _LayoutKey(flat, env, (maxWidth * 2).round(), tight);
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing; // LRU touch
      hits++;
      return existing;
    }
    misses++;
    final hook = profileHook;
    final sw = hook == null ? null : (Stopwatch()..start());
    final entry = _layout(flat, env, minWidth, maxWidth);
    if (sw != null && hook != null) {
      sw.stop();
      hook(sw.elapsedMicroseconds);
    }
    _entries[key] = entry;
    while (_entries.length > _cap) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest)!.dispose();
    }
    return entry;
  }

  /// 内在宽度度量(无限宽排一次,min/max 与约束无关;结果按 env 缓存)。
  static ParagraphIntrinsics intrinsics(FlattenResult flat, ParagraphEnv env) {
    final key = _MetricsKey(flat, env);
    final cached = _metrics[key];
    if (cached != null) return cached;
    final paragraph = _build(flat, env)
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final result = ParagraphIntrinsics(
      minIntrinsicWidth: paragraph.minIntrinsicWidth,
      maxIntrinsicWidth: paragraph.maxIntrinsicWidth,
    );
    paragraph.dispose();
    // 有界:跟布局缓存同源(FlattenResult 有限),粗略限一手防泄漏。
    if (_metrics.length > _cap) _metrics.clear();
    _metrics[key] = result;
    return result;
  }

  /// 全清(hot reload / 字体注册等环境级失效)。
  /// ui.Paragraph 的 dispose 安全:直绘 RenderObject 每次 layout 都经
  /// obtain 重取(不持旧引用跨 relayout)。
  static void evictAll() {
    for (final e in _entries.values) {
      e.dispose();
    }
    _entries.clear();
    _metrics.clear();
  }

  static ui.Paragraph _build(FlattenResult flat, ParagraphEnv env) {
    // Text.rich 同构:外层 DefaultTextStyle,内层我们的 span。
    final root = TextSpan(style: env.rootStyle, children: [flat.span]);
    final builder = ui.ParagraphBuilder(
      env.rootStyle.getParagraphStyle(
        textAlign: env.textAlign,
        textDirection: env.textDirection,
        textScaler: env.textScaler,
      ),
    );
    root.build(
      builder,
      textScaler: env.textScaler,
      dimensions: _placeholderDims(flat, env),
    );
    return builder.build();
  }

  /// 岛占位尺寸(直绘判据保证 islands 全非 null)。缩放语义对齐 SDK:
  /// RichText 给 WidgetSpan child 包 _AutoScaleInlineWidget(按字号缩放
  /// 因子放大 child),占位 = child 布局尺寸 × 因子;这里等价地把确定
  /// 尺寸 × 因子(emoji 尺寸恒derive自根字号,因子按根字号算)。
  static List<PlaceholderDimensions>? _placeholderDims(
      FlattenResult flat, ParagraphEnv env) {
    if (flat.islands.isEmpty) return const [];
    final scale = islandScale(flat, env);
    return [
      for (final island in flat.islands)
        PlaceholderDimensions(
          size: Size(island!.width * scale, island.height * scale),
          alignment: island.alignment,
        ),
    ];
  }

  /// 岛的 textScaler 缩放因子(1.0 = 无系统字体缩放,绝对主流)。
  static double islandScale(FlattenResult flat, ParagraphEnv env) {
    final fontSize =
        flat.span.style?.fontSize ?? env.rootStyle.fontSize ?? 14.0;
    if (fontSize == 0) return 0;
    return env.textScaler.scale(fontSize) / fontSize;
  }

  static ParagraphLayoutEntry _layout(
    FlattenResult flat,
    ParagraphEnv env,
    double minWidth,
    double maxWidth,
  ) {
    final paragraph = _build(flat, env)
      ..layout(ui.ParagraphConstraints(width: maxWidth));
    var contentWidth = maxWidth;
    if (minWidth != maxWidth) {
      // TextWidthBasis.parent 语义(TextPainter.layout 同款):
      // 收缩到内容宽,短文本不占满整列。
      contentWidth =
          paragraph.maxIntrinsicWidth.clamp(minWidth, maxWidth).toDouble();
      if (contentWidth != paragraph.width) {
        paragraph.layout(ui.ParagraphConstraints(width: contentWidth));
      }
    }
    return ParagraphLayoutEntry(
      paragraph: paragraph,
      size: Size(contentWidth, paragraph.height),
    );
  }
}

class _LayoutKey {
  _LayoutKey(this.flat, this.env, this.bucket, this.tight);
  final FlattenResult flat;
  final ParagraphEnv env;
  final int bucket;
  final bool tight;

  @override
  bool operator ==(Object other) =>
      other is _LayoutKey &&
      identical(other.flat, flat) &&
      other.env == env &&
      other.bucket == bucket &&
      other.tight == tight;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(flat), env, bucket, tight);
}

class _MetricsKey {
  _MetricsKey(this.flat, this.env);
  final FlattenResult flat;
  final ParagraphEnv env;

  @override
  bool operator ==(Object other) =>
      other is _MetricsKey &&
      identical(other.flat, flat) &&
      other.env == env;

  @override
  int get hashCode => Object.hash(identityHashCode(flat), env);
}

/// 直绘段落 widget:缓存 ui.Paragraph 上屏 + 链接命中 + 选区几何 + 语义。
///
/// [FlattenResult.islands] 非空时(emoji 段落)为 MultiChild:children =
/// 各岛的真 widget(RichText 路径同一实例,加载/动图/兜底零分歧),
/// layout 后按 getBoxesForPlaceholders 摆进占位坑 —— 与 RenderParagraph
/// 处理 WidgetSpan 同款机制(同一渲染树/变换链,非 overlay 对齐)。
class CachedParagraphText extends MultiChildRenderObjectWidget {
  CachedParagraphText({
    super.key,
    required this.result,
    this.textAlign,
  }) : super(
          children: [
            for (final island in result.islands)
              if (island != null) island.child,
          ],
        );

  final FlattenResult result;
  final TextAlign? textAlign;

  ParagraphEnv _env(BuildContext context) {
    final defaults = DefaultTextStyle.of(context);
    return ParagraphEnv(
      rootStyle: defaults.style,
      // Text 的对齐决策链:widget.textAlign ?? DefaultTextStyle.textAlign
      // ?? TextAlign.start。
      textAlign: textAlign ?? defaults.textAlign ?? TextAlign.start,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
  }

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderCachedParagraph(result: result, env: _env(context));

  @override
  void updateRenderObject(
      BuildContext context, RenderCachedParagraph renderObject) {
    renderObject
      ..result = result
      ..env = _env(context);
  }
}

/// 岛子节点的 parentData(占位坑偏移由 performLayout 回填)。
class _IslandParentData extends ContainerBoxParentData<RenderBox> {}

/// 直绘 RenderObject。布局 = 缓存查询 + 岛坑位回填;绘制 = drawParagraph
/// + 岛子节点;命中 = 岛子节点优先,再偏移反查 recognizer;选区 =
/// BlockTextGeometry;语义 = 整段 label。
class RenderCachedParagraph extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _IslandParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _IslandParentData>,
        BlockTextGeometry {
  RenderCachedParagraph({
    required FlattenResult result,
    required ParagraphEnv env,
  })  : _result = result,
        _env = env;

  FlattenResult _result;
  FlattenResult get result => _result;
  set result(FlattenResult value) {
    if (identical(_result, value)) return;
    _result = value;
    _entry = null;
    _cachedPlainText = null;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  ParagraphEnv _env;
  ParagraphEnv get env => _env;
  set env(ParagraphEnv value) {
    if (_env == value) return;
    _env = value;
    _entry = null;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  ParagraphLayoutEntry? _entry;
  String? _cachedPlainText;

  String get _plainText =>
      _cachedPlainText ??= _result.span.toPlainText(includePlaceholders: false);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _IslandParentData) {
      child.parentData = _IslandParentData();
    }
  }

  // ---- RenderBox ----

  @override
  void performLayout() {
    final entry = _entry = ParagraphLayoutCache.obtain(
      _result,
      _env,
      constraints.minWidth,
      constraints.maxWidth,
    );
    // 预热探针:登记真实布局用的 (env, 约束宽),idle 预热同源构 key。
    ParagraphWarmupProbe.noteEnv(
        _env, constraints.minWidth, constraints.maxWidth);
    size = constraints.constrain(entry.size);

    // 岛子节点:tight 约束到占位尺寸(与 addPlaceholder 一致;emoji
    // builder 契约本就按 size 出图),坑位来自段落布局的占位盒。
    var child = firstChild;
    if (child == null) return;
    final boxes = entry.paragraph.getBoxesForPlaceholders();
    final scale = ParagraphLayoutCache.islandScale(_result, _env);
    var boxIndex = 0;
    for (final island in _result.islands) {
      if (island == null) continue; // 直绘判据下不该出现,防御跳过
      if (child == null || boxIndex >= boxes.length) break;
      final box = boxes[boxIndex].toRect();
      child.layout(BoxConstraints.tight(
        Size(island.width * scale, island.height * scale),
      ));
      (child.parentData! as _IslandParentData).offset = box.topLeft;
      child = (child.parentData! as _IslandParentData).nextSibling;
      boxIndex++;
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      ParagraphLayoutCache.intrinsics(_result, _env).minIntrinsicWidth;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      ParagraphLayoutCache.intrinsics(_result, _env).maxIntrinsicWidth;

  @override
  double computeMinIntrinsicHeight(double width) =>
      _heightAtWidth(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _heightAtWidth(width);

  // 注:IntrinsicWidth/IntrinsicHeight 会以 infinity 询问内在高度,无界宽由
  // ParagraphLayoutCache.obtain 统一兜底(退化成段落自身的内在宽度)。
  double _heightAtWidth(double width) =>
      ParagraphLayoutCache.obtain(_result, _env, 0, width).size.height;

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final p = _entry?.paragraph;
    if (p == null) return null;
    return switch (baseline) {
      TextBaseline.alphabetic => p.alphabeticBaseline,
      TextBaseline.ideographic => p.ideographicBaseline,
    };
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final entry = _entry;
    if (entry == null) return;
    context.canvas.drawParagraph(entry.paragraph, offset);
    defaultPaint(context, offset); // 岛子节点(emoji)画在文字之上
  }

  // ---- 语义(a11y 朗读;整段 label,粒度粗于 RenderParagraph 逐 span) ----

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..label = _plainText
      ..textDirection = _env.textDirection;
  }

  // ---- 链接命中(RenderParagraph.hitTestChildren 的直绘等价物) ----

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position); // 岛子节点优先

  @override
  void handleEvent(PointerEvent event, covariant BoxHitTestEntry entry) {
    if (event is! PointerDownEvent) return;
    _recognizerAt(entry.localPosition)?.addPointer(event);
  }

  GestureRecognizer? _recognizerAt(Offset local) {
    final paragraph = _entry?.paragraph;
    if (paragraph == null) return null;
    final pos = paragraph.getPositionForOffset(local);
    final span = _result.span.getSpanForPosition(TextPosition(
      offset: pos.offset,
      affinity: pos.affinity,
    ));
    return span is TextSpan ? span.recognizer : null;
  }

  // ---- BlockTextGeometry ----

  @override
  RenderBox get renderBox => this;

  @override
  TextPosition getPositionForOffset(Offset local) {
    final p = _entry?.paragraph;
    if (p == null) return const TextPosition(offset: 0);
    return p.getPositionForOffset(local);
  }

  @override
  TextRange getWordBoundary(TextPosition position) {
    final p = _entry?.paragraph;
    if (p == null) return TextRange.collapsed(position.offset);
    return p.getWordBoundary(position);
  }

  @override
  List<TextBox> getBoxesForSelection(
    TextSelection selection, {
    ui.BoxHeightStyle boxHeightStyle = ui.BoxHeightStyle.tight,
  }) {
    final p = _entry?.paragraph;
    if (p == null) return const [];
    return p.getBoxesForRange(
      selection.start,
      selection.end,
      boxHeightStyle: boxHeightStyle,
    );
  }

  @override
  Rect caretRectAt(int offset) {
    // 行盒近似(阅读态托柄/放大镜够用;编辑光标不走直绘路径):
    // 取 offset 右侧字符盒左边线;末尾取左侧盒右边线;空段 Rect.zero。
    final p = _entry?.paragraph;
    if (p == null) return Rect.zero;
    final right = p.getBoxesForRange(offset, offset + 1);
    if (right.isNotEmpty) {
      final b = right.first;
      return Rect.fromLTWH(b.left, b.top, 0, b.bottom - b.top);
    }
    if (offset > 0) {
      final left = p.getBoxesForRange(offset - 1, offset);
      if (left.isNotEmpty) {
        final b = left.last;
        return Rect.fromLTWH(b.right, b.top, 0, b.bottom - b.top);
      }
    }
    return Rect.zero;
  }
}
