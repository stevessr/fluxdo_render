/// 段落渲染预热 —— 把「首见段落」也变成缓存命中。
///
/// ## 背景
///
/// FlattenCache + ParagraphLayoutCache 落地后,纯文字段落**回滚**已是
/// 零排版;但**首次滚进视口**仍要在滚动帧里付 flatten + 排版。本模块
/// 提供 idle 预热原语:滚动停止后,宿主(TopicPostList)在空闲帧对
/// 即将滚到的楼层逐段预 flatten + 预排版,产物落进两层全局缓存 ——
/// 滚到时全程查表,这是 Telegram「后台预排」的 UI 线程等价物。
///
/// ## key 同源(探针,预热命中率的命门)
///
/// 缓存 key 含 theme(identical 比对)与 env(挂载处 DefaultTextStyle
/// 派生)。预热侧手工重建这条链必然漂移(值等而实例不等、或构造逻辑
/// 复制后 drift),预热就全部白做。因此用**探针登记**:真实挂载的直绘
/// 块把自己 acquire/obtain 时用的 (baseStyle, theme, flattener) 与
/// (env, 宽度) 登记进 [ParagraphWarmupProbe](按出现次数计数,取众数
/// ——正文段落数量碾压 heading 等偏格,收敛快且自适应主题/字号切换)。
/// 首屏挂载几段后探针就绪,预热用探针快照构 key,与挂载 100% 同源。
///
/// 若探针登记的 theme 与预热 flatten 读色的 context 不一致(理论罕见),
/// 后果只是缓存 miss 重做,不会串色 —— 挂载路径永远自建正确产物。
library;

import 'package:material_ui/material_ui.dart';

import '../flatten/flatten_cache.dart';
import '../flatten/inline_flattener.dart';
import '../node/node.dart';
import 'cached_paragraph_text.dart';
import 'emoji_handler.dart';
import 'footnote_handler.dart';
import 'image_handler.dart';
import 'link_handler.dart';
import 'local_date_handler.dart';
import 'math_handler.dart';
import 'mention_handler.dart';

/// 直绘段落的挂载环境快照(探针产物)。
class WarmupContext {
  const WarmupContext({
    required this.baseStyle,
    required this.theme,
    required this.flattener,
    required this.env,
    required this.minWidth,
    required this.maxWidth,
  });

  final TextStyle baseStyle;
  final ThemeData theme;
  final InlineFlattener flattener;
  final ParagraphEnv env;
  final double minWidth;
  final double maxWidth;
}

/// 挂载环境探针:直绘块登记,预热器取众数快照。
class ParagraphWarmupProbe {
  ParagraphWarmupProbe._();

  static const int _cap = 8;

  // (baseStyle, theme, flattener) → 出现次数
  static final Map<_StyleKey, int> _styles = {};
  // (env, minWidth, maxWidth) → 出现次数
  static final Map<_EnvKey, int> _envs = {};

  /// InlineSpanText 直绘分路成立时登记(build 路径,只做 map 自增)。
  static void noteStyle(
      TextStyle baseStyle, ThemeData theme, InlineFlattener flattener) {
    final key = _StyleKey(baseStyle, theme, flattener);
    _styles[key] = (_styles[key] ?? 0) + 1;
    if (_styles.length > _cap) _prune(_styles);
  }

  /// RenderCachedParagraph.performLayout 登记(layout 路径)。
  static void noteEnv(ParagraphEnv env, double minWidth, double maxWidth) {
    final key = _EnvKey(env, minWidth, maxWidth);
    _envs[key] = (_envs[key] ?? 0) + 1;
    if (_envs.length > _cap) _prune(_envs);
  }

  /// 众数快照;任一侧未收敛(无登记)返回 null(预热器跳过本轮)。
  static WarmupContext? snapshot() {
    final style = _top(_styles);
    final env = _top(_envs);
    if (style == null || env == null) return null;
    return WarmupContext(
      baseStyle: style.baseStyle,
      theme: style.theme,
      flattener: style.flattener,
      env: env.env,
      minWidth: env.minWidth,
      maxWidth: env.maxWidth,
    );
  }

  /// 主题/字号切换后旧登记失去意义,宿主可主动清(不清也会被新登记
  /// 的计数逐步反超,只是慢几拍)。
  static void reset() {
    _styles.clear();
    _envs.clear();
  }

  static K? _top<K>(Map<K, int> map) {
    K? best;
    var bestCount = 0;
    map.forEach((k, v) {
      if (v > bestCount) {
        bestCount = v;
        best = k;
      }
    });
    return best;
  }

