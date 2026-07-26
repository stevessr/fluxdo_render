import 'package:flutter/material.dart';

import '../node/node.dart';
import '../parser/paragraph_parser.dart';
import '../render/code_block_handler.dart';
import '../render/document_order.dart';
import '../render/emoji_handler.dart';
import '../render/footnote_handler.dart';
import '../render/audio_handler.dart';
import '../render/iframe_handler.dart';
import '../render/image_handler.dart';
import '../render/video_handler.dart';
import '../render/lazy_video_handler.dart';
import '../render/link_handler.dart';
import '../render/local_date_handler.dart';
import '../render/math_handler.dart';
import '../render/mention_handler.dart';
import '../render/node_factory.dart';
import '../render/onebox_handler.dart';
import '../render/policy_handler.dart';
import '../render/chat_transcript_handler.dart';
import '../render/poll_handler.dart';
import '../render/quote_avatar_handler.dart';
import '../render/svg_handler.dart';
import '../selection/selection_data.dart';
import '../selection/selection_registry.dart';
import '../selection/selection_scope.dart';
import '../selection/selection_scope_registry.dart';
import 'screenshot_mode.dart';
import 'selection_content_layer.dart';

/// 帖子渲染入口 widget。
///
/// 当前作用域(阶段 1):段落 + 标题 + 列表 + 引用块 + 分割线 + 代码块 +
/// 引用卡 + 行内 em/strong/br/text/link/inline_code/emoji/mention/image。
/// 其他节点(spoiler 等)按 docs/node_priority.md 顺序在后续阶段实现。
/// 未识别块级会 fallback 成段落 + textContent。
class FluxdoRender extends StatefulWidget {
  const FluxdoRender({
    super.key,
    required this.cookedHtml,
    this.parsedNodes,
    this.parser,
    this.factory,
    this.linkHandler,
    this.emojiImageBuilder,
    this.mentionTapHandler,
    this.imageContentBuilder,
    this.codeBlockHighlighter,
    this.codeBlockBuilder,
    this.quoteAvatarBuilder,
    this.oneboxBuilder,
    this.imageGridBuilder,
    this.footnoteTapHandler,
    this.lazyVideoBuilder,
    this.iframeBuilder,
    this.videoBuilder,
    this.audioBuilder,
    this.localDateBuilder,
    this.policyBuilder,
    this.pollBuilder,
    this.chatTranscriptBuilder,
    this.mathBlockBuilder,
    this.mathInlineBuilder,
    this.svgBuilder,
    this.onDownloadAttachment,
    this.baseTextStyle,
    this.compact = false,
    this.screenshotMode = false,
    this.selectionEnabled = true,
    this.onQuoteRequest,
    this.onCopyQuoteRequest,
    this.onCopyToast,
    this.imageIndexOffset = 0,
    this.footnotesHtml,
    this.selectionScopeId,
    this.chunkIndex = 0,
    this.trimTopMargin = false,
    this.trimBottomMargin = false,
    this.stretchBlocks = true,
  });

  /// Discourse cooked HTML 内容。
  final String cookedHtml;

  /// 已解析好的节点。长帖分 chunk 时,调用方可在构建分段数据时一次性 parse,
  /// 再传给每个 FluxdoRender,避免 widget mount 时重复解析同一 chunk。
  ///
  /// 传入时节点内的 indexInPost / footnote content 应已按调用场景处理好;
  /// [cookedHtml] 仍保留用于 widget identity / 兼容旧调用。
  final List<BlockNode>? parsedNodes;

  /// 解析器,默认是 ParagraphParser。
  /// 后续可注入自定义实现做 dogfood / fixture 测试。
  final ParagraphParser? parser;

  /// 节点工厂,默认 NodeFactory()。
  /// 调用方可继承 NodeFactory 做场景化覆盖(用户卡 bio / AI 分享卡 等)。
  /// 注意:传 factory 时,factory 自带的 handlers 优先于本 widget 的
  /// 同名参数(避免双重注入)。
  final NodeFactory? factory;

