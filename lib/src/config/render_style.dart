import 'package:flutter/material.dart';

/// 渲染引擎的排版风格：标题字体、引用块外观等随宿主主题变化的版式。
///
/// 宿主通过 `ThemeData.extensions` 注入；未注入时取默认值，外观与引入
/// 本类之前一致。子包只依赖 Flutter，不感知宿主的主题系统。
@immutable
class FluxdoRenderStyle extends ThemeExtension<FluxdoRenderStyle> {
  const FluxdoRenderStyle({
    this.headingFontFamily,
    this.headingFontFamilyFallback,
    this.quoteBackground = true,
    this.quoteBarWidth = 4,
  });

  static const FluxdoRenderStyle standard = FluxdoRenderStyle();

  /// 正文标题（h1–h6）字体，null 跟随正文。
  final String? headingFontFamily;

  /// 标题字体的回退链（补标题字体缺的字），null 跟随正文。
  final List<String>? headingFontFamilyFallback;

  /// 引用块是否带浅色底；关闭时只留左侧竖条。
  final bool quoteBackground;

  /// 引用块左侧竖条宽度。
  final double quoteBarWidth;

  /// [theme] 注入的排版风格，未注入时为 [standard]。
  static FluxdoRenderStyle of(ThemeData theme) =>
      theme.extension<FluxdoRenderStyle>() ?? standard;

  /// 给标题样式套上标题字体。
  TextStyle applyHeading(TextStyle style) {
    final family = headingFontFamily;
    if (family == null) return style;
    return style.copyWith(
      fontFamily: family,
      fontFamilyFallback: [
        ...?headingFontFamilyFallback,
        ?style.fontFamily,
        ...?style.fontFamilyFallback,
      ],
    );
  }

  @override
  FluxdoRenderStyle copyWith({
    String? headingFontFamily,
    List<String>? headingFontFamilyFallback,
    bool? quoteBackground,
    double? quoteBarWidth,
  }) => FluxdoRenderStyle(
    headingFontFamily: headingFontFamily ?? this.headingFontFamily,
    headingFontFamilyFallback:
        headingFontFamilyFallback ?? this.headingFontFamilyFallback,
    quoteBackground: quoteBackground ?? this.quoteBackground,
    quoteBarWidth: quoteBarWidth ?? this.quoteBarWidth,
  );

  /// 版式是离散选择，主题切换时整体换档。
  @override
  FluxdoRenderStyle lerp(covariant FluxdoRenderStyle? other, double t) =>
      other == null || t < 0.5 ? this : other;

  @override
  bool operator ==(Object other) =>
      other is FluxdoRenderStyle &&
      other.headingFontFamily == headingFontFamily &&
      _listEquals(other.headingFontFamilyFallback, headingFontFamilyFallback) &&
      other.quoteBackground == quoteBackground &&
      other.quoteBarWidth == quoteBarWidth;

  @override
  int get hashCode => Object.hash(
    headingFontFamily,
    headingFontFamilyFallback == null
        ? null
        : Object.hashAll(headingFontFamilyFallback!),
    quoteBackground,
    quoteBarWidth,
  );

  static bool _listEquals(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
