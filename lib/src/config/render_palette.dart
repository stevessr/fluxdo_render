import 'package:flutter/material.dart';

/// 渲染引擎的语义色：ColorScheme 之外、随宿主主题变化的颜色。
///
/// 宿主通过 `ThemeData.extensions` 注入；未注入时取默认值（Material 命名
/// 色 + 原有点击数徽标配色），外观与引入本类之前一致。子包只依赖
/// Flutter，不感知宿主的主题系统。
@immutable
class FluxdoRenderPalette extends ThemeExtension<FluxdoRenderPalette> {
  const FluxdoRenderPalette({
    this.blue = Colors.blue,
    this.cyan = Colors.cyan,
    this.teal = Colors.teal,
    this.green = Colors.green,
    this.orange = Colors.orange,
    this.red = Colors.red,
    this.purple = Colors.purple,
    this.grey = Colors.grey,
    this.clickCountBackground,
    this.clickCountForeground,
  });

  /// callout 等语义提示的色相。
  final Color blue;
  final Color cyan;
  final Color teal;
  final Color green;
  final Color orange;
  final Color red;
  final Color purple;
  final Color grey;

  /// 链接点击数徽标的底色 / 文字色，null 时按明暗取默认灰。
  final Color? clickCountBackground;
  final Color? clickCountForeground;

  /// [theme] 注入的调色板，未注入时返回默认值。
  static FluxdoRenderPalette of(ThemeData theme) =>
      theme.extension<FluxdoRenderPalette>() ?? const FluxdoRenderPalette();

  @override
  FluxdoRenderPalette copyWith({
    Color? blue,
    Color? cyan,
    Color? teal,
    Color? green,
    Color? orange,
    Color? red,
    Color? purple,
    Color? grey,
    Color? clickCountBackground,
    Color? clickCountForeground,
  }) => FluxdoRenderPalette(
    blue: blue ?? this.blue,
    cyan: cyan ?? this.cyan,
    teal: teal ?? this.teal,
    green: green ?? this.green,
    orange: orange ?? this.orange,
    red: red ?? this.red,
    purple: purple ?? this.purple,
    grey: grey ?? this.grey,
    clickCountBackground: clickCountBackground ?? this.clickCountBackground,
    clickCountForeground: clickCountForeground ?? this.clickCountForeground,
  );

  @override
  FluxdoRenderPalette lerp(
    covariant FluxdoRenderPalette? other,
    double t,
  ) {
    if (other == null) return this;
    return FluxdoRenderPalette(
      blue: Color.lerp(blue, other.blue, t)!,
      cyan: Color.lerp(cyan, other.cyan, t)!,
      teal: Color.lerp(teal, other.teal, t)!,
      green: Color.lerp(green, other.green, t)!,
      orange: Color.lerp(orange, other.orange, t)!,
      red: Color.lerp(red, other.red, t)!,
      purple: Color.lerp(purple, other.purple, t)!,
      grey: Color.lerp(grey, other.grey, t)!,
      clickCountBackground: Color.lerp(
        clickCountBackground,
        other.clickCountBackground,
        t,
      ),
      clickCountForeground: Color.lerp(
        clickCountForeground,
        other.clickCountForeground,
        t,
      ),
    );
  }
}
