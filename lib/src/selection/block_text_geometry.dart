/// 文本几何提供者 —— 选区/高亮/命中/导出对「一段已排版文本」的全部只读访问。
///
/// 抽象目的:解开选区体系对 [RenderParagraph] 的硬依赖,让"缓存
/// ui.Paragraph 直绘"的自定义 RenderObject(笔3 直绘路径)也能承载选区。
/// 实现:
/// - [ParagraphGeometry]:包 RenderParagraph(RichText 路径,现状全量);
/// - 直绘路径的 RenderObject 自实现本接口(持缓存 ui.Paragraph,几何原语
///   ui.Paragraph 全有:getPositionForOffset/getBoxesForRange/getWordBoundary)。
///
/// 非文本块由 SelectableObjectBlock 提供 before/after 两个边界。
///
/// 与句柄同约定:**不缓存实例**,每次经 handle 实时取(虚拟化安全)。
library;

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

abstract mixin class BlockTextGeometry {
  /// 宿主 RenderBox:坐标变换(localToGlobal/globalToLocal/size/attached)
  /// 与框架 hit-test 匹配都经它。
  RenderBox get renderBox;

  /// Text in rendered-offset coordinates, including placeholder characters.
  String get plainText;

  /// A non-text block with only before/after positions.
  bool get isAtomic => false;

  /// 局部坐标 → 文本位置。
  TextPosition getPositionForOffset(Offset local);

  /// 词边界(长按选词)。落在 ￼ 上返回 (n, n+1) → 整颗原子选中。
  TextRange getWordBoundary(TextPosition position);

  /// 选区盒(局部坐标)。
  List<TextBox> getBoxesForSelection(
    TextSelection selection, {
    ui.BoxHeightStyle boxHeightStyle = ui.BoxHeightStyle.tight,
  });

  /// 位置处 caret 的局部矩形(宽 0)。RichText 路径走 TextPainter 精确值;
  /// 直绘路径允许行盒近似(阅读态托柄/放大镜对亚像素不敏感)。
  Rect caretRectAt(int offset);

  // ---- 便捷透传 ----
  //
  // size/localToGlobal/globalToLocal 一律**不做**透传:RenderBox 自带同名
  // 成员,mixin 声明会覆写宿主(RenderCachedParagraph 混入后 size →
  // renderBox.size → 自己 → 无限递归 StackOverflow,实测教训)。
  // 消费方经 [renderBox] 访问。isLive 无撞名,保留。

  bool get isLive => renderBox.attached && renderBox.hasSize;
}

/// RenderParagraph 适配(RichText 路径)。
class ParagraphGeometry with BlockTextGeometry {
  ParagraphGeometry(this.paragraph);

  final RenderParagraph paragraph;

  @override
  RenderBox get renderBox => paragraph;

  @override
  String get plainText =>
      paragraph.text.toPlainText(includeSemanticsLabels: false);

  @override
  TextPosition getPositionForOffset(Offset local) =>
      paragraph.getPositionForOffset(local);

  @override
  TextRange getWordBoundary(TextPosition position) =>
      paragraph.getWordBoundary(position);

  @override
  List<TextBox> getBoxesForSelection(
    TextSelection selection, {
    ui.BoxHeightStyle boxHeightStyle = ui.BoxHeightStyle.tight,
  }) =>
      paragraph.getBoxesForSelection(selection, boxHeightStyle: boxHeightStyle);

  @override
  Rect caretRectAt(int offset) {
    final tp = TextPosition(offset: offset);
    final local = paragraph.getOffsetForCaret(tp, Rect.zero);
    final height = paragraph.getFullHeightForCaret(tp);
    return local & Size(0, height);
  }
}
