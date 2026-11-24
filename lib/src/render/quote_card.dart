import 'package:material_ui/material_ui.dart';

import '../config/render_shapes.dart';
import '../config/render_style.dart';
import '../node/node.dart';
import 'ai_content_badge.dart';
import 'quote_avatar_handler.dart';

typedef QuoteCardLayout =
    Widget Function({
      Widget? trailing,
      Widget? body,
      Widget? footer,
      VoidCallback? onOpen,
      Color? categoryColor,
      String? floorLabel,
      bool disableSource,
      bool isCrossTopic,
    });
typedef QuoteCardBuilder =
    Widget Function(
      BuildContext context,
      QuoteCardNode quote,
      QuoteCardLayout layout,
      TextStyle? bodyStyle,
    );

class RenderQuoteCard extends StatelessWidget {
  const RenderQuoteCard({
    super.key,
    required this.quote,
    required this.body,
    required this.avatarBuilder,
    this.title,
    this.trailing,
    this.onOpen,
    this.onCategory,
    this.categoryColor,
    this.floorLabel,
    this.footer,
    this.isCrossTopic = false,
  });

  final QuoteCardNode quote;
  final Widget? title, body, trailing, footer;
  final QuoteAvatarBuilder avatarBuilder;
  final VoidCallback? onOpen, onCategory;
  final Color? categoryColor;
  final String? floorLabel;
  final bool isCrossTopic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = FluxdoRenderStyle.of(theme);
    final textDirection = Directionality.of(context);
    final nested =
        context.findAncestorWidgetOfExactType<RenderQuoteCard>() != null;
    final isTopic = title != null;
    final author = quote.displayName ?? quote.username;
    final hasAvatar = quote.avatarUrl != null || author.isNotEmpty;
    final number = quote.postNumber;
    final metaStyle = (theme.textTheme.labelSmall ?? const TextStyle())
        .copyWith(
          fontSize: 12,
          height: 1.25,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w400,
        );

    final Widget? category = quote.categoryName == null
        ? null
        : _QuoteLink(
            onTap: onCategory,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: categoryColor ?? scheme.outline,
                  ),
                  child: const SizedBox.square(dimension: 6.5),
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    quote.categoryName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                ),
              ],
            ),
          );

    final Widget? floor = number == null || number <= 0
        ? null
        : _FloorBadge(
            number: number,
            isCrossTopic: isCrossTopic,
            onTap: onOpen,
            label: floorLabel,
          );

    final hasHeader =
        hasAvatar ||
        isTopic ||
        category != null ||
        floor != null ||
        trailing != null ||
        quote.aiGenerated;

    Widget? headerWidget;
    if (hasHeader) {
      if (isTopic) {
        headerWidget = _buildTopicHeader(
          context: context,
          scheme: scheme,
          hasAvatar: hasAvatar,
          author: author,
          category: category,
          floor: floor,
          metaStyle: metaStyle,
        );
      } else {
        headerWidget = _buildPostHeader(
          context: context,
          theme: theme,
          scheme: scheme,
          hasAvatar: hasAvatar,
          author: author,
          category: category,
          floor: floor,
        );
      }
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ?headerWidget,
        if (hasHeader && body != null) SizedBox(height: isTopic ? 6 : 5),
        ?body,
        ?footer,
      ],
    );

    final barWidth = style.quoteBackground
        ? (nested ? 2.0 : style.quoteBarWidth.clamp(2.5, 3.5))
        : (nested ? 1.5 : style.quoteBarWidth.clamp(2.0, 3.0));
    final barColor = style.quoteBackground
        ? scheme.outline.withValues(alpha: nested ? 0.45 : 0.6)
        : scheme.outline.withValues(alpha: nested ? 0.45 : 0.65);

    final Widget card;
    if (style.quoteBackground) {
      final radius = context.renderShapes.radius(8);
      final startRadius = context.renderShapes.radius(2);
      card = ClipRSuperellipse(
        borderRadius: BorderRadiusDirectional.only(
          topStart: startRadius,
          bottomStart: startRadius,
          topEnd: radius,
          bottomEnd: radius,
        ).resolve(textDirection),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(
              alpha: nested ? 0.24 : 0.34,
            ),
          ),
          child: CustomPaint(
            painter: _QuoteRailPainter(
              color: barColor,
              width: barWidth,
              textDirection: textDirection,
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                barWidth + (nested ? 8 : 10),
                nested ? 6 : 7,
                nested ? 8 : 10,
                nested ? 6 : 8,
              ),
              child: content,
            ),
          ),
        ),
      );
    } else {
      card = CustomPaint(
        painter: _QuoteRailPainter(
          color: barColor,
          width: barWidth,
          textDirection: textDirection,
          radius: context.renderShapes.radius(barWidth / 2),
        ),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            barWidth + (nested ? 7 : 9),
            nested ? 1 : 2,
            0,
            nested ? 1 : 2,
          ),
          child: content,
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: nested ? 4 : 6),
      child: card,
    );
  }

  Widget _buildPostHeader({
    required BuildContext context,
    required ThemeData theme,
    required ColorScheme scheme,
    required bool hasAvatar,
    required String author,
    required Widget? category,
    required Widget? floor,
  }) {
    final nameStyle = (theme.textTheme.labelMedium ?? const TextStyle())
        .copyWith(
          fontSize: 13,
          height: 1.25,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        );
    final nameWidget = author.isEmpty
        ? null
        : Text(
            author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (hasAvatar)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: avatarBuilder(
              context,
              quote.username.isEmpty ? author : quote.username,
              quote.avatarUrl,
              18,
            ),
          ),
        if (quote.aiGenerated)
          const Padding(
            padding: EdgeInsetsDirectional.only(end: 4),
            child: AiContentBadge(),
          ),
        Expanded(
          child: category == null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (nameWidget != null) Flexible(child: nameWidget),
                    if (nameWidget != null && floor != null)
                      const SizedBox(width: 6),
                    ?floor,
                  ],
                )
              : Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [?nameWidget, category, ?floor],
                ),
        ),
        if (trailing != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4),
            child: trailing!,
          ),
      ],
    );
  }

  Widget _buildTopicHeader({
    required BuildContext context,
    required ColorScheme scheme,
    required bool hasAvatar,
    required String author,
    required Widget? category,
    required Widget? floor,
    required TextStyle metaStyle,
  }) {
    final hasMeta = hasAvatar || category != null || floor != null;
    final dot = Text(
      '·',
      style: metaStyle.copyWith(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (quote.aiGenerated)
              const Padding(
                padding: EdgeInsetsDirectional.only(end: 4, top: 2),
                child: AiContentBadge(),
              ),
            Expanded(
              child: _QuoteLink(onTap: onOpen, child: title!),
            ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 4),
                child: trailing!,
              ),
          ],
        ),
        if (hasMeta) ...[
          const SizedBox(height: 3),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (hasAvatar)
                avatarBuilder(
                  context,
                  quote.username.isEmpty ? author : quote.username,
                  quote.avatarUrl,
                  16,
                ),
              ?category,
              if (category != null && floor != null) dot,
              ?floor,
            ],
          ),
        ],
      ],
    );
  }
}