  /// 链接点击 callback —— 主项目注入。优先级见 [factory] 文档。
  final LinkActionHandler? linkHandler;

  /// Emoji 图片 builder —— 主项目注入。优先级见 [factory] 文档。
  final EmojiImageBuilder? emojiImageBuilder;

  /// Mention chip 点击跳用户卡 callback —— 主项目注入。
  final MentionTapHandler? mentionTapHandler;

  /// 内容图片 builder —— 主项目注入,走主项目的 discourseImageProvider
  /// + gallery + lightbox + 长按菜单 等完整体系。
  final ImageContentBuilder? imageContentBuilder;

  /// 代码块高亮 builder —— 主项目注入,走 HighlighterService(highlight.js)
  /// + Mermaid 等。不传则纯 monospace。
  final CodeBlockHighlighter? codeBlockHighlighter;

  /// 代码块整块 override —— 主项目注入(mermaid 等语言整块换成图表容器)。
  /// 返回 null / 不传时走默认代码块外壳 + [codeBlockHighlighter]。
  final CodeBlockBuilder? codeBlockBuilder;

  /// 引用卡头像 builder —— 主项目注入,走 SmartAvatar(鉴权 + CDN 重写)。
  /// 不传则首字母 chip。
  final QuoteAvatarBuilder? quoteAvatarBuilder;

  /// Onebox 卡片 builder —— 主项目注入,根据 OneboxKind dispatch 到 6 种
  /// 子 builder(github / video / social / tech / user / default)。
  /// 返回 null 时子包用内置通用卡片(标题 + 描述 + 缩略图)。
  final OneboxBuilder? oneboxBuilder;

  /// 图片网格 carousel builder —— 主项目注入,接 legacy buildImageCarousel
  /// (分页圆点 / >10 张计数器 / 正负 1 预加载 / 画廊左右切)。仅
  /// [ImageGridNode] 的 carousel 形态调用;返回 null 时子包 fallback 单列大图。
  final ImageGridBuilder? imageGridBuilder;

  /// 脚注点击 callback —— 主项目注入弹 popover/dialog 显示 contentHtml。
  /// 不传时仅 debugPrint(默认 [defaultFootnoteTapHandler])。
  final FootnoteTapHandler? footnoteTapHandler;

  /// 懒加载视频 builder —— 主项目注入 webview iframe 嵌入。
  /// 返回 null 时子包用内置缩略图卡片(点击 → linkHandler 跳浏览器)。
  final LazyVideoBuilder? lazyVideoBuilder;

  /// 嵌入 iframe builder —— 主项目注入 webview 真实渲染。
  /// 返回 null 时子包用内置占位卡(图标 + 域名 + 打开按钮)。
  final IframeBuilder? iframeBuilder;

  /// 原生上传视频 builder —— 主项目注入 chewie 真播放器（DiscourseVideoPlayer）。
  /// 返回 null 时子包用内置占位卡（封面/图标 + 点击降级 linkHandler）。
  final VideoBuilder? videoBuilder;

  /// 原生上传音频 builder —— 主项目注入 just_audio 音频条。
  /// 返回 null 时子包用内置占位卡（音乐图标 + 文件名 + 点击降级 linkHandler）。
  final AudioBuilder? audioBuilder;

  /// 本地日期 chip builder —— 主项目注入完整虚线下划线 + 时区换算 + popover。
  /// 返回 null 时子包用内置 fallback(服务端预渲染文本 + 时钟图标)。
  final LocalDateBuilder? localDateBuilder;

  /// Discourse policy builder —— 主项目注入完整交互(接受/撤销 + API +
  /// 已接受用户列表)。返回 null 时子包 fallback 渲染 body + 静态 footer 占位。
  final PolicyBuilder? policyBuilder;

  /// 投票块 builder —— 主项目接 legacy buildPoll(选项/票数/投票 + API)。
  /// 返回 null 时子包 fallback 占位卡。
  final PollBuilder? pollBuilder;

