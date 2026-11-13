/// 行内代码背景自绘 —— 在 InlineSpanText 的文字**下层**画圆角灰底,跨行时按行
/// 合并成连续 RSuperellipse(首行圆左角、末行圆右角)。
///
/// 对齐 legacy 装饰架构(`CombinedDecoratorOverlay` + `InlineCodePainter` +
/// `ScanBoundary`):legacy 给 `<code>` 设**透明 CSS 背景** + 标记字体,布局后
/// 扫描 RenderParagraph 定位 code 区间,把灰底画在内容 Stack **最底层**并用
/// ClipRect 裁剪;可滚动容器(表格)以 ScanBoundary 截断扫描、内部自挂 overlay,
/// 保证装饰**永远画在文字之下、且不越出所属容器**。新引擎按块(SelectableTextBox)
/// 自带这两条:painter 画在本块文字下层,块级 ClipRect 裁掉 padding 出血
/// (见 SelectableTextBox.build);表格 cell / 代码块各是独立块,天然"自带边界"。
///
/// 为什么自绘而非 `TextStyle.background`:后者只能画**直角矩形**,代码跨行会裂成
/// 两块独立矩形、无圆角、无 padding、贴字。自绘用 RenderParagraph 的
/// `getBoxesForSelection` 拿到每段 inline code 的字符矩形,复用选区高亮的
/// `mergeSelectionBoxesByLine` 按行合并,再加 padding + 圆角。
///
/// 代码**块**(`<pre><code>`,SelectableTextBox.codeLanguage != null,整块自带背景)
/// 不挂本 painter —— 见 SelectableTextBox.build。
library;

import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/rendering.dart';

import '../selection/projection.dart';
import '../selection/selection_highlight_painter.dart'
    show mergeSelectionBoxesByLine;

class InlineCodeBackgroundPainter extends CustomPainter {
  InlineCodeBackgroundPainter({
    required this.paragraphGetter,
    required this.projectionGetter,
    required this.color,
    required this.mentionColor,
  });

  /// 取本块 child 子树里的 RenderParagraph(虚拟化安全,实时找)。
  final RenderParagraph? Function() paragraphGetter;

  /// 取本块的渲染偏移↔逻辑投影映射表(含 inlineCode 区间)。
  final RenderTextProjection Function() projectionGetter;

  /// 灰底色(主项目主题 `colorScheme.surfaceContainerHighest`)。
  final Color color;

  /// TextSpan 版 mention 的药丸底色(`colorScheme.surfaceContainerHigh`,
  /// 对齐 WidgetSpan 版 Container 的装饰)。
  final Color mentionColor;

  // 与 legacy InlineCodePainter 完全一致:hPadding 3.5 / vPadding 1.5(对称)/
  // radius 3。不要私自加大 —— 之前顶部加到 3.0,出血伸进上一行文字底下,
  // 真机观感就是"背景溢出到别的文字下面"。
  //
  // _hPad 只是**上限**:实际水平出血按相邻 codePad(NBSP)的实测宽度 clamp
  // (见 paint 内注释),保证灰底构造上落在 pad 空白里、永不压到邻字。
  static const double _radius = 3.0;
  static const double _hPad = 3.5;
  static const double _vPad = 1.5;

  /// mention 药丸参数(对齐 WidgetSpan 版 Container 装饰):radius 10,
  /// 水平内边距上限 6(实际按相邻 mentionPad 的 NBSP 实测宽 clamp,
  /// 同 inline code 的出血策略);垂直方向用整行高盒(见 paint 内注释),
  /// 不再额外加 pad。
  static const double _mentionRadius = 10.0;
  static const double _mentionHPad = 6.0;

  /// 矩形几何缓存:同一 (paragraph, projection, 段落尺寸) 下 boxes 不变。
  /// 选区拖动等场景每帧连带重绘本 painter(CustomPaint 非 repaint 边界),
  /// 缓存后免去每帧 N 次 getBoxesForSelection。painter 随 rebuild 重建时
  /// 缓存自然丢弃(rebuild 已被上游 flatten/块缓存压到很少)。
  RenderParagraph? _cacheParagraph;
  RenderTextProjection? _cacheProjection;
  Size? _cacheSize;
  List<RSuperellipse>? _cacheRRects;
  List<RSuperellipse>? _cacheMentionRRects;