  /// 超容时砍掉计数最低的一半,防主题反复切换堆积。
  static void _prune<K>(Map<K, int> map) {
    final entries = map.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (var i = 0; i < entries.length ~/ 2; i++) {
      map.remove(entries[i].key);
    }
  }
}

class _StyleKey {
  _StyleKey(this.baseStyle, this.theme, this.flattener);
  final TextStyle baseStyle;
  final ThemeData theme;
  final InlineFlattener flattener;

  @override
  bool operator ==(Object other) =>
      other is _StyleKey &&
      other.baseStyle == baseStyle &&
      identical(other.theme, theme) &&
      identical(other.flattener, flattener);

  @override
  int get hashCode => Object.hash(
      baseStyle, identityHashCode(theme), identityHashCode(flattener));
}

class _EnvKey {
  _EnvKey(this.env, this.minWidth, this.maxWidth);
  final ParagraphEnv env;
  final double minWidth;
  final double maxWidth;

  @override
  bool operator ==(Object other) =>
      other is _EnvKey &&
      other.env == env &&
      other.minWidth == minWidth &&
      other.maxWidth == maxWidth;

  @override
  int get hashCode => Object.hash(env, minWidth, maxWidth);
}

/// 段落预热器:对一个 post 的顶层段落逐个 flatten + 排版进全局缓存。
class ParagraphWarmup {
  ParagraphWarmup._();

  /// 预热统计(诊断)。
  static int warmedParagraphs = 0;

  /// 对 [nodes] 的顶层 ParagraphNode 从 [startIndex] 起逐段预热,
  /// 超 [budgetMicros] 即停。返回下一个待处理下标;全部完成返回 -1。
  ///
  /// - flatten:acquire 进 FlattenCache 后**立即 release**(refs 归 0,
  ///   条目按 LRU 存活;挂载时 acquire 直接命中)。所有段落都热
  ///   (RichText 路径同样吃 FlattenCache);
  /// - 排版:仅满足直绘判据(纯 TextSpan、无行内代码/mention)的段落
  ///   obtain 进 ParagraphLayoutCache;
  /// - [context] 仅供 flatten 同步读主题色;recognizer 点击走 mount 桥,
  ///   与预热时的 context 无关。
  static int warmParagraphs({
    required List<BlockNode> nodes,
    required WarmupContext ctx,
    required BuildContext context,
    required int totalImagesInPost,
    LinkActionHandler? linkHandler,
    EmojiImageBuilder? emojiImageBuilder,
    MentionTapHandler? mentionTapHandler,
    ImageContentBuilder? imageContentBuilder,
    FootnoteTapHandler? footnoteTapHandler,
    LocalDateBuilder? localDateBuilder,
    MathInlineBuilder? mathInlineBuilder,
    AttachmentDownloadHandler? onDownloadAttachment,
    int startIndex = 0,
    int budgetMicros = 4000,
  }) {
    final sw = Stopwatch()..start();
    for (var i = startIndex; i < nodes.length; i++) {
      if (sw.elapsedMicroseconds > budgetMicros) return i;
      final node = nodes[i];
      if (node is! ParagraphNode) continue;
      final flat = FlattenCache.acquire(
        inlines: node.inlines,
        baseStyle: ctx.baseStyle,
        theme: ctx.theme,
        totalImagesInPost: totalImagesInPost,
        flattener: ctx.flattener,
        create: () => ctx.flattener.flatten(
          node.inlines,
          ctx.baseStyle,
          linkHandler: linkHandler,
          emojiImageBuilder: emojiImageBuilder,
          mentionTapHandler: mentionTapHandler,
          imageContentBuilder: imageContentBuilder,
          footnoteTapHandler: footnoteTapHandler,
          localDateBuilder: localDateBuilder,
          mathInlineBuilder: mathInlineBuilder,
          onDownloadAttachment: onDownloadAttachment,
          totalImagesInPost: totalImagesInPost,
          context: context,
        ),
      );
      // 直绘判据同 InlineSpanText:满足才预排版(emoji 占位岛可进)。
      final projection = flat.projection;
      if ((!flat.hasPlaceholders || flat.allPlaceholdersAreIslands) &&
          !projection.hasInlineCode &&
          !projection.hasSpanMention) {
        ParagraphLayoutCache.obtain(flat, ctx.env, ctx.minWidth, ctx.maxWidth);
      }
      FlattenCache.release(flat); // refs 归 0,条目留 LRU 待挂载命中
      warmedParagraphs++;
    }
    return -1;
  }
}