  /// 聊天记录 builder —— 主项目接 legacy buildChatTranscript。
  /// 返回 null 时子包 fallback 卡。
  final ChatTranscriptBuilder? chatTranscriptBuilder;

  /// 块级数学公式 builder —— 主项目接入 flutter_math_fork。
  /// 返回 null 时子包 fallback 用 monospace `$latex$` 原文。
  final MathBlockBuilder? mathBlockBuilder;

  /// 行内数学公式 builder —— 主项目接入 flutter_math_fork。
  /// 返回 null 时子包 fallback 用 monospace `$latex$` 原文。
  final MathInlineBuilder? mathInlineBuilder;

  /// 内容型 SVG builder —— 主项目接入 jovial_svg(ScalableImage.fromSvgString)。
  /// 返回 null 时子包 fallback 画占位框。
  final SvgBuilder? svgBuilder;

  /// 附件(a.attachment)下载 callback —— 主项目注入,带 href + 文件名,
  /// 接内置下载器(startDownload)。不传时附件点击降级到 [linkHandler]
  /// (主项目 launchContentLink 内部按 /uploads/ 路径仍能识别附件并下载/外开)。
  final AttachmentDownloadHandler? onDownloadAttachment;

  /// 正文基准文字样式 —— 透传给默认 [NodeFactory]。为 null 时回退
  /// `Theme.textTheme.bodyMedium`。正文注入含 contentFontScale 的样式,
  /// 非正文各传自己的字号。传 [factory] 时以 factory 自带的为准。
  final TextStyle? baseTextStyle;

  /// 紧凑模式 —— 移除段落上下外边距,用于 bio / 回复预览 / 卡片等密集场景
  /// (对齐 legacy DiscourseHtmlContent 的 compact)。透传给默认 [NodeFactory]。
  /// 传 [factory] 时以 factory 自带的 compact 为准。
  final bool compact;

  /// 截图 / 离屏渲染模式 —— 分享成图场景。透传给默认 [NodeFactory](关掉大表格
  /// 行虚拟化,全渲染),并在渲染树上包 [ScreenshotMode],让 mermaid 等懒加载
  /// builder 跳过 VisibilityDetector 立即出图。传 [factory] 时以 factory 自带为准。
  final bool screenshotMode;

  /// 是否启用自研选区(划词选中 → toolbar 复制/引用)。默认 true;
  /// 用户卡 bio 等场景可关掉(不挂手势层 + 高亮,零成本)。
  final bool selectionEnabled;

  /// 引用请求 —— toolbar 点「引用」时调,把选区 plainText 交回主项目。
  final QuoteRequestCallback? onQuoteRequest;

  /// 复制引用请求 —— toolbar 点「复制引用」时调,主项目拼 [quote=...] BBCode
  /// 进剪贴板(需 post 元数据,子包无法自拼)。null = 不显示该按钮。
  final QuoteRequestCallback? onCopyQuoteRequest;

  /// 复制完成 —— 子包复制到剪贴板后通知主项目弹 toast(可选)。
  final CopyToastCallback? onCopyToast;

  /// 图片 indexInPost 起始偏移(长帖分 chunk 时,该 chunk 之前所有 chunk 的
  /// 图片总数),使图片 heroTag / 画廊索引对齐整帖。整帖渲染时为 0。
  final int imageIndexOffset;

  /// 整帖脚注区源 html(分 chunk 时正文 chunk 不含帖尾脚注区,需额外传以保证
  /// 脚注点击取到内容)。整帖渲染时为 null。
  final String? footnotesHtml;

  /// 共享选区作用域 id(如 post.id)。非 null 时,同 id 的多个 FluxdoRender
  /// (长帖各 chunk)共享一个 SelectionController → 选区可跨 chunk。null 时
  /// 每个 FluxdoRender 自建独立选区(整帖渲染 / 用户卡等)。
  final Object? selectionScopeId;

