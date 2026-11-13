import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 渲染引擎的圆角形状 token：调用方写设计值，按宿主主题的形状风格换算。
///
/// - 普通圆角：`设计值 × scale`，再按 [max] 封顶；
/// - 胶囊 / 圆形（设计值 ≥ [fullThreshold]）：不缩放，只在设有 [max] 时
///   收成上限。
///
/// 宿主通过 `ThemeData.extensions` 注入，并同步 [current] 供拿不到
/// context 的绘制代码使用；未注入时恒等换算，外观与引入本类之前一致。
/// 子包只依赖 Flutter，不感知宿主的主题系统。
@immutable
class FluxdoRenderShapes extends ThemeExtension<FluxdoRenderShapes> {
  const FluxdoRenderShapes({this.scale = 1.0, this.max});

  static const FluxdoRenderShapes standard = FluxdoRenderShapes();

  /// 当前生效的形状风格，供无 context 的代码使用；宿主在构建主题时同步。
  static FluxdoRenderShapes current = standard;

  static const double fullThreshold = 100;

  final double scale;
  final double? max;

  /// [theme] 注入的形状风格，未注入时为 [standard]。
  static FluxdoRenderShapes of(ThemeData theme) =>
      theme.extension<FluxdoRenderShapes>() ?? standard;

  double resolve(double design) {
    if (design >= fullThreshold) return max ?? design;
    final scaled = design * scale;
    final limit = max;
    return limit == null ? scaled : math.min(scaled, limit);
  }

  Radius radius(double design) => Radius.circular(resolve(design));

  BorderRadius borderRadius(double design) =>
      BorderRadius.circular(resolve(design));

  @override
  FluxdoRenderShapes copyWith({double? scale, double? max}) =>
      FluxdoRenderShapes(scale: scale ?? this.scale, max: max ?? this.max);

  @override
  FluxdoRenderShapes lerp(covariant FluxdoRenderShapes? other, double t) {
    if (other == null) return this;
    final a = max;
    final b = other.max;
    return FluxdoRenderShapes(
      scale: scale + (other.scale - scale) * t,
      max: a == null || b == null ? (t < 0.5 ? a : b) : a + (b - a) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FluxdoRenderShapes && other.scale == scale && other.max == max;

  @override
  int get hashCode => Object.hash(scale, max);
}

extension FluxdoRenderShapesContext on BuildContext {
  /// 当前主题注入的渲染形状风格。
  FluxdoRenderShapes get renderShapes =>
      FluxdoRenderShapes.of(Theme.of(this));
}
