/// 渲染 quote_card 头像时主项目要提供的 builder 签名。
///
/// 子包不依赖 SmartAvatar / discourseImageProvider 等(主项目已有完整体系),
/// 通过这个 typedef 注入。
///
/// 调用方:
/// ```dart
/// FluxdoRender(
///   cookedHtml: ...,
///   quoteAvatarBuilder: (ctx, username, avatarUrl, size) {
///     return SmartAvatar(
///       imageUrl: rewriteCdn(avatarUrl ?? ''),
///       radius: size / 2,
///       fallbackText: username,
///     );
///   },
/// );
/// ```
///
/// 默认 fallback:首字母圆形 chip(灰底 + onSurfaceVariant 字色)。

library;

import 'package:material_ui/material_ui.dart';

typedef QuoteAvatarBuilder = Widget Function(
  BuildContext context,
  String username,
  String? avatarUrl,
  double size,
);

/// 默认 avatar builder —— 首字母圆形 chip,不联网。
Widget defaultQuoteAvatarBuilder(
  BuildContext context,
  String username,
  String? avatarUrl,
  double size,
) {
  final scheme = Theme.of(context).colorScheme;
  // 取 username 首字母大写,空时显示 ?
  final initial = username.isEmpty
      ? '?'
      : username.characters.first.toUpperCase();
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHigh,
      shape: BoxShape.circle,
    ),
    alignment: Alignment.center,
    child: Text(
      initial,
      style: TextStyle(
        fontSize: size * 0.55,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
        height: 1.0,
      ),
    ),
  );
}