  /// 该 FluxdoRender 在整帖里的 chunk 文档序号(长帖 sliver 分 chunk 时由主项目
  /// 传入,= chunk 文档顺序)。与块内 docOrder 组成全局选区文档序
  /// `SelectableBlockId(chunkIndex, docOrder)` → 跨 chunk 选区按逻辑序稳定排序。
  /// 整帖渲染(不分 chunk)时为 0。
  final int chunkIndex;

  /// 把首/末块的上/下外边距裁成 0。长帖分块时,若本 chunk 是「被切断的单段落」
  /// 的延续(首块接上一片)或前段(末块接下一片),裁掉接缝侧边距 → 拼接处与
  /// 连续渲染一致(无缝)。真正块边界(如 `<p>` 之间)的 chunk 不设,保留间距。
  final bool trimTopMargin;
  final bool trimBottomMargin;

  /// 块级子项是否横向拉伸占满可用宽度(默认 true,正文语义:代码块/引用卡/
  /// 分割线都该占满栏宽)。
  ///
  /// 传 false 时改为按内容收缩(`CrossAxisAlignment.start`),整棵渲染树的宽度
  /// = 最宽子项的自然宽度。聊天气泡这类「按内容自适应宽度」的容器要用它 ——
  /// 外层再包 [IntrinsicWidth] 是行不通的:图片/iframe 等 builder 内部有
  /// LayoutBuilder,不支持 dry layout / 内在尺寸,一问就抛异常导致整条消息
  /// 布局失败(肉眼不可见)。
  final bool stretchBlocks;

  @override
  State<FluxdoRender> createState() => _FluxdoRenderState();
}

class _FluxdoRenderState extends State<FluxdoRender> {
  late List<BlockNode> _nodes;
  late int _totalImagesInPost;

  /// 节点/ListItem → 文档序(parse 后算,选区按它定全局视觉序)。
  Map<Object, int> _docOrders = const {};

  /// 自研选区控制器(selectionEnabled 时非 null)。
  /// scopeId 非 null 时为共享(SelectionScopeRegistry,跨 chunk),否则自建。
  SelectionController? _selectionController;
  bool _ownsController = false;

  /// 块级 widget 树缓存(Column 及其全部 factory.build 产物)。
  ///
  /// 输入不变时跨 rebuild 返回 identical 的 Column → Element.updateChild
  /// 看到相同 widget 直接跳过整棵内容子树的 rebuild(此前每次 build 新建
  /// NodeFactory + 重跑所有 block,任何 ancestor rebuild 都放大成全部
  /// 可见内容重建/重排版)。
  ///
  /// 失效时机:
  /// - _reparse(内容变了)
  /// - didUpdateWidget 检出渲染配置(handlers/样式/trim/chunkIndex)变化
  /// - build 时 Theme / Directionality / MediaQuery.size 变化(NodeFactory
  ///   同步路径读这三个 inherited —— 表格虚拟化限高用 size.height ——
  ///   派生值内嵌在产出的 widget 里)
  Widget? _cachedColumn;
  ThemeData? _cacheTheme;
  TextDirection? _cacheDirectionality;
  Size? _cacheMediaSize;

  @override
  void initState() {
    super.initState();
    _reparse();
    _acquireController();
  }

  /// selectionEnabled 时获取选区控制器:有 scopeId 用共享(跨 chunk),否则自建。
  void _acquireController() {
    if (!widget.selectionEnabled) return;
    final scopeId = widget.selectionScopeId;
    if (scopeId != null) {
      _selectionController = SelectionScopeRegistry.retain(scopeId);
      _ownsController = false;
    } else {
      _selectionController = SelectionController(SelectionRegistry());
      _ownsController = true;
    }
  }

  void _releaseController() {
    final c = _selectionController;
    if (c == null) return;
    if (_ownsController) {
      c.dispose();
    } else if (widget.selectionScopeId != null) {
      SelectionScopeRegistry.release(widget.selectionScopeId!);
    }
    _selectionController = null;
    _ownsController = false;
  }