  @override
  void paint(Canvas canvas, Size size) {
    final projection = projectionGetter();
    // 快路径:无 inline code / span mention 区间 → 不取 paragraph,零成本。
    var hasCode = false;
    var hasMention = false;
    for (final e in projection.entries) {
      if (e.renderLen == 0) continue;
      if (e.kind == ProjectionKind.inlineCode) hasCode = true;
      if (e.kind == ProjectionKind.mentionText) hasMention = true;
      if (hasCode && hasMention) break;
    }
    if (!hasCode && !hasMention) return;
    final paragraph = paragraphGetter();
    if (paragraph == null) return;

    // 裁剪到块边界(对齐 legacy CombinedDecoratorOverlay 的 ClipRect):
    // padding 会伸出块外,CustomPaint 不裁剪 → 出血会画到相邻块的文字上
    // (compact 容器如 spoiler 内段落 margin 0,块间紧贴,上边 padding 正好
    // 糊住上一段文字)。块内文字永远在 painter 之上,不受影响。
    canvas.clipRect(Offset.zero & size, doAntiAlias: false);

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    final mentionPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = mentionColor;

    // 缓存命中:同段落实例 + 同投影表 + 布局尺寸未变 → 矩形必同,直接画。
    // (相同 span 在相同宽度下换行确定,relayout 而几何变了必伴随尺寸或
    //  投影/段落身份变化。)
    final cached = _cacheRRects;
    final cachedMention = _cacheMentionRRects;
    if (cached != null &&
        cachedMention != null &&
        identical(_cacheParagraph, paragraph) &&
        identical(_cacheProjection, projection) &&
        _cacheSize == paragraph.size) {
      for (final rrect in cachedMention) {
        canvas.drawRSuperellipse(rrect, mentionPaint);
      }
      for (final rrect in cached) {
        canvas.drawRSuperellipse(rrect, paint);
      }
      return;
    }

    final rrects = <RSuperellipse>[];
    final mentionRRects = <RSuperellipse>[];
    final entries = projection.entries;
    for (var idx = 0; idx < entries.length; idx++) {
      final e = entries[idx];
      final isCode = e.kind == ProjectionKind.inlineCode;
      final isMention = e.kind == ProjectionKind.mentionText;
      if ((!isCode && !isMention) || e.renderLen == 0) continue;

      final padKind =
          isCode ? ProjectionKind.codePad : ProjectionKind.mentionPad;
      final hPad = isCode ? _hPad : _mentionHPad;

      // 水平出血上限 = 相邻 pad(NBSP 粘性内边距,flattener 恒在两侧
      // 各注入一个)的**实测宽度**。NBSP 宽度随字体/字号浮动(≈0.25em):默认
      // 14px 时 ≈4.9px 兜得住 3.5,但正文字号调小后可能 < 上限 —— 写死
      // 会超出 pad 压到邻字边缘。取 min 后出血从构造上不可能触及邻字;
      // 无 pad 条目(理论不发生,防御)退回上限保持旧观感。
      final leftPad = idx > 0 && entries[idx - 1].kind == padKind
          ? _entryWidth(paragraph, entries[idx - 1])
          : hPad;
      final rightPad =
          idx + 1 < entries.length && entries[idx + 1].kind == padKind
          ? _entryWidth(paragraph, entries[idx + 1])
          : hPad;
      final leftBleed = leftPad < hPad ? leftPad : hPad;
      final rightBleed = rightPad < hPad ? rightPad : hPad;

      // code 用 BoxHeightStyle.tight(legacy 扫描同款默认值):贴合**代码
      // 字形自身**的行高(0.85em 小字),而非段落整行高 —— 对齐 legacy /
      // 浏览器观感。mention 药丸相反:WidgetSpan 版 Container 高度锁整行
      // (em*1.5),用整行高盒(BoxHeightStyle.max)填满整行。
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: e.renderStart, extentOffset: e.renderEnd),
        boxHeightStyle: isCode ? BoxHeightStyle.tight : BoxHeightStyle.max,
      );
      if (boxes.isEmpty) continue;
      final rows = mergeSelectionBoxesByLine(boxes);
      final radius = isCode ? _radius : _mentionRadius;
      final vPad = isCode ? _vPad : 0.0;
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        final isFirst = i == 0;
        final isLast = i == rows.length - 1;
        // pad 只存在于区间整体的首尾(NBSP 与相邻字符间不可断行,
        // 恒同行):首行左缘贴左 pad、末行右缘贴右 pad → 按各自 pad clamp;
        // 跨行折行处的边缘在行首/行尾,旁边没有文字,保持上限出血。
        final merged = Rect.fromLTRB(
          row.left - (isFirst ? leftBleed : hPad),
          row.top - vPad,
          row.right + (isLast ? rightBleed : hPad),
          row.bottom + vPad,
        );
        // 首行圆左角、末行圆右角(单行 = 四角全圆);中间行直角 → 跨行连成一条。
        final lr = isFirst ? Radius.circular(radius) : Radius.zero;
        final rr = isLast ? Radius.circular(radius) : Radius.zero;
        (isCode ? rrects : mentionRRects).add(RSuperellipse.fromRectAndCorners(
          merged,
          topLeft: lr,
          bottomLeft: lr,
          topRight: rr,
          bottomRight: rr,
        ));
      }
    }
    for (final rrect in mentionRRects) {
      canvas.drawRSuperellipse(rrect, mentionPaint);
    }
    for (final rrect in rrects) {
      canvas.drawRSuperellipse(rrect, paint);
    }
    _cacheParagraph = paragraph;
    _cacheProjection = projection;
    _cacheSize = paragraph.size;
    _cacheRRects = rrects;
    _cacheMentionRRects = mentionRRects;
  }

  /// 条目渲染区间的实测总宽(codePad 是单个 NBSP,恒单 box)。
  double _entryWidth(RenderParagraph paragraph, ProjectionEntry e) {
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: e.renderStart, extentOffset: e.renderEnd),
    );
    var w = 0.0;
    for (final b in boxes) {
      w += b.right - b.left;
    }
    return w;
  }

  @override
  bool shouldRepaint(InlineCodeBackgroundPainter old) =>
      old.color != color ||
      old.projectionGetter != projectionGetter ||
      old.paragraphGetter != paragraphGetter;
}
