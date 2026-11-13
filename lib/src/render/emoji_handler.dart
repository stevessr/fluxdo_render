/// 渲染 emoji 图片时主项目要提供的 builder 签名。
///
/// 子包不实现图片加载(主项目有 emojiImageProvider 独立缓存池、SVG 探测、
/// upload:// 短链解析、CDN 重写 等),通过这个 typedef 注入。
///
/// **约定**:builder 应该返回宽高 = [size] 的 widget(图片用 width/height,
/// fallback 视情况)。子包不会在 builder 外再加 SizedBox 约束,以免
/// fallback 文本被裁剪。
///
/// 调用方:
/// ```dart
/// FluxdoRender(
///   cookedHtml: ...,
///   emojiImageBuilder: (context, emoji, size) {
///     return Image(
///       image: emojiImageProvider(rewriteCdn(emoji.url)),
///       width: size, height: size,
///     );
///   },
/// );
/// ```

library;

import 'package:flutter/material.dart';

import '../node/inline_node.dart';
import '../config/render_shapes.dart';

/// Emoji 渲染 builder。
///
/// - [emoji] 包含 url / name / isOnlyEmoji
/// - [size] 已根据 isOnlyEmoji + 父字号算好的最终显示 px
typedef EmojiImageBuilder = Widget Function(
  BuildContext context,
  EmojiRun emoji,
  double size,
);

/// 默认 emoji builder —— Image.network + chip 样式 fallback。
///
/// 主项目接入时**必须**注入自定义 builder(性能差距大:Image.network
/// 不走主项目的统一缓存池 + 鉴权)。子包默认值仅供 example gallery
/// 和单测使用。
///
/// Fallback 形态:`:name:` 文本包在浅灰 chip 里,清晰提示"这里有 emoji
/// 但没图"。完整显示 name,不裁剪。Chip 总高度约等于 1em,跟相邻
/// 文字视觉对齐(避免 WidgetSpan 中点对齐时 chip 偏上偏下)。
Widget defaultEmojiImageBuilder(
  BuildContext context,
  EmojiRun emoji,
  double size,
) {
  Widget placeholder() {
    final text = emoji.name.isEmpty ? ':?:' : ':${emoji.name}:';
    final scheme = Theme.of(context).colorScheme;
    // Chip 总高 ≈ size(1em),跟周围文字垂直占位一致 ——
    // 字号 size*0.7 + 上下 padding 各 (size*0.15) = size
    final innerFontSize = size * 0.7;
    final vPad = size * 0.15;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: vPad),
      decoration: ShapeDecoration(color: scheme.surfaceContainerHigh,shape: RoundedSuperellipseBorder(borderRadius: context.renderShapes.borderRadius(3), ),),
      child: Text(
        text,
        style: TextStyle(
          fontSize: innerFontSize,
          fontFamily: 'monospace',
          color: scheme.onSurfaceVariant,
          height: 1.0,
        ),
      ),
    );
  }

  if (emoji.url.isEmpty) return placeholder();
  return Image.network(
    emoji.url,
    width: size,
    height: size,
    errorBuilder: (_, _, _) => placeholder(),
  );
}
