/// 渲染一段含 LinkRun 等需要 GestureRecognizer 的行内内容。
///
/// flatten 产物经 [FlattenCache] 全局复用(State 只持引用不持所有权,
/// recognizer 生命周期随缓存条目);没有 link 的纯样式段落同样受益
/// (跨挂载免重 flatten)。

library;

import 'package:material_ui/material_ui.dart';

import '../flatten/flatten_cache.dart';
import '../flatten/inline_flattener.dart';
import '../node/inline_node.dart';
import '../selection/projection.dart';
import 'cached_paragraph_text.dart';
import 'emoji_handler.dart';
import 'footnote_handler.dart';
import 'image_handler.dart';
import 'link_handler.dart';
import 'local_date_handler.dart';
import 'math_handler.dart';
import 'mention_handler.dart';
import 'paragraph_warmup.dart';
import 'selectable_text_box.dart';

class InlineSpanText extends StatefulWidget {
  /// 测试钩子:强制走 RichText 路径(生成双路径对照基线用)。
  /// golden 流程:开着它 + 确定性 emoji builder 重锁基线(基线 =
  /// RichText 形态)→ 关掉跑 golden = 直绘 vs RichText 的像素级对照。
  @visibleForTesting
  static bool debugForceRichText = false;

  const InlineSpanText({
    super.key,
    required this.inlines,
    required this.baseStyle,
    this.documentOrder = 0,
    this.chunkIndex = 0,
    this.flattener = const InlineFlattener(),
    this.linkHandler,
    this.emojiImageBuilder,
    this.mentionTapHandler,
    this.imageContentBuilder,
    this.footnoteTapHandler,
    this.localDateBuilder,
    this.mathInlineBuilder,
    this.onDownloadAttachment,
    this.totalImagesInPost = 0,
    this.textAlign,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  final List<InlineNode> inlines;
  final TextStyle baseStyle;

  /// 块在 chunk 内的文档序(见 SelectableBlockId / document_order.dart)。
  final int documentOrder;

  /// 所属 chunk 的文档序号(整帖渲染时 0)。
  final int chunkIndex;

  final InlineFlattener flattener;
  final LinkActionHandler? linkHandler;
  final EmojiImageBuilder? emojiImageBuilder;
  final MentionTapHandler? mentionTapHandler;
  final ImageContentBuilder? imageContentBuilder;
  final FootnoteTapHandler? footnoteTapHandler;
  final LocalDateBuilder? localDateBuilder;
  final MathInlineBuilder? mathInlineBuilder;
  /// 附件下载回调(主项目注入)。null 时附件 tap 降级到 linkHandler。
  final AttachmentDownloadHandler? onDownloadAttachment;
  final int totalImagesInPost;
  final TextAlign? textAlign;

  /// 最大行数(null=不限)。引用卡标题传 1 做单行省略。
  final int? maxLines;

  /// 文本溢出处理(默认 clip;引用卡标题传 ellipsis)。
  final TextOverflow overflow;

  @override
  State<InlineSpanText> createState() => _InlineSpanTextState();
}

class _InlineSpanTextState extends State<InlineSpanText> {
  /// 当前持有的 flatten 产物(FlattenCache 引用,acquire/release 配对)。
  ///
  /// 缓存 key = (inlines 身份, baseStyle, theme 身份, totalImagesInPost,
  /// flattener 身份)。**handlers 不进 key**(设计见 FlattenCache 类注释):
  /// 内容一变 inlines 身份必变 → miss → 新 handler 生效;内容不变时旧
  /// handler 语义等价,点击 context 经 mount 桥挂载时现取,无悬空。
  ///
  /// 相比旧 State 级缓存的收益:sliver 回收重进直接命中(span identical →
  /// RenderParagraph text setter 短路,免重排版);recognizer 跨挂载存续,
  /// 命中路径上进行中的 tap 手势不被 dispose 打断。
  FlattenResult? _result;

  // ---- acquire key 快照(判断是否需要换引用) ----
  List<InlineNode>? _keyInlines;
  TextStyle? _keyBaseStyle;
  ThemeData? _keyTheme;
  InlineFlattener? _keyFlattener;
  int _keyTotalImages = -1;

  /// 当前选区映射表(供 SelectableTextBox 读取),与 span 同源。
  RenderTextProjection get _projection =>
      _result?.projection ?? RenderTextProjection.empty;

  @override
  void dispose() {
    _releaseResult();
    super.dispose();
  }

  @override
  void reassemble() {
    // hot reload:全局缓存整体失效(在用条目延迟释放),本 State 重新
    // acquire,渲染代码改动立即可见。布局缓存(ui.Paragraph)同步清。
    _releaseResult();
    FlattenCache.evictAll();
    ParagraphLayoutCache.evictAll();
    super.reassemble();
  }

  void _releaseResult() {
    final r = _result;
    if (r == null) return;
    r.mount.detach(context);
    FlattenCache.release(r);
    _result = null;
  }

  bool _cacheValid(ThemeData theme) =>
      _result != null &&
      identical(_keyInlines, widget.inlines) &&
      _keyBaseStyle == widget.baseStyle &&
      identical(_keyTheme, theme) &&
      identical(_keyFlattener, widget.flattener) &&
      _keyTotalImages == widget.totalImagesInPost;

  @override
  Widget build(BuildContext context) {
    // 无条件读 Theme:注册依赖,主题切换时本 widget 被标脏 → key 变 →
    // 换缓存条目(flatten 同步读色共 3 处:link/inline-code/mention)。
    final theme = Theme.of(context);
    if (!_cacheValid(theme)) {
      _releaseResult();
      _result = FlattenCache.acquire(
        inlines: widget.inlines,
        baseStyle: widget.baseStyle,
        theme: theme,
        totalImagesInPost: widget.totalImagesInPost,
        flattener: widget.flattener,
        create: () => widget.flattener.flatten(
          widget.inlines,
          widget.baseStyle,
          linkHandler: widget.linkHandler,
          emojiImageBuilder: widget.emojiImageBuilder,
          mentionTapHandler: widget.mentionTapHandler,
          imageContentBuilder: widget.imageContentBuilder,
          footnoteTapHandler: widget.footnoteTapHandler,
          localDateBuilder: widget.localDateBuilder,
          mathInlineBuilder: widget.mathInlineBuilder,
          onDownloadAttachment: widget.onDownloadAttachment,
          totalImagesInPost: widget.totalImagesInPost,
          context: context,
        ),
      );
      _keyInlines = widget.inlines;
      _keyBaseStyle = widget.baseStyle;
      _keyTheme = theme;
      _keyFlattener = widget.flattener;
      _keyTotalImages = widget.totalImagesInPost;
    }
    final result = _result!;
    // 挂载登记:recognizer 点击闭包经 mount 现取活 context(flatten 契约
    // 已去 context 捕获),每次 build 刷新登记保证拿到的是当前挂载点。
    result.mount.attach(context);

    // ---- 分路:直绘缓存 vs RichText ----
    //
    // 直绘(CachedParagraphText,缓存 ui.Paragraph drawParagraph):
    // sliver 回收重进零排版零测量 —— 笔3 收益主体。判据(全部满足):
    // - 占位全是「岛」(emoji,占位尺寸确定)或无占位;其他 WidgetSpan
    //   原子(图/chip/公式)占位尺寸依赖 widget 布局,画不了;
    // - 无行内代码/TextSpan-mention(灰底 InlineCodeBackgroundPainter
    //   仍直读 RenderParagraph,首期不动它);
    // - 无 maxLines/overflow 定制(引用卡标题单行省略语义走 TextPainter
    //   的 ellipsis,直绘层未实现 —— 这类块量少,留 RichText)。
    // 其余段落(交互原子/富装饰)走原 RichText 路径,行为不变。
    final projection = result.projection;
    final useDirectPaint = !InlineSpanText.debugForceRichText &&
        (!result.hasPlaceholders || result.allPlaceholdersAreIslands) &&
        !projection.hasInlineCode &&
        !projection.hasSpanMention &&
        widget.maxLines == null &&
        widget.overflow == TextOverflow.clip;

    if (useDirectPaint) {
      // 预热探针:登记挂载真实使用的 (baseStyle, theme, flattener),
      // idle 预热用同源 key 构缓存条目(见 paragraph_warmup.dart)。
      ParagraphWarmupProbe.noteStyle(
          widget.baseStyle, theme, widget.flattener);
    }

    // 选区注册 + 高亮统一由 SelectableTextBox 封装(无 SelectionScope 时退化
    // 为裸文本,零成本)。直绘块经 BlockTextGeometry 接入同一套选区。
    return SelectableTextBox(
      projectionGetter: () => _projection,
      documentOrder: widget.documentOrder,
      chunkIndex: widget.chunkIndex,
      debugLabel: 'inlineText',
      child: useDirectPaint
          ? CachedParagraphText(
              result: result,
              textAlign: widget.textAlign,
            )
          : Text.rich(
              result.span,
              textAlign: widget.textAlign,
              maxLines: widget.maxLines,
              overflow: widget.overflow,
            ),
    );
  }
}