class _FloorBadge extends StatelessWidget {
  const _FloorBadge({
    required this.number,
    required this.isCrossTopic,
    this.onTap,
    this.label,
  });

  final int number;
  final bool isCrossTopic;
  final VoidCallback? onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final interactive = onTap != null;
    final fg = interactive
        ? scheme.primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.7);
    final textStyle = (theme.textTheme.labelSmall ?? const TextStyle())
        .copyWith(
          fontSize: 11.5,
          height: 1.2,
          fontWeight: interactive ? FontWeight.w600 : FontWeight.w500,
          color: fg,
          fontFeatures: const [FontFeature.tabularFigures()],
        );

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('#$number', style: textStyle),
        if (isCrossTopic) ...[
          const SizedBox(width: 2),
          CustomPaint(
            size: const Size.square(9.5),
            painter: _ExternalArrowPainter(color: fg),
          ),
        ],
      ],
    );

    if (!interactive) return content;

    final badgeRadius = context.renderShapes.borderRadius(4);
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: badgeRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        child: content,
      ),
    );
    return _QuoteLink(
      onTap: onTap,
      label: label,
      borderRadius: badgeRadius,
      child: pill,
    );
  }
}

class _QuoteLink extends StatelessWidget {
  const _QuoteLink({
    required this.child,
    this.onTap,
    this.label,
    this.padding,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? label;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final inner = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    if (onTap == null) return inner;
    final result = Semantics(
      link: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius ?? context.renderShapes.borderRadius(4),
        child: inner,
      ),
    );
    return label == null ? result : Tooltip(message: label!, child: result);
  }
}

class _QuoteRailPainter extends CustomPainter {
  const _QuoteRailPainter({
    required this.color,
    required this.width,
    required this.textDirection,
    this.radius,
  });

  final Color color;
  final double width;
  final TextDirection textDirection;
  final Radius? radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0 || width <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final left = textDirection == TextDirection.rtl ? size.width - width : 0.0;
    final r = radius;
    if (r != null && r != Radius.zero) {
      final inset = size.height > 4 ? 1.0 : 0.0;
      canvas.drawRRect(
        RRect.fromLTRBR(
          left,
          inset,
          left + width,
          size.height - inset,
          r,
        ),
        paint,
      );
    } else {
      canvas.drawRect(Rect.fromLTWH(left, 0, width, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_QuoteRailPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.radius != radius;
}

class _ExternalArrowPainter extends CustomPainter {
  const _ExternalArrowPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.28, h * 0.22)
      ..lineTo(w * 0.82, h * 0.22)
      ..lineTo(w * 0.82, h * 0.76);
    canvas.drawPath(path, paint);
    canvas.drawLine(
      Offset(w * 0.2, h * 0.84),
      Offset(w * 0.8, h * 0.24),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ExternalArrowPainter oldDelegate) =>
      oldDelegate.color != color;
}
