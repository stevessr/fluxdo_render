/// 渲染内容图片(非 emoji)时主项目要提供的 builder 签名。
///
/// 子包不实现 gallery / Hero / lightbox / 长按菜单 / upload:// 短链解析 /
/// CDN 重写等(主项目侧有 `discourseImageProvider` + `galleryInfo` + Hero
/// 路由 + 长按菜单 等完整体系),通过这个 typedef 注入。
///
/// **画廊 / Hero 怎么接**:
/// - `image.indexInPost`:当前图在 post 内的 0-based 序号(parser 分配)
/// - [totalImagesInPost]:当前 post 共多少张图(FluxdoRender 算好后传)
///
/// 主项目用这俩做确定性 Hero tag + 全屏 viewer 索引,无需自己在
/// builder 内累加索引或猜次序。
///
/// 调用方:
/// ```dart
/// FluxdoRender(
///   cookedHtml: ...,
///   imageContentBuilder: (context, image, totalImagesInPost) {
///     final heroTag = 'post_${post.id}_img_${image.indexInPost}';
///     return LazyImage(
///       imageProvider: discourseImageProvider(rewriteCdn(image.src)),
///       width: image.width, height: image.height,
///       heroTag: heroTag,
///       onTap: () => DiscourseImageUtils.openViewer(
///         context: context,
///         images: post.allImageUrls,
///         currentIndex: image.indexInPost,
///         heroTag: heroTag,
///       ),
///     );
///   },
/// );
/// ```

library;

import 'package:flutter/material.dart';

import '../node/node.dart';

/// 内容图片 builder。
///
/// - [image]:含 src / alt / width / height / **indexInPost**(parser 分配)
/// - [totalImagesInPost]:当前 post 共有多少张内容图,主项目用来构造
///   gallery viewer(`currentIndex`、`totalCount` 等)
typedef ImageContentBuilder = Widget Function(
  BuildContext context,
  ImageRun image,
  int totalImagesInPost,
);

/// 默认 image builder —— Image.network + broken-image fallback。
///
/// 主项目接入时**必须**注入自定义 builder(性能 / 缓存 / 鉴权差距大)。
/// 子包默认值仅供 example gallery 和单测使用。
Widget defaultImageContentBuilder(
  BuildContext context,
  ImageRun image,
  int totalImagesInPost,
) {
  if (image.src.isEmpty) {
    return _placeholder(context, image);
  }
  return Image.network(
    image.src,
    width: image.width,
    height: image.height,
    fit: BoxFit.contain,
    errorBuilder: (_, _, _) => _placeholder(context, image),
  );
}

Widget _placeholder(BuildContext context, ImageRun image) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    width: image.width ?? 120,
    height: image.height ?? 80,
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: scheme.outlineVariant),
    ),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(4),
    child: Icon(
      Icons.broken_image_outlined,
      size: 24,
      color: scheme.onSurfaceVariant,
    ),
  );
}

/// 图片网格 / 轮播 builder —— 主项目注入,接 legacy buildImageCarousel
/// (分页圆点 / 超过 10 张计数器 / 正负 1 预加载 / upload:// 解析 / 画廊左右切)。
///
/// 当前仅在 [ImageGridNode] 的 **carousel** 形态被 NodeFactory 调用:
/// - 返回非 null:用主项目的真轮播 Widget。
/// - 返回 null(或不注入):子包 fallback 为单列大图垂直叠(见
///   `NodeFactory.buildImageGrid`)。
///
/// grid(网格)形态仍由子包内置 Wrap 布局渲染,不走此 builder(瓦片内的
/// 单图复用 [ImageContentBuilder])。
///
/// 入参是整个 [ImageGridNode](含 images: `List<ImageRun>` / columns / mode),
/// 主项目据此映射成自己的画廊数据结构。
typedef ImageGridBuilder = Widget? Function(
  BuildContext context,
  ImageGridNode node,
);

/// 网格瓦片作用域标记 —— 子包 `_GridTile` 用它包住 imageContentBuilder
/// 的产物,让主项目的图片 widget 感知"自己正被 cover 裁切展示"
/// (瓦片形态:FittedBox cover + 圆角 4)。
///
/// 主项目据此在打开查看器时启用飞行 crossfade(cover 纹理层随飞行
/// 淡入淡出+圆角插值),消除「裁剪图↔完整图」的开合跳变;普通文档流
/// 图(contain 无裁切)读不到本标记,行为不变。
class GridTileScope extends InheritedWidget {
  const GridTileScope({super.key, required super.child});

  /// 当前 context 是否处于网格瓦片内
  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<GridTileScope>() != null;

  @override
  bool updateShouldNotify(GridTileScope oldWidget) => false;
}
/// Supplies the outer link tap handler to an image inside an anchor.
/// WidgetSpan children do not inherit TextSpan gesture recognizers.
class ImageLinkScope extends InheritedWidget {
  const ImageLinkScope({super.key, required this.onTap, required super.child});

  final VoidCallback onTap;

  static VoidCallback? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ImageLinkScope>()?.onTap;

  @override
  bool updateShouldNotify(ImageLinkScope oldWidget) =>
      onTap != oldWidget.onTap;
}