  @override
  void didUpdateWidget(covariant FluxdoRender oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cookedHtml != widget.cookedHtml ||
        oldWidget.parsedNodes != widget.parsedNodes ||
        oldWidget.parser != widget.parser ||
        oldWidget.imageIndexOffset != widget.imageIndexOffset ||
        oldWidget.footnotesHtml != widget.footnotesHtml) {
      _reparse();
    } else if (_renderConfigChanged(oldWidget)) {
      _cachedColumn = null;
    }
    // selectionEnabled / scopeId 变化 → 重新获取控制器。
    if (oldWidget.selectionEnabled != widget.selectionEnabled ||
        oldWidget.selectionScopeId != widget.selectionScopeId) {
      _releaseController();
      _acquireController();
    }
  }

  /// 除内容外,所有会进入 NodeFactory / factory.build 产物的配置项。
  /// 任一身份变化 → 块缓存失效(主项目 callbacks 按 post 缓存,稳态下全部
  /// identical,不会误失效)。
  bool _renderConfigChanged(FluxdoRender old) =>
      !identical(old.factory, widget.factory) ||
      !identical(old.linkHandler, widget.linkHandler) ||
      !identical(old.emojiImageBuilder, widget.emojiImageBuilder) ||
      !identical(old.mentionTapHandler, widget.mentionTapHandler) ||
      !identical(old.imageContentBuilder, widget.imageContentBuilder) ||
      !identical(old.codeBlockHighlighter, widget.codeBlockHighlighter) ||
      !identical(old.codeBlockBuilder, widget.codeBlockBuilder) ||
      !identical(old.quoteAvatarBuilder, widget.quoteAvatarBuilder) ||
      !identical(old.oneboxBuilder, widget.oneboxBuilder) ||
      !identical(old.imageGridBuilder, widget.imageGridBuilder) ||
      !identical(old.footnoteTapHandler, widget.footnoteTapHandler) ||
      !identical(old.lazyVideoBuilder, widget.lazyVideoBuilder) ||
      !identical(old.iframeBuilder, widget.iframeBuilder) ||
      !identical(old.videoBuilder, widget.videoBuilder) ||
      !identical(old.audioBuilder, widget.audioBuilder) ||
      !identical(old.localDateBuilder, widget.localDateBuilder) ||
      !identical(old.policyBuilder, widget.policyBuilder) ||
      !identical(old.pollBuilder, widget.pollBuilder) ||
      !identical(old.chatTranscriptBuilder, widget.chatTranscriptBuilder) ||
      !identical(old.mathBlockBuilder, widget.mathBlockBuilder) ||
      !identical(old.mathInlineBuilder, widget.mathInlineBuilder) ||
      !identical(old.svgBuilder, widget.svgBuilder) ||
      !identical(old.onDownloadAttachment, widget.onDownloadAttachment) ||
      old.baseTextStyle != widget.baseTextStyle ||
      old.compact != widget.compact ||
      old.screenshotMode != widget.screenshotMode ||
      old.chunkIndex != widget.chunkIndex ||
      old.trimTopMargin != widget.trimTopMargin ||
      old.trimBottomMargin != widget.trimBottomMargin ||
      old.stretchBlocks != widget.stretchBlocks;

  @override
  void reassemble() {
    // hot reload 后强制重建,渲染代码改动立即可见
    _cachedColumn = null;
    super.reassemble();
  }

  @override
  void dispose() {
    _releaseController();
    super.dispose();
  }

  void _reparse() {
    _nodes = widget.parsedNodes ??
        (widget.parser ?? ParagraphParser()).parse(
          widget.cookedHtml,
          imageIndexStart: widget.imageIndexOffset,
          footnotesHtml: widget.footnotesHtml,
        );
    _totalImagesInPost = countImageRuns(_nodes);
    _docOrders = assignDocumentOrder(_nodes);
    _cachedColumn = null;
  }

  /// 截图模式时在树上包 [ScreenshotMode],供 mermaid 等懒加载 builder 感知。
  Widget _wrapScreenshot(Widget child) => widget.screenshotMode
      ? ScreenshotMode(enabled: true, child: child)
      : child;

  @override
  Widget build(BuildContext context) {
    if (_nodes.isEmpty) {
      return const SizedBox.shrink();
    }
    // 无条件读 Theme/Directionality/MediaQuery.size:注册 inherited 依赖,
    // 三者变化时本 widget 被标脏 → 走到这里检出变化 → 缓存失效重建
    // (NodeFactory 同步路径把 theme / 表格限高等派生值直接嵌进 widget,
    // 不能跨主题/屏幕尺寸复用)。
    final theme = Theme.of(context);
    final directionality = Directionality.of(context);
    final mediaSize = MediaQuery.sizeOf(context);
    if (!identical(_cacheTheme, theme) ||
        _cacheDirectionality != directionality ||
        _cacheMediaSize != mediaSize) {
      _cachedColumn = null;
      _cacheTheme = theme;
      _cacheDirectionality = directionality;
      _cacheMediaSize = mediaSize;
    }

    Widget column = _cachedColumn ?? _buildColumn(context);
    _cachedColumn = column;

    final controller = _selectionController;
    if (controller == null) return _wrapScreenshot(column);

    // 选区树:Scope 下传 controller 给各 InlineSpanText(注册 + 高亮),
    // 顶层手势层管长按选区,toolbar 弹复制/引用浮层。
    //
    // 关键:用 SelectionContainer.disabled 把内容从**外层系统 SelectionArea**
    // (主项目 topic_post_list 包了一层)里排除——否则 Text.rich 会自动参与
    // 外层系统选区,系统高亮抢先接管拖拽,自研手势层/toolbar 永远触发不了。
    // 自研选区直接用 RenderParagraph,不依赖 SelectionContainer,disabled 不影响它。
    return _wrapScreenshot(SelectionContainer.disabled(
      child: SelectionScope(
        controller: controller,
        child: SelectionContentLayer(
          controller: controller,
          chunkIndex: widget.chunkIndex,
          onQuoteRequest: widget.onQuoteRequest,
          onCopyQuoteRequest: widget.onCopyQuoteRequest,
          onCopyToast: widget.onCopyToast,
          child: column,
        ),
      ),
    ));
  }

  Widget _buildColumn(BuildContext context) {
    final factory = widget.factory ??
        NodeFactory(
          linkHandler: widget.linkHandler,
          emojiImageBuilder: widget.emojiImageBuilder,
          mentionTapHandler: widget.mentionTapHandler,
          imageContentBuilder: widget.imageContentBuilder,
          codeBlockHighlighter: widget.codeBlockHighlighter,
          codeBlockBuilder: widget.codeBlockBuilder,
          quoteAvatarBuilder: widget.quoteAvatarBuilder,
          oneboxBuilder: widget.oneboxBuilder,
          imageGridBuilder: widget.imageGridBuilder,
          footnoteTapHandler: widget.footnoteTapHandler,
          lazyVideoBuilder: widget.lazyVideoBuilder,
          iframeBuilder: widget.iframeBuilder,
          videoBuilder: widget.videoBuilder,
          audioBuilder: widget.audioBuilder,
          localDateBuilder: widget.localDateBuilder,
          policyBuilder: widget.policyBuilder,
          pollBuilder: widget.pollBuilder,
          chatTranscriptBuilder: widget.chatTranscriptBuilder,
          mathBlockBuilder: widget.mathBlockBuilder,
          mathInlineBuilder: widget.mathInlineBuilder,
          svgBuilder: widget.svgBuilder,
          onDownloadAttachment: widget.onDownloadAttachment,
          baseTextStyle: widget.baseTextStyle,
          compact: widget.compact,
          screenshotMode: widget.screenshotMode,
          totalImagesInPost: _totalImagesInPost,
          chunkIndex: widget.chunkIndex,
          docOrders: _docOrders,
        );
    return Column(
      crossAxisAlignment: widget.stretchBlocks
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < _nodes.length; i++)
          factory.build(
            context,
            _nodes[i],
            trimTop: widget.trimTopMargin && i == 0,
            trimBottom: widget.trimBottomMargin && i == _nodes.length - 1,
          ),
      ],
    );
  }
}
