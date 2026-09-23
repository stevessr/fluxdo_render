/// 编辑器组装件 —— M1 顶层 widget。
///
/// 职责:
/// - 持有编辑器**自己的** SelectionController/Registry(不走只读全局
///   coordinator 的手势层;高亮/命中/caret 几何复用同一套基建);
/// - 坐标桥接:EditorState 的 (blockId, 编辑文本偏移) ↔ 选区系统的
///   (SelectableBlockId(docOrder), 渲染偏移),经逻辑块表 projection 换算;
/// - 手势:tap 定位光标、拖动扩选;
/// - Focus + IME client 生命周期,帧后回喂光标几何;
/// - 光标 overlay(EditorCaret)。
library;

import 'dart:ui' as ui show BoxHeightStyle;
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart'
    show
        LongPressGestureRecognizer,
        TapDragDownDetails,
        TapDragUpDetails,
        TapDragStartDetails,
        TapDragUpdateDetails,
        TapDragEndDetails,
        DragStartBehavior,
        PointerDeviceKind,
        PointerDownEvent,
        TapGestureRecognizer,
        kDoubleTapTimeout;
import 'package:flutter/material.dart';
import '../../render/selectable_object_block.dart';
import 'package:flutter/rendering.dart'
    show BoxHitTestResult, RenderMetaData, RenderParagraph, ScrollDirection;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../../node/node.dart'
    show
        CodeBlockNode,
        ImageGridNode,
        ImageRun,
        InlineNode,
        LocalDateRun,
        LinkRun,
        TableNode;
import '../../render/block_text_styles.dart';
import '../../render/node_factory.dart';
import '../../selection/hit_tester.dart';
import '../../selection/block_text_geometry.dart';
import '../../selection/text_selection_rules.dart';
import '../../selection/selection_exporter.dart';
import '../../selection/selection_geometry.dart';
import '../../selection/selection_handles.dart';
import '../../selection/selection_highlight_painter.dart'
    show mergeSelectionBoxesByLine;
import '../../selection/selection_magnifier.dart';
import '../../selection/selection_registry.dart';
import '../../selection/selection_scope.dart';
import '../input/editor_ime_client.dart';
import '../input/editor_key_handler.dart';
import '../input/three_finger_gestures.dart';
import '../model/editor_image_commands.dart';
import '../model/editor_state.dart';
import '../model/editable_text_content.dart';
import '../model/editor_object.dart';
import 'editor_object_frame.dart';
import 'editable_paragraph.dart';
import 'editor_caret.dart';
import 'editor_caret_reveal.dart';
import 'editor_code_block.dart';
import 'editor_collapsed_handle.dart';
import 'editor_container_shell.dart';
import 'editor_context_bar.dart';
import 'editor_image_grid.dart';
import 'editor_island.dart';
import 'editor_table_grid.dart';

/// 图片原子选中态(官方 ProseMirror NodeSelection 对应物)。
///
/// [globalRect] 帧后计算(_afterFrame),跟随滚动/重排更新 —— 宿主浮层
/// (工具条/alt 输入条)锚定用。==/hashCode 四字段全参与:rect 变化也
/// 要通知(浮层跟随),宿主按值比较跳过冗余重建。
@immutable
class ImageAtomSelection {
  const ImageAtomSelection({
    required this.blockId,
    required this.offset,
    required this.image,
    required this.globalRect,
  });

  /// 所在文本块 id(动作回调 replaceAtomAt/addImageAtomToGrid 直接用)。
  final String blockId;

  /// 原子在块内的内容偏移。
  final int offset;

  /// 图片原子(宿主算 disabled 态与 copyWith 基底)。
  final ImageRun image;

  /// 图片渲染矩形(全局坐标)。
  final Rect globalRect;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ImageAtomSelection &&
          blockId == other.blockId &&
          offset == other.offset &&
          image == other.image &&
          globalRect == other.globalRect;

  @override
  int get hashCode => Object.hash(blockId, offset, image, globalRect);
}

/// 浮动幽灵光标定位用(widget test;iOS 长按空格 trackpad 模式)。
const Key kFloatingCursorGhostKey = ValueKey('editor-floating-cursor-ghost');

/// 岛整选上下文(宿主 onebox 工具条等锚定用;帧后回报,滚动跟随)。
@immutable
class IslandSelection {
  const IslandSelection({required this.island, required this.globalRect});

  final IslandBlock island;
  final Rect globalRect;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IslandSelection &&
          island == other.island &&
          globalRect == other.globalRect;

  @override
  int get hashCode => Object.hash(island, globalRect);
}

/// collapsed 光标落在 mark 链接内或整选链接原子的上下文(宿主链接工具条锚定/编辑用)。
///
/// [rangeGlobal] = 链接文本区间的全局包围矩形(帧后计算,跟随滚动
/// 刷新);[start]/[end] = 块内编辑偏移(原位替换用)。
@immutable
class LinkCaretInfo {
  const LinkCaretInfo({
    required this.blockId,
    required this.start,
    required this.end,
    required this.href,
    required this.text,
    required this.rangeGlobal,
  });

  final String blockId;
  final int start;
  final int end;
  final String? href;

  /// 链接区间纯文本(编辑对话框预填;含原子哨兵时由宿主自行取舍)。
  final String text;

  final Rect rangeGlobal;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LinkCaretInfo &&
          blockId == other.blockId &&
          start == other.start &&
          end == other.end &&
          href == other.href &&
          text == other.text &&
          rangeGlobal == other.rangeGlobal;

  @override
  int get hashCode => Object.hash(blockId, start, end, href, text, rangeGlobal);
}

/// 编程式虚拟指针:宿主"手势光标"的二维形态 —— 复用 iOS 浮动光标链
/// (幽灵光标跟手 + 实光标命中吸附 + 贴边自动滚)。宿主滑钮 pan 手势
/// 驱动:按下 [start] → 拖动 [moveBy] 累计位移 → 松手 [end]。
///
/// 经 [FluxdoEditor.virtualPointer] 绑定;编辑器未挂载/无光标时
/// [start] 返回 false(宿主应忽略本次拖动)。
class FluxdoEditorVirtualPointer {
  _FluxdoEditorState? _state;
  Offset _acc = Offset.zero;
  bool _active = false;

  bool get isActive => _active;

  /// 从当前光标处起漂。[extend] = 扩选(选区 base 固定,指针驱动 extent)。
  bool start({bool extend = false}) {
    final s = _state;
    if (s == null || !s.mounted) return false;
    _acc = Offset.zero;
    _active = s._floatingStart(extend: extend);
    return _active;
  }

  void moveBy(Offset delta) {
    if (!_active) return;
    _acc += delta;
    _state?._floatingUpdate(_acc);
  }

  void end() {
    if (!_active) return;
    _active = false;
    _state?._floatingEnd();
  }
}

/// 内容操作句柄:把「作用于文字本身」的动作(剪贴板/全选/撤销重做)
/// 暴露给宿主。
///
/// 为什么需要它:这些动作的实现散在 [_FluxdoEditorState] 私有方法里
/// (剪贴板要走 markdown 序列化 + cook 导入链,不是简单取文本),宿主的
/// 工具栏/手势层够不到。照 [FluxdoEditorVirtualPointer] 同款:宿主持有
/// 句柄对象,编辑器 initState 时反向绑定 state。
///
/// 撤销/重做直接转发 [EditorState],放在这里只是为了让宿主有**单一**
/// 内容操作入口 —— 工具栏的「内容操作」按钮与三指手势共用同一套动作,
/// 不必一半调 state、一半调编辑器。
///
/// 编辑器未挂载时所有方法静默无操作([canUndo] 等返回 false)。
class FluxdoEditorContentActions {
  _FluxdoEditorState? _state;

  /// 编辑器是否已挂载可用(宿主据此禁用整个内容操作入口)。
  bool get isAttached => _state?.mounted ?? false;

  EditorState? get _editorState => _state?.widget.state;

  bool get canUndo => _editorState?.canUndo ?? false;
  bool get canRedo => _editorState?.canRedo ?? false;

  /// 当前是否有非折叠选区(决定复制/剪切是否可用)。
  bool get hasSelection {
    final sel = _editorState?.selection;
    return sel != null && !sel.isCollapsed;
  }

  void undo() {
    final s = _editorState;
    if (s == null) return;
    // 先封口:未 seal 的输入组作为完整一步回退(与工具栏按钮同语义)
    s.sealHistory();
    s.undo();
    _state?._ime.syncFromState(show: false);
  }

  void redo() {
    final s = _editorState;
    if (s == null) return;
    s.redo();
    _state?._ime.syncFromState(show: false);
  }

  void selectAll() {
    _editorState?.selectAll();
  }

  /// 工具栏方向按钮复用内核的字素移动与真实行布局。
  void moveHorizontal(int direction, {required bool extend}) {
    _editorState?.moveCaretHorizontal(direction, extend: extend);
    _state?._ime.syncFromState(show: false);
  }

  void moveVertical(int direction, {required bool extend}) {
    _state?._moveCaretVertical(direction, extend: extend);
    _state?._ime.syncFromState(show: false);
  }

  void copy() => _state?._clipboardCopy();

  void cut() => _state?._clipboardCut();

  void paste() => _state?._clipboardPaste();

  void selectObject(EditorObjectTarget target, {bool showMenu = false}) {
    _state?._selectObject(target);
    if (showMenu) _state?._requestObjectMenu();
  }

  /// 宿主滚动层暂时屏蔽正文时，仍可按全局鼠标位置打开对象菜单。
  void showObjectMenuAt(Offset position) => _state?._onSecondaryTapUp(
    TapUpDetails(globalPosition: position, kind: PointerDeviceKind.mouse),
  );

  /// Visible painted content in global coordinates, measured only on demand.
  /// Line and image bounds leave usable blank space beside short content.
  List<Rect> visibleContentRects() =>
      _state?._visiblePaintedRects() ?? const [];

  Rect? visibleViewportRect() => _state?._visibleViewportRect();

  EditorObjectSelection? get objectSelection =>
      _state?._computeObjectSelection();

  void continueAfterDocument() => _state?._continueAfterDocument();

  /// The outer block, including the paragraph/grid that contains an image.
  Rect? objectBounds(EditorObjectTarget target) {
    final state = _state;
    if (state == null) return null;
    final object = resolveEditorObject(state.widget.state, target);
    if (object == null) return null;
    final key = target is EditorContainerTarget
        ? state._containerKeys[(target.groupId, object.blocks.first.id)]
        : state._blockKeys[target.blockId];
    return state._objectRect(key);
  }

  /// Block/container hit testing for desktop hover affordances. Read-only:
  /// never modifies the text selection, focus, or document revision.
  EditorObjectSelection? blockAt(Offset position, {double leadingSlop = 0}) =>
      _state?._blockAt(position, leadingSlop: leadingSlop);

  void clearObjectSelection() {
    _state?._explicitObjectTarget = null;
    _state?._setGridImageSelection(null);
    _editorState?.updateSelection(null);
    _state?._ime.syncFromState(show: false);
  }
}

class FluxdoEditor extends StatefulWidget {
  const FluxdoEditor({
    super.key,
    required this.state,
    this.baseTextStyle,
    this.autofocus = false,
    this.focusNode,
    this.nodeFactory,
    this.markdownImporter,
    this.richPasteImporter,
    this.semanticMarkdownInserter,
    this.semanticRichPasteInserter,
    this.onCalloutTypeTrigger,
    this.onIslandEditRequest,
    this.onContainerTitleEdit,
    this.onTableEdited,
    this.onCodeBlockEdited,
    this.onAtomTap,
    this.onImageAtomSelectionChanged,
    this.onImageAtomOpenRequest,
    this.onGridImageSelectionChanged,
    this.onGridImageOpenRequest,
    this.onAddGridImages,
    this.addingImageGrids = const {},
    this.gridPendingUploadsBuilder,
    this.transientBlockBuilder,
    this.gridControlSurfaceBuilder,
    this.onCaretRectChanged,
    this.onEditingActivity,
    this.caretViewportInsets = EdgeInsets.zero,
    this.onLinkCaret,
    this.onIslandSelected,
    this.keyEventInterceptor,
    this.virtualPointer,
    this.contentActions,
    this.objectToolbarManaged = false,
    this.emptyParagraphHint,
    this.emptyParagraphHintKey,
    this.showTrailingParagraph = false,
    this.onObjectContextMenuRequest,
    this.onObjectSelectionChanged,
    this.onObjectMenuRequested,
  });

  final EditorState state;
  final Widget? Function(BuildContext, EditorBlock)? transientBlockBuilder;
  final ValueChanged<String>? onAddGridImages;
  final Set<String> addingImageGrids;
  final List<Widget> Function(BuildContext, String)? gridPendingUploadsBuilder;
  final Widget Function(BuildContext, Widget)? gridControlSurfaceBuilder;

  /// Host overlays measured inward from the scroll viewport (including any
  /// keyboard space they occupy). Combined with the platform keyboard bounds,
  /// so one coordinator handles caret visibility without double subtraction.
  final EdgeInsets caretViewportInsets;

  /// Confirmed text interaction or platform text input, including undocked IME.
  final VoidCallback? onEditingActivity;

  /// 宿主提供统一对象工具栏时，隐藏块内重复的操作浮层。
  final bool objectToolbarManaged;
  final String? emptyParagraphHint;
  final Key? emptyParagraphHintKey;
  final bool showTrailingParagraph;
  final VoidCallback? onObjectContextMenuRequest;
  final ValueChanged<EditorObjectSelection?>? onObjectSelectionChanged;
  final ValueChanged<EditorObjectMenuRequest>? onObjectMenuRequested;

  final TextStyle? baseTextStyle;

  final bool autofocus;

  /// 外部焦点节点(宿主监听焦点态做键盘/面板联动;null 内部自建)。
  final FocusNode? focusNode;

  /// 孤岛块的渲染工厂(主项目注入带 emoji/image builder 的实例;
  /// null 用子包默认 fallback —— demo/测试可用)。
  final NodeFactory? nodeFactory;

  /// 粘贴的 markdown → 编辑块导入器(主项目注入 cook 链路:
  /// markdown → cook → parse → blockNodesToDoc)。null / 返回 null 时
  /// 粘贴降级为纯文本(pastePlainText)。
  ///
  /// 剪贴板策略:复制/剪切写 markdown 文本(跨 app 通用、粘回自身经
  /// cook 还原富内容 —— Discourse 官方富文本 composer 同款语义)。
  final Future<List<EditorBlock>?> Function(String markdown)? markdownImporter;

  /// 富粘贴导入器:粘贴时**先**问它 —— 宿主自行读系统剪贴板的富格式
  /// (text/html 等,子包不背平台剪贴板依赖)并转成编辑块。返回 null /
  /// 空 = 剪贴板无富内容或转换失败,回落 [markdownImporter] 纯文本路径;
  /// 抛异常同回落。null = 不启用富粘贴。
  final Future<List<EditorBlock>?> Function()? richPasteImporter;

  /// 语义宿主直接导入并插入片段；true 表示已消费，不再调用旧块导入器。
  /// selection 在异步操作前捕获；宿主须在自己的 await 前建立书签，
  /// 并在目标失效时取消插入。false 或异常仅在文档版本与选区均未变化时
  /// 回落旧导入器/原始纯文本；读取纯文本期间目标变化则不调用此入口。
  final Future<bool> Function(String markdown, EditorSelection? selection)?
  semanticMarkdownInserter;

  /// 富粘贴原数据入口：宿主自行读取系统 HTML 等原格式并插入语义片段。
  /// 在读取剪贴板前调用，便于宿主立即建立书签；true 阻断所有后续粘贴，
  /// false 或异常仅在文档版本与选区均未变化时继续旧富格式及
  /// Markdown/纯文本路径。语义宿主可将旧导入器设为 null。
  final Future<bool> Function(EditorSelection? selection)?
  semanticRichPasteInserter;

  /// input rule `[!type] ` 命中(callout 手打)时的完整内容征集回调:
  /// 宿主弹标题/折叠态对话框(同"+"菜单插入共用一个对话框),返回完整
  /// Obsidian callout markdown(`> [!type]±  标题\n> 正文`);取消返回
  /// null(本次触发放弃,已清空的标记文本不恢复,用户可继续打字)。
  ///
  /// 为什么不直接插一个空壳让用户接着打字:callout 落地后是**岛**(只读
  /// 块,不是可续行编辑的容器)——插入空壳后按 Enter 换行,新行文本会
  /// 被当成岛后面的新段落,而不是并入岛的正文,视觉上"标题"和"正文"
  /// 拆成两个不相干的块(真机复现)。"+" 菜单插入从不出这问题,因为它
  /// 靠对话框把标题/正文一次性收全再插入,插入的就已经是完整体——手打
  /// 触发复用同一个对话框,从根上避开"岛不可续写"这个架构限制,而不是
  /// 打补丁擦屁股。
  final Future<String?> Function(String type)? onCalloutTypeTrigger;

  /// 双击岛 → 请求编辑(宿主弹源码对话框,改完调 state.replaceIsland)。
  /// null = 岛只读不可编辑。
  final void Function(IslandBlock island)? onIslandEditRequest;

  /// 点容器壳标题(details summary / callout 标题)→ 请求改标题
  /// (宿主弹输入框,改完调 state.updateContainerFrame)。null = 不可改。
  final void Function(ContainerFrame frame)? onContainerTitleEdit;

  /// 表格 cell 编辑确认 → 新 markdown 表格文本(宿主 cook 后
  /// state.replaceIsland)。null = 表格走通用只读岛。
  final void Function(IslandBlock island, String markdown)? onTableEdited;

  /// 代码块岛内编辑提交 → 新 code/language(宿主直接
  /// state.updateIslandNode(CodeBlockNode(...)),结构化形变不经 cook)。
  /// null = 代码块走通用只读岛(双击源码编辑)。
  final void Function(IslandBlock island, String code, String? language)?
  onCodeBlockEdited;

  /// 单击可编辑原子(date chip)→ 请求编辑(宿主弹属性对话框,确认后
  /// state.replaceAtomAt)。null = 原子只读。
  final void Function(String blockId, int offset, InlineNode atom)? onAtomTap;

  /// 图片原子选中态变化(帧后回报,含全局矩形,跟随滚动/重排;null =
  /// 取消选中)。宿主浮层(缩放/删除/加网格工具条 + alt 输入条)锚定用。
  final ValueChanged<ImageAtomSelection?>? onImageAtomSelectionChanged;

  /// 已选中的图片原子再次单击 → 请求打开(宿主开图片查看器,官方
  /// 「选中态再点开灯箱」同语义)。
  final ValueChanged<ImageAtomSelection>? onImageAtomOpenRequest;

  /// grid 岛内图片子选中变化(官方 grid 内图 NodeSelection 的等价物;
  /// null = 取消)。宿主浮层出官方 isInGrid 工具条([删除|移出网格] +
  /// alt 条,无缩放按钮)。
  final ValueChanged<GridImageSelection?>? onGridImageSelectionChanged;

  /// 已子选中的 grid 内图再点 → 请求打开查看器。
  final ValueChanged<GridImageSelection>? onGridImageOpenRequest;

  /// 光标全局矩形变化(帧后回报;null = 光标不可见)。宿主用于锚定
  /// 斜杠菜单/mention 面板到光标位置。
  final ValueChanged<Rect?>? onCaretRectChanged;

  /// collapsed 光标进入/离开链接(帧后回报;null = 不在链接内/失焦/
  /// range 选区)。宿主链接工具条(编辑/复制/取消链接/预览/访问)
  /// 锚定用 —— 官方 link-toolbar 的 getMarkRange 检测同语义。
  final ValueChanged<LinkCaretInfo?>? onLinkCaret;

  /// 岛整选态变化(帧后回报,含全局矩形跟随滚动;null = 取消)。宿主
  /// 按 island.node 类型出对应工具条(官方 onebox-toolbar 的
  /// NodeSelection 检测同语义)。
  final ValueChanged<IslandSelection?>? onIslandSelected;

  /// 虚拟指针控制器(宿主手势光标驱动浮动光标链);null 不启用。
  final FluxdoEditorVirtualPointer? virtualPointer;

  /// 内容操作句柄(剪贴板/全选/撤销重做),供宿主工具栏与手势层调用。
  final FluxdoEditorContentActions? contentActions;

  /// 按键拦截器:编辑器处理按键**之前**先问它(返回 true = 已消费,
  /// 编辑器不再处理)。宿主的浮层(斜杠菜单/mention)激活时借此接管
  /// 上下键/回车/Esc —— 否则方向键被编辑器拿去移光标,菜单无法导航。
  final bool Function(KeyEvent event)? keyEventInterceptor;

  @override
  State<FluxdoEditor> createState() => _FluxdoEditorState();
}

class _FluxdoEditorState extends State<FluxdoEditor>
    with SingleTickerProviderStateMixin {
  late final SelectionController _controller;
  late final SelectionHitTester _hitTester;
  late final EditorImeClient _ime;
  late final NodeFactory _islandFactory;
  late final FocusNode _focusNode =
      widget.focusNode ?? FocusNode(debugLabel: 'FluxdoEditor');
  bool get _ownsFocusNode => widget.focusNode == null;
  final GlobalKey _rootKey = GlobalKey();

  /// 岛容器 key(整选矩形上抛用;按块 id 稳定)。
  final Map<String, GlobalKey> _islandKeys = {};
  final Map<String, GlobalKey> _blockKeys = {};
  final Map<(String, String), GlobalKey> _containerKeys = {};
  final Map<String, GlobalKey<EditorImageGridState>> _gridKeys = {};
  EditorObjectTarget? _explicitObjectTarget;
  EditorObjectSelection? _lastObjectSelection;
  bool _objectGeometryScheduled = false;

  void _scheduleObjectGeometry() {
    if (_lastObjectSelection == null || _objectGeometryScheduled) return;
    _objectGeometryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _objectGeometryScheduled = false;
      if (mounted) _afterFrame();
    });
  }

  /// 编辑器局部坐标系的光标矩形 + 配对修订号(帧后由 hit_tester 计算)。
  ///
  /// 用 ValueNotifier 而非 setState:光标位置每键都变,走整树 setState
  /// 会造成"每键两帧全量 build"(JANK 日志的第二帧 vsyncOverhead 20ms+
  /// 就是它);Notifier 只重建 caret overlay 一个叶子。修订号语义见
  /// EditorCaret.moveGeneration。
  final ValueNotifier<(Rect?, int)> _caretInfo = ValueNotifier((null, 0));

  @override
  void initState() {
    super.initState();
    _controller = SelectionController(SelectionRegistry());
    _hitTester = SelectionHitTester(_controller.registry);
    _ime = EditorImeClient(state: widget.state);
    // input rule `--- ` → 分隔线岛(经 cook 链路;importer 未注入时用
    // markdown 纯文本兜底 —— 至少不静默)
    _ime.onHorizontalRuleRequest = _insertHorizontalRule;
    // input rule `[!type] ` → callout 岛(同 hr,经 cook 链路)
    _ime.onCalloutRequest = _insertCalloutFromTyping;
    // iOS 浮动光标(长按空格 trackpad 模式)
    _ime.onFloatingCursor = _onFloatingCursor;
    // macOS selector 快捷键(自管 IME 激活时 Cmd+A/C/V/X 走 selector)
    _ime.onSelector = _onImeSelector;
    widget.virtualPointer?._state = this;
    widget.contentActions?._state = this;
    _islandFactory = widget.nodeFactory ?? NodeFactory();
    widget.state.addListener(_onStateChanged);
    _focusNode.addListener(_onFocusChanged);
    // 手柄拖动的反向回写(controller → state;仅 _handleDragging 期间)
    _controller.addListener(_onSelectionControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFrame());
  }

  @override
  void didUpdateWidget(covariant FluxdoEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.caretViewportInsets != widget.caretViewportInsets) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _afterFrame();
      });
    }
    if (oldWidget.contentActions != widget.contentActions) {
      if (oldWidget.contentActions?._state == this) {
        oldWidget.contentActions!._state = null;
      }
      widget.contentActions?._state = this;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ime.updateViewId(View.of(context).viewId);
    _bindScrollPosition();
    // Keyboard/window changes only reveal a caret we were already following.
    // Recompute geometry after layout; the tracker preserves reading elsewhere.
    MediaQuery.maybeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _afterFrame();
    });
  }

  @override
  void dispose() {
    if (widget.virtualPointer?._state == this) {
      widget.virtualPointer!._active = false;
      widget.virtualPointer!._state = null;
    }
    if (widget.contentActions?._state == this) {
      widget.contentActions!._state = null;
    }
    _handles?.hide();
    _collapsedHandle?.hide();
    _contextBar?.hide();
    _magnifier?.hide();
    _removeFloatingGhost();
    _autoScrollTicker?.dispose();
    _scrollPosition?.removeListener(_onScrolled);
    _caretInfo.dispose();
    widget.state.removeListener(_onStateChanged);
    _controller.removeListener(_onSelectionControllerChanged);
    _ime.detach();
    _focusNode.removeListener(_onFocusChanged);
    // Focus(onKeyEvent:) 会把处理器写进 FocusNode 对象本身;外部共享
    // 节点在本编辑器亡后仍存活 —— 不清的话宿主把同一节点交给 TextField
    // (双模切换),每个按键先过本编辑器的亡灵处理器:Cmd+A 命中
    // keyA 分支对已 dispose 的 state 空操作后 handled 吞键 = 切到源码
    // 后全选/快捷键全废。
    // == 而非 identical:方法 tearoff 每次取都是新闭包对象(identical
    // 恒 false),同对象同方法的 tearoff 相等性走 ==
    if (_focusNode.onKeyEvent == _editorOnKeyEvent) {
      _focusNode.onKeyEvent = null;
    }
    if (_ownsFocusNode) _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------
  // 状态联动
  // -----------------------------------------------------------------

  /// 编辑帧耗时插桩(debug;>8ms 打印,定位打字卡顿)。
  Stopwatch? _editFrameWatch;

  void _onStateChanged() {
    if (!mounted) return;
    final explicit = _explicitObjectTarget;
    if (explicit != null) {
      final object = resolveEditorObject(widget.state, explicit);
      if (object == null || object.selection != widget.state.selection) {
        _explicitObjectTarget = null;
      }
    }
    final gridSelection = _gridImageSel;
    final selectedImage = _lastGridImageSel?.image;
    if (gridSelection != null && selectedImage != null) {
      final index = widget.state.indexOfBlock(gridSelection.$1);
      final block = index < 0 ? null : widget.state.blocks[index];
      if (block is IslandBlock && block.node is ImageGridNode) {
        final images = (block.node as ImageGridNode).images;
        final moved = images.indexWhere(
          (image) => identical(image, selectedImage),
        );
        if (moved >= 0) {
          _gridImageSel = (gridSelection.$1, moved);
        } else if (gridSelection.$2 >= images.length ||
            images[gridSelection.$2].src != selectedImage.src) {
          _setGridImageSelection(null);
        }
      }
    }
    if (kDebugMode) _editFrameWatch = Stopwatch()..start();
    // 打字/退格(IME 平台增量应用中)→ 收触摸选区 UI(系统同款:输入
    // 即隐手柄;实际显隐由帧后 _syncHandlesAndContextBar 收敛)。
    if (_ime.isApplyingPlatformUpdate) {
      widget.onEditingActivity?.call();
      // A replacement can remove selected paragraphs in this frame. Retire
      // handles before their RenderParagraphs disappear, rather than waiting
      // for the post-frame selection mirror.
      _dismissTouchSelection();
      _magnifier?.hide();
      _controller.selection = null;
    }
    // 外部变更(undo/redo 按钮、程序化改文档)→ IME 的 diff 基准已过期,
    // 必须重喂;IME 自身回调引发的通知、以及拖选/长按扩选/手柄拖动进行
    // 中(高频选区变化,end 时统一喂)除外。
    // hasPrimaryFocus(非 hasFocus):焦点在子输入框(表格 cell)时
    // 编辑器 IME 必须闭嘴 —— 重喂会跟 TextField 抢输入连接。
    if (!_ime.isApplyingPlatformUpdate &&
        _dragBase == null &&
        !_longPressing &&
        !_handleDragging &&
        !_floatingCursor &&
        _focusNode.hasPrimaryFocus) {
      _ime.syncFromState(show: false);
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFrame());
  }

  /// 上一次观察到的 primary 焦点态(区分三态迁移用)。
  bool _hadPrimaryFocus = false;
  bool _hasHadPrimaryFocus = false;

  void _onFocusChanged() {
    final primary = _focusNode.hasPrimaryFocus;
    if (primary) {
      // 仅首次聚焦初始化光标。选中网格图片/关闭对象菜单会主动清空
      // 文字选区，路由恢复焦点不能把这种空选区重新解释为「跳到文末」。
      if (!_hasHadPrimaryFocus &&
          widget.state.selection == null &&
          _gridImageSel == null &&
          _explicitObjectTarget == null) {
        final last = widget.state.blocks.last;
        widget.state.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: last.id, offset: last.selectionLength),
          ),
        );
      }
      _hasHadPrimaryFocus = true;
      _ime.syncFromState();
    } else if (_hadPrimaryFocus) {
      // 焦点离开编辑器正文(→ 子输入框如表格 cell,或 → 编辑器外):
      // 关编辑器 IME + 封历史口;光标随 hasPrimaryFocus 消失(见
      // _computeLocalCaretRect),否则与 cell TextField 双光标。
      _ime.detach();
      widget.state.sealHistory();
    }
    _hadPrimaryFocus = primary;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFrame());
  }

  /// 帧后:镜像选区给高亮层 + 重算光标矩形 + 回喂 IME 几何。
  void _afterFrame() {
    if (!mounted) return;
    final w = _editFrameWatch;
    if (w != null) {
      _editFrameWatch = null;
      w.stop();
      if (w.elapsedMilliseconds > 8) {
        debugPrint(
          '[EditorPerf] edit frame ${w.elapsedMilliseconds}ms '
          '(blocks=${widget.state.blocks.length})',
        );
      }
    }
    // 失焦时高亮层也清掉(选区数据保留在 EditorState,聚焦回来即恢复);
    // 焦点在 cell 输入框时同理(hasPrimaryFocus)。
    final imageSelection = _computeImageAtomSelection();
    _controller.outlineSelection = imageSelection != null;
    _controller.selection =
        (_focusNode.hasPrimaryFocus || imageSelection != null) &&
            _explicitObjectTarget == null
        ? _toDocumentSelection(widget.state.selection)
        : null;

    final newCaret = _computeLocalCaretRect();
    if (newCaret != _caretInfo.value.$1) {
      _caretInfo.value = (newCaret, widget.state.docRevision);
    }

    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (newCaret != null && rootBox is RenderBox && rootBox.hasSize) {
      _ime.updateEditableGeometry(
        size: rootBox.size,
        transform: rootBox.getTransformTo(null),
        caretRect: newCaret,
      );
      // 光标全局矩形上抛(斜杠菜单/mention 面板锚定光标,而非编辑器角)
      final caretGlobal =
          rootBox.localToGlobal(newCaret.topLeft) & newCaret.size;
      widget.onCaretRectChanged?.call(caretGlobal);
      _ensureCaretVisible(caretGlobal);
      _notifyLinkCaret();
    } else if (newCaret == null) {
      widget.onCaretRectChanged?.call(null);
      _notifyLinkCaret();
    }

    // 图片原子选中态上抛(变化才通知;rect 变化也算 —— 浮层跟随)
    final imgSel = imageSelection;
    if (imgSel != _lastImageAtomSel) {
      _lastImageAtomSel = imgSel;
      widget.onImageAtomSelectionChanged?.call(imgSel);
    }

    // 岛整选态上抛(onebox 工具条等;变化才通知,rect 变化跟随滚动)
    if (widget.onIslandSelected != null) {
      final islSel = _computeIslandSelection();
      if (islSel != _lastIslandSel) {
        _lastIslandSel = islSel;
        widget.onIslandSelected!(islSel);
      }
    }

    // grid 子选中失效检查:岛没了/图删了/主选区**后续**移动(基线对比)
    // → 清。点瓦片在自管区内不动主选区,基线恒等不误清。
    final gsel = _gridImageSel;
    if (gsel != null) {
      final blockIdx = widget.state.indexOfBlock(gsel.$1);
      final stillIsland =
          blockIdx >= 0 &&
          widget.state.blocks[blockIdx] is IslandBlock &&
          (widget.state.blocks[blockIdx] as IslandBlock).node is ImageGridNode;
      final imagesLen = stillIsland
          ? ((widget.state.blocks[blockIdx] as IslandBlock).node
                    as ImageGridNode)
                .images
                .length
          : 0;
      final selectionMoved = widget.state.selection != _gridSelBaseline;
      if (!stillIsland || gsel.$2 >= imagesLen || selectionMoved) {
        _setGridImageSelection(null);
      }
    }

    final currentGrid = _gridImageSel;
    if (currentGrid != null) {
      final snapshot = _gridKeys[currentGrid.$1]?.currentState?.selectionFor(
        currentGrid.$2,
      );
      if (snapshot != null && snapshot != _lastGridImageSel) {
        _lastGridImageSel = snapshot;
        widget.onGridImageSelectionChanged?.call(snapshot);
      }
    }

    final objectSelection = _computeObjectSelection();
    if (objectSelection != _lastObjectSelection) {
      _lastObjectSelection = objectSelection;
      widget.onObjectSelectionChanged?.call(objectSelection);
    }
    _syncHandlesAndContextBar();
  }

  // -----------------------------------------------------------------
  // 移动端选区手柄 + 上下文动作条(S3/S4 桥接)
  // -----------------------------------------------------------------

  SelectionHandlesController? _handles;
  CollapsedHandleController? _collapsedHandle;
  EditorContextBar? _contextBar;

  /// 手柄拖动进行中(高频选区变化不逐帧重喂 IME;controller → state 的
  /// 反向回写只在此期间开启)。collapsed 单手柄拖动同样复用此门。
  bool _handleDragging = false;

  /// 手柄拖动:_controller(DocumentSelection)→ EditorState 回写。
  /// 平时是 state → controller 单向镜像(_afterFrame),环由 == 短路。
  void _onSelectionControllerChanged() {
    if (!_handleDragging) return;
    final sel = _controller.selection;
    if (sel == null) return;
    final base = _toEditorPosition(sel.base);
    final extent = _toEditorPosition(sel.extent);
    if (base == null || extent == null) return;
    // 拖动期间延迟 ir 收口(端点交叉瞬间可能 collapsed,即时物化会
    // 闪烁回流);_onHandleDragFinished 统一补收口。
    widget.state.updateSelection(
      EditorSelection(base: base, extent: extent),
      deferIrReconcile: true,
    );
  }

  /// 帧后统一收敛手柄/动作条显隐(唯一真源:state.selection + 触摸来源)。
  void _syncHandlesAndContextBar() {
    if (_explicitObjectTarget != null || _gridImageSel != null) {
      _handles?.hide();
      _collapsedHandle?.hide();
      _contextBar?.hide();
      return;
    }
    final sel = widget.state.selection;
    final touchReady = _touchSelection && _focusNode.hasPrimaryFocus;
    final showRange =
        touchReady &&
        sel != null &&
        !sel.isCollapsed &&
        _lastImageAtomSel == null && // 图原子选中走宿主工具条
        _controller.selection != null; // 文档几何可得(失焦已清)
    if (showRange) {
      (_handles ??= SelectionHandlesController(
        context: context,
        controller: _controller,
        onDragStart: () {
          _handleDragging = true;
          _contextBar?.hide();
        },
        onDragMove: _onRangeHandleDragMoved,
        onDragEnd: _onHandleDragFinished,
      )).show();
      if (!_handleDragging &&
          !_longPressing &&
          _dragBase == null &&
          !_touchToolbarSuppressed) {
        _showContextBarForSelection();
      }
    } else {
      _handles?.hide();
      _contextBar?.hide();
    }

    // collapsed 单手柄:触摸落光标后可拖动微调(Android 系统同款;
    // iOS 无此形态 —— 系统绘制即空盒,platformHasHandle 挡掉)。
    final caretLocal = _caretInfo.value.$1;
    final rootBox = _rootKey.currentContext?.findRenderObject();
    final collapsedReady =
        !showRange &&
        touchReady &&
        sel != null &&
        sel.isCollapsed &&
        caretLocal != null &&
        rootBox is RenderBox &&
        rootBox.attached;
    if (collapsedReady && _wantCollapsedBar && !_handleDragging) {
      _showCollapsedContextBar(
        rootBox.localToGlobal(caretLocal.topLeft) & caretLocal.size,
      );
    }
    if (collapsedReady &&
        CollapsedHandleController.platformHasHandle(context)) {
      final caretGlobal =
          rootBox.localToGlobal(caretLocal.topLeft) & caretLocal.size;
      (_collapsedHandle ??= CollapsedHandleController(
        context: context,
        tapRegionGroupId: EditableText,
        onDragStart: () {
          _handleDragging = true; // IME 三门复用(拖动高频变化 end 时统一喂)
          _wantCollapsedBar = false;
          _contextBar?.hide();
          widget.state.sealHistory();
        },
        onDragMove: _onCollapsedHandleDragMoved,
        onDragEnd: _onHandleDragFinished,
      )).show(caretGlobal);
    } else {
      _collapsedHandle?.hide();
    }
  }

  /// 双手柄拖拽点移动:记录拖拽点 + 驱动边缘自动滚(选区更新由
  /// SelectionHandlesController 内部完成)。
  void _onRangeHandleDragMoved(Offset dragGlobal) {
    _handleDragPoint = dragGlobal;
    _updateAutoScroll(dragGlobal);
  }

  /// collapsed 手柄拖拽点移动:半行上移命中行中心 → 移光标 + 放大镜 +
  /// 边缘自动滚(与双手柄/长按同口径)。
  void _onCollapsedHandleDragMoved(Offset dragGlobal) {
    _handleDragPoint = dragGlobal;
    final docPos = _hitTester.positionAt(
      dragGlobal - Offset(0, _caretLineHeight / 2),
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos != null) {
      final editorPos = _toEditorPosition(docPos);
      if (editorPos != null && editorPos != widget.state.selection?.extent) {
        _caretAffinity = docPos.affinity;
        _verticalGoalX = null;
        // 拖动逐帧 collapsed 更新:延迟收口(路过 mark 逐个展开/折回 =
        // 闪烁),_onHandleDragFinished 对最终落点统一补物化。
        widget.state.updateSelection(
          EditorSelection.collapsed(editorPos),
          deferIrReconcile: true,
        );
        HapticFeedback.selectionClick();
      }
      // 放大镜:X 跟拖拽点、Y 锁光标行(长按/双手柄同口径)
      final caret = _hitTester.editingCaretRectAt(
        docPos,
        lineHeight: _caretLineHeight,
      );
      if (caret != null) {
        _showEditorMagnifier(
          gestureGlobal: dragGlobal,
          caret: caret,
          docPos: docPos,
        );
      }
    }
    _updateAutoScroll(dragGlobal);
  }

  /// 放大镜四字段喂给(SDK MagnifierInfo 口径,SelectionHandles 同款):
  /// fieldBounds = 编辑器根;lineBoundaries = caret 行横向扩到段落宽。
  void _showEditorMagnifier({
    required Offset gestureGlobal,
    required Rect caret,
    DocumentPosition? docPos,
  }) {
    Rect fieldBounds = caret;
    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (rootBox is RenderBox && rootBox.attached && rootBox.hasSize) {
      final tl = rootBox.localToGlobal(Offset.zero);
      if (tl.dx.isFinite && tl.dy.isFinite) fieldBounds = tl & rootBox.size;
    }
    Rect lineBoundaries = Rect.fromLTRB(
      fieldBounds.left,
      caret.top,
      fieldBounds.right,
      caret.bottom,
    );
    final paragraph = docPos == null
        ? null
        : _controller.registry.byId(docPos.blockId)?.paragraph;
    if (paragraph != null && paragraph.attached && paragraph.hasSize) {
      final tl = paragraph.localToGlobal(Offset.zero);
      if (tl.dx.isFinite && tl.dy.isFinite) {
        lineBoundaries = Rect.fromLTRB(
          tl.dx,
          caret.top,
          tl.dx + paragraph.size.width,
          caret.bottom,
        );
      }
    }
    (_magnifier ??= SelectionMagnifier(context)).show(
      gestureGlobal: gestureGlobal,
      caretRect: caret,
      currentLineBoundaries: lineBoundaries,
      fieldBounds: fieldBounds,
    );
  }

  /// 手柄(双/单)拖动结束的统一收尾。
  void _onHandleDragFinished() {
    _handleDragging = false;
    _handleDragPoint = null;
    _stopAutoScroll();
    _magnifier?.hide();
    // 拖动期间的延迟 ir 收口在此结算:collapsed 手柄落点补物化;
    // 双手柄终态 range 时收口守卫 no-op(选择保持不展开)。
    final before = widget.state.docRevision;
    widget.state.commitDeferredIrReconcile();
    _ime.syncFromState(show: false, force: widget.state.docRevision != before);
    // 双手柄:按新选区重新定位显示动作条;collapsed 无区间几何,内部早退。
    _showContextBarForSelection();
  }

  // -----------------------------------------------------------------
  // iOS 浮动光标(长按空格 trackpad 模式)
  // -----------------------------------------------------------------

  /// 浮动光标进行中(IME 门之一:平台在拖光标,选区高频变化,End 时
  /// 统一回喂;期间 setEditingState 会打断系统手势)。
  bool _floatingCursor = false;

  /// 上次平台/虚拟指针累计输入；转为增量后从限位位置继续移动，
  /// 不积攒越界位移，保证贴边后反向立即响应。
  Offset _floatingLastOffset = Offset.zero;
  Offset _floatingPos = Offset.zero;
  OverlayEntry? _floatingGhost;

  /// 扩选模式的固定端(虚拟指针 extend;null = collapsed 移动)。
  EditorPosition? _floatingExtendBase;

  void _onFloatingCursor(RawFloatingCursorPoint point) {
    if (!mounted) return;
    switch (point.state) {
      case FloatingCursorDragState.Start:
        _floatingStart(initialOffset: point.offset ?? Offset.zero);
      case FloatingCursorDragState.Update:
        _floatingUpdate(point.offset ?? Offset.zero);
      case FloatingCursorDragState.End:
        _floatingEnd();
    }
  }

  /// 浮动/虚拟指针起步(基准 = 当前光标中心)。[extend] = 扩选模式
  /// (base 固定,幽灵驱动 extent;IME 路径恒 false)。
  /// 返回 false = 无光标可起步(未聚焦/岛上无文本光标)。
  bool _floatingStart({
    Offset initialOffset = Offset.zero,
    bool extend = false,
  }) {
    var sel = widget.state.selection;
    // 只在正文可见区域起步，不能把标题、阅读留白算进编辑范围。
    final vp = _visibleContentRect();
    if (vp == null || vp.isEmpty) return false;

    // 视口中心命中一个文档位并落光标(虚拟指针"随时可拖"的起步锚:
    // 无光标、或光标在屏外时,都从看得见的地方开始 —— 否则幽灵生成
    // 在视口外,Update 钳回边缘还会触发边缘自动滚狂滚)。
    bool anchorAtViewportCenter() {
      final v = vp;
      if (v.isEmpty) return false;
      final docPos = _hitTester.positionAt(
        v.center,
        hitTestRoot: _rootKey.currentContext?.findRenderObject(),
      );
      if (docPos == null) return false;
      var pos = _toEditorPosition(docPos);
      if (pos == null) return false;
      // 中心命中岛块(视口被 table/图集占满时):解析到岛外邻块,
      // 不产生「按下即松手光标驻留岛位」的失焦死角。
      final index = docPos.blockId.docOrder;
      final blocks = widget.state.blocks;
      if (index >= 0 && index < blocks.length && blocks[index] is IslandBlock) {
        pos = _nearestTextEdgeAroundIsland(
          index,
          after: docPos.renderOffset > 0,
        );
        if (pos == null) return false;
      }
      _caretAffinity = docPos.affinity;
      widget.state.updateSelection(EditorSelection.collapsed(pos));
      return true;
    }

    if (sel == null) {
      if (!anchorAtViewportCenter()) return false;
      sel = widget.state.selection;
      if (sel == null) return false;
    }
    var docPos = _toDocumentPosition(sel.extent, affinity: _caretAffinity);
    // 文本块用精确行内 caret;岛位(table/图集)无注册几何、离屏块已
    // 回收时返回 null,交由下方视口中心重起步兑底。
    Rect? caretRectFor(DocumentPosition? pos) => pos == null
        ? null
        : (_hitTester.editingCaretRectAt(pos, lineHeight: _caretLineHeight) ??
              _hitTester.caretRectAt(pos));
    var rect = caretRectFor(docPos);
    // 非扩选起步 = 移动插入点。文字选区维持忽略(不破坏拖出的选区);
    // 对象/岛整选态(端点在岛上、无文本 caret)折叠到 extent 起步 ——
    // 折叠会经 _onStateChanged 自动退出对象整选态,否则点过 table/
    // 图集后滑钮再也拉不起光标(失焦死角)。
    if (!extend && !sel.isCollapsed) {
      final extentHandle = docPos == null
          ? null
          : _hitTester.registry.byId(docPos.blockId);
      if (extentHandle?.paragraph != null) return false;
      widget.state.updateSelection(EditorSelection.collapsed(sel.extent));
      sel = widget.state.selection;
      if (sel == null) return false;
    }
    // 起步矩形不可用(光标驻留岛位、所在块离屏被虚拟列表回收)或
    // 光标在视口外:改从视口中心重起步 —— 滑钮"随时可拖",不能因
    // 上次落点不可见而永久失灵。
    if (!extend && (rect == null || !vp.contains(rect.center))) {
      if (anchorAtViewportCenter()) {
        sel = widget.state.selection;
        docPos = sel == null
            ? null
            : _toDocumentPosition(sel.extent, affinity: _caretAffinity);
        final r2 = caretRectFor(docPos);
        if (r2 != null) rect = r2;
      }
    }
    if (rect == null) return false;
    if (sel == null) return false;
    _floatingCursor = true;
    _floatingExtendBase = extend ? sel.base : null;
    _floatingLastOffset = initialOffset;
    _floatingPos = _clampFloatingPosition(rect.center + initialOffset, vp);
    widget.state.sealHistory();
    _collapsedHandle?.hide();
    _contextBar?.hide();
    _showFloatingGhost();
    setState(() {}); // 实光标切灰色残影态
    return true;
  }

  /// 浮动位置更新([accumulated] = 相对起步点的累计位移)。
  void _floatingUpdate(Offset accumulated) {
    if (!_floatingCursor) return;
    final delta = accumulated - _floatingLastOffset;
    _floatingLastOffset = accumulated;
    final visible = _visibleContentRect();
    if (visible == null || visible.isEmpty) {
      _stopAutoScroll();
      return;
    }
    final pos = _clampFloatingPosition(_floatingPos + delta, visible);
    _floatingPos = pos;
    _floatingGhost?.markNeedsBuild();
    // 实光标就近吸附(EditableText 的灰色残影等价物:吸附位即落点)
    _applyFloatingHit(pos);
    // 贴视口上下缘 → 边缘自动滚(键盘态可视区小,长文档必需;
    // tick 每帧滚动后按幽灵位置重命中,吸附点随内容继续走)
    _updateAutoScroll(pos);
  }

  /// 预留幽灵本体半宽/半高；可见区域过小时收敛到中心，避免反向 clamp。
  Offset _clampFloatingPosition(Offset pos, Rect bounds) {
    final halfWidth = bounds.width < 2.5 ? bounds.width / 2 : 1.25;
    final halfHeight = bounds.height < _caretLineHeight
        ? bounds.height / 2
        : _caretLineHeight / 2;
    return Offset(
      pos.dx.clamp(bounds.left + halfWidth, bounds.right - halfWidth),
      pos.dy.clamp(bounds.top + halfHeight, bounds.bottom - halfHeight),
    );
  }

  void _floatingEnd() {
    if (!_floatingCursor) return;
    _floatingCursor = false;
    _floatingLastOffset = Offset.zero;
    _floatingExtendBase = null;
    _stopAutoScroll();
    _removeFloatingGhost();
    // 拖完把焦点还给编辑器:落点即编辑位,实光标立即可见(失焦态
    // 光标不渲染),键盘按平台惯例自然弹出。
    if (!_focusNode.hasPrimaryFocus) _focusNode.requestFocus();
    // 浮动拖动的延迟 ir 收口在此结算(落点补物化/离开折叠)。
    final beforeRev = widget.state.docRevision;
    widget.state.commitDeferredIrReconcile();
    // 最后一帧吸附在布局后完成，下一帧不能再因同一落点启动 ensure 动画；
    // 拖动滚动到此结束，后续编辑或键盘尺寸变化仍可正常触发避让。
    _caretReveal.suppressNext(widget.state.caretRevealKey);
    _ime.syncFromState(
      show: false,
      force: widget.state.docRevision != beforeRev,
    );
    setState(() {}); // 实光标恢复主题色
  }

  /// 浮动点 → 实光标吸附(Update 与自动滚 tick 共用;无半行补偿 ——
  /// 浮动点即文本行内坐标,与手柄"手指在行下方"不同)。
  void _applyFloatingHit(Offset pos) {
    final docPos = _hitTester.positionAt(
      pos,
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos == null) return;
    var editorPos = _toEditorPosition(docPos);
    // 块级对象(table/图集/onebox…)不是光标可停位 —— 与键盘移动同规
    // (「岛端点顺移到岛外邻块」):命中按上下半区解析到岛前块尾/岛后
    // 块头。否则选区驻留岛位,实光标因无文本 caret 消失,拖动会话
    // 表现为"失焦"。
    if (editorPos != null) {
      final index = docPos.blockId.docOrder;
      final blocks = widget.state.blocks;
      if (index >= 0 && index < blocks.length && blocks[index] is IslandBlock) {
        editorPos = _nearestTextEdgeAroundIsland(
          index,
          after: docPos.renderOffset > 0,
        );
      }
    }
    if (editorPos != null && editorPos != widget.state.selection?.extent) {
      _caretAffinity = docPos.affinity;
      _verticalGoalX = null;
      final extendBase = _floatingExtendBase;
      // 逐帧移动延迟 ir 收口(路过 mark 即时物化 = 闪烁),End 结算。
      widget.state.updateSelection(
        extendBase == null
            ? EditorSelection.collapsed(editorPos)
            : EditorSelection(base: extendBase, extent: editorPos),
        deferIrReconcile: true,
      );
    }
  }

  /// 岛([index])按命中侧解析到最近文本块的可停位:[after] = 岛后
  /// 块头,否则岛前块尾;首选方向没有文本块时反向兜底(文档不变量
  /// 保证至少一个 TextBlock,双查皆空才返回 null)。
  EditorPosition? _nearestTextEdgeAroundIsland(
    int index, {
    required bool after,
  }) {
    final blocks = widget.state.blocks;
    for (final forward in [after, !after]) {
      if (forward) {
        for (var i = index + 1; i < blocks.length; i++) {
          final block = blocks[i];
          if (block is TextBlock) {
            return EditorPosition(blockId: block.id, offset: 0);
          }
        }
      } else {
        for (var i = index - 1; i >= 0; i--) {
          final block = blocks[i];
          if (block is TextBlock) {
            return EditorPosition(
              blockId: block.id,
              offset: block.content.length,
            );
          }
        }
      }
    }
    return null;
  }

  /// 浮动幽灵光标:主题色圆角条 + 轻阴影,Overlay 顶层跟手平滑移动
  /// (实光标按字符格吸附,幽灵负责"浮动"体感)。
  void _showFloatingGhost() {
    if (_floatingGhost != null) {
      _floatingGhost!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _floatingGhost = OverlayEntry(
      builder: (ctx) {
        final overlayBox =
            Overlay.of(context).context.findRenderObject() as RenderBox?;
        final local = overlayBox == null
            ? _floatingPos
            : overlayBox.globalToLocal(_floatingPos);
        return Positioned(
          left: local.dx - 1.25,
          top: local.dy - _caretLineHeight / 2,
          child: IgnorePointer(
            child: Container(
              key: kFloatingCursorGhostKey,
              width: 2.5,
              height: _caretLineHeight,
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.primary,
                borderRadius: BorderRadius.circular(1.25),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_floatingGhost!);
  }

  void _removeFloatingGhost() {
    _floatingGhost?.remove();
    _floatingGhost = null;
  }

  /// 按当前选区几何弹动作条(复制/剪切/粘贴/全选)。
  void _showContextBarForSelection({Offset? anchor}) {
    final docSel = _controller.selection;
    if (docSel == null) return;
    final data = SelectionExporter(_controller.registry).export(docSel);
    if (data == null || data.globalRects.isEmpty) return;
    (_contextBar ??= EditorContextBar(
      context: context,
      tapRegionGroupId: EditableText,
    )).show(
      selectionBounds: anchor == null
          ? data.globalBounds
          : Rect.fromLTWH(anchor.dx, anchor.dy, 0, 0),
      items: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            _clipboardCopy();
            _dismissTouchSelection();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.cut,
          onPressed: () {
            _clipboardCut();
            _dismissTouchSelection();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            _clipboardPaste();
            _dismissTouchSelection();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () {
            widget.state.selectAll();
            // 全选后保持触摸态,手柄/动作条按新选区重弹
          },
        ),
        if (widget.onObjectSelectionChanged != null)
          ContextMenuButtonItem(
            label: '块操作',
            onPressed: () {
              final id = widget.state.selection?.extent.blockId;
              if (id == null) return;
              _selectObject(EditorBlockTarget(id));
              _requestObjectMenu();
            },
          ),
      ],
    );
  }

  /// collapsed 光标(无选区)的动作条:仅「粘贴 | 全选」,锚光标矩形。
  void _showCollapsedContextBar(Rect caretGlobal) {
    (_contextBar ??= EditorContextBar(
      context: context,
      tapRegionGroupId: EditableText,
    )).show(
      selectionBounds: caretGlobal,
      items: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () {
            _clipboardPaste();
            _dismissTouchSelection();
          },
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: () {
            widget.state.selectAll();
            _wantCollapsedBar = false;
          },
        ),
        if (widget.onObjectSelectionChanged != null)
          ContextMenuButtonItem(
            label: '块操作',
            onPressed: () {
              final id = widget.state.selection?.extent.blockId;
              if (id == null) return;
              _selectObject(EditorBlockTarget(id));
              _requestObjectMenu();
            },
          ),
      ],
    );
  }

  /// 动作执行后收触摸选区 UI(复制后折叠选区 = 移动惯例)。
  void _dismissTouchSelection() {
    _touchSelection = false;
    _wantCollapsedBar = false;
    _contextBar?.hide();
    _handles?.hide();
    _collapsedHandle?.hide();
  }

  /// 滚动跟随:编辑器在宿主滚动容器内,纯滚动不触发 _onStateChanged →
  /// 帧后矩形(caret/图片选中)不重算 → 浮层脱锚。挂最近 Scrollable 的
  /// position listener,滚动时帧后重报(仅有上报对象时,listener 早退)。
  ScrollPosition? _scrollPosition;

  bool _scrollRecomputeQueued = false;
  double _lastScrollPixels = 0;

  void _onScrolled() {
    // 手柄/动作条滚动跟随:算本帧 delta 做滞后补偿(阅读端同款消抖)
    final pixels = _scrollPosition?.pixels ?? 0;
    final delta = pixels - _lastScrollPixels;
    _lastScrollPixels = pixels;
    if (_handles?.isShowing ?? false) {
      _handles!.update(yCompensation: delta);
      _contextBar?.reposition(yCompensation: delta);
    }
    if (_collapsedHandle?.isShowing ?? false) {
      _collapsedHandle!.translate(delta);
    }
    if (_lastImageAtomSel == null &&
        _caretInfo.value.$1 == null &&
        _dragGlobal == null &&
        !_longPressing) {
      return;
    }
    // coalesce:滚动一帧内 position listener 可触发多次,每次都排
    // postFrame 会让 _afterFrame(getBoxesForSelection + 事件比对)一帧
    // 跑 N 遍 —— 拖选/惯性滚动时白耗 CPU。
    if (_scrollRecomputeQueued) return;
    _scrollRecomputeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollRecomputeQueued = false;
      if (mounted) {
        if (_dragGlobal != null) _applyPointerDrag(_dragGlobal!);
        if (_longPressPoint != null) _applyLongPressSelection(_longPressPoint!);
        _afterFrame();
      }
    });
  }

  void _bindScrollPosition() {
    final next = Scrollable.maybeOf(context)?.position;
    if (identical(next, _scrollPosition)) return;
    _scrollPosition?.removeListener(_onScrolled);
    _scrollPosition = next;
    _lastScrollPixels = next?.pixels ?? 0;
    _scrollPosition?.addListener(_onScrolled);
  }

  // -----------------------------------------------------------------
  // 软键盘 ensureVisible(S5)
  // -----------------------------------------------------------------

  final _caretReveal = EditorCaretRevealTracker();

  /// 光标越出可见区(视口 ∩ 键盘上方)时滚动到可见。仅折叠光标态
  /// (打字/点击);非折叠选区(手柄态)不自动滚 —— 用户在看选区。
  ///
  /// 不用 Scrollable.ensureVisible:它按**整个 RenderObject**(编辑器是
  /// 一整块巨型 child)对齐,会瞬移到块顶。position.animateTo 按光标
  /// 矩形精确滚(宿主 markdown_editor 同构做法)。
  void _ensureCaretVisible(Rect caretGlobal) {
    final pos = _scrollPosition;
    if (pos == null || !pos.hasContentDimensions) return;
    // 手柄拖动/浮动光标中光标由手指驱动,滚动交给边缘自动滚 —— ensure
    // 的 animateTo 会与 tick 的 jumpTo(或幽灵跟手)抢滚动位置(来回抖)。
    if (_handleDragging || _floatingCursor || _dragBase != null) return;
    final sel = widget.state.selection;
    if (sel == null || !sel.isCollapsed) return;
    final visible = _visibleViewportRect(forCaret: true);
    if (visible == null) return;
    final userScrolling = pos.userScrollDirection != ScrollDirection.idle;
    if (!_caretReveal.shouldReveal(
      key: widget.state.caretRevealKey,
      caret: caretGlobal,
      viewport: visible,
      userScrolling: userScrolling,
      autoScrolling: pos.isScrollingNotifier.value && !userScrolling,
    )) {
      return;
    }
    const pad = 24.0;
    final visBottom = visible.bottom - pad;
    final visTop = visible.top + pad;
    if (visBottom <= visTop) return;

    double? delta;
    if (caretGlobal.bottom > visBottom) {
      delta = caretGlobal.bottom - visBottom;
    } else if (caretGlobal.top < visTop) {
      delta = caretGlobal.top - visTop;
    }
    if (delta == null) return;
    final target = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if ((target - pos.pixels).abs() < 1) return;
    pos.animateTo(
      target,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  /// 宿主滚动视口的全局矩形(键盘遮挡部分已截掉)。
  Rect? _visibleViewportRect({bool forCaret = false}) {
    final scrollableCtx = Scrollable.maybeOf(context)?.context;
    final vpBox = scrollableCtx?.findRenderObject();
    if (vpBox is! RenderBox || !vpBox.attached || !vpBox.hasSize) return null;
    final bounds = vpBox.localToGlobal(Offset.zero) & vpBox.size;
    final vpRect = forCaret
        ? widget.caretViewportInsets.deflateRect(bounds)
        : bounds;
    final mq = MediaQuery.maybeOf(context);
    final screenH = mq?.size.height ?? vpRect.bottom;
    final kbTop = screenH - (mq?.viewInsets.bottom ?? 0);
    final bottom = vpRect.bottom < kbTop ? vpRect.bottom : kbTop;
    if (bottom <= vpRect.top) return null;
    return Rect.fromLTRB(vpRect.left, vpRect.top, vpRect.right, bottom);
  }

  /// 正文实际布局与可见视口的交集，排除宿主标题、外侧留白和键盘。
  /// 无滚动宿主时仍裁掉屏幕外及键盘遮挡的部分。
  Rect? _visibleContentRect() {
    final root = _rootKey.currentContext?.findRenderObject();
    if (root is! RenderBox || !root.attached || !root.hasSize) return null;
    var bounds = root.localToGlobal(Offset.zero) & root.size;
    final viewport = _visibleViewportRect(forCaret: true);
    if (viewport != null) bounds = bounds.intersect(viewport);
    final mq = MediaQuery.maybeOf(context);
    if (mq != null) {
      bounds = bounds.intersect(
        Rect.fromLTRB(
          0,
          0,
          mq.size.width,
          mq.size.height - mq.viewInsets.bottom,
        ),
      );
    }
    return bounds;
  }

  // -----------------------------------------------------------------
  // 手柄拖动边缘自动滚
  // -----------------------------------------------------------------

  /// 拖拽点距可视区上/下沿多近开始自动滚。
  static const double _kAutoScrollEdge = 56.0;

  /// 每帧最大滚动步长(px,≈900px/s@60fps;越贴边越快,线性)。
  static const double _kAutoScrollMaxStep = 15.0;

  /// 手柄拖拽点(双手柄/collapsed 共用,全局坐标):自动滚每帧滚动后
  /// 按它重新命中,让被拖端随内容滚动继续走。
  Offset? _handleDragPoint;

  Ticker? _autoScrollTicker;
  double _autoScrollStep = 0;

  void _updateAutoScroll(Offset dragGlobal) {
    final visible = _floatingCursor
        ? _visibleContentRect()
        : _visibleViewportRect();
    if (_scrollPosition == null || visible == null || visible.isEmpty) {
      _stopAutoScroll();
      return;
    }
    final topDist = dragGlobal.dy - visible.top;
    final bottomDist = visible.bottom - dragGlobal.dy;
    double step = 0;
    if (topDist < _kAutoScrollEdge) {
      step =
          -_kAutoScrollMaxStep *
          (1 - topDist / _kAutoScrollEdge).clamp(0.0, 1.0);
    } else if (bottomDist < _kAutoScrollEdge) {
      step =
          _kAutoScrollMaxStep *
          (1 - bottomDist / _kAutoScrollEdge).clamp(0.0, 1.0);
    }
    _autoScrollStep = step;
    if (step != 0) {
      final ticker = _autoScrollTicker ??= createTicker(_onAutoScrollTick);
      if (!ticker.isActive) ticker.start();
    } else {
      _autoScrollTicker?.stop();
    }
  }

  void _onAutoScrollTick(Duration _) {
    final pos = _scrollPosition;
    // 拖拽点:手柄用 pan 上报的 _handleDragPoint,浮动光标用幽灵位置。
    final drag = _floatingCursor
        ? _floatingPos
        : _dragGlobal ?? _longPressPoint ?? _handleDragPoint;
    final dragging =
        _handleDragging ||
        _floatingCursor ||
        _dragBase != null ||
        _longPressing;
    if (pos == null || drag == null || _autoScrollStep == 0 || !dragging) {
      _stopAutoScroll();
      return;
    }
    final target = (pos.pixels + _autoScrollStep).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (target == pos.pixels) {
      // 滚到头:停表等待反向拖动(方向反转会有新的 pan update 重启)
      _autoScrollTicker?.stop();
      return;
    }
    pos.jumpTo(target);
    // 拖拽点全局没动、内容滚过去了 → 用当前拖拽点重新命中,让被拖端
    // (或 collapsed 光标/浮动吸附点)随滚动继续走;否则只滚屏不扩选。
    if (_floatingCursor) {
      // ticker 在布局前运行；图片加载或滚动可能已令段落布局失效。
      // 等本帧布局完成再读取几何，同时按滚动后的正文范围重新限位。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_floatingCursor) return;
        final visible = _visibleContentRect();
        if (visible == null || visible.isEmpty) {
          _stopAutoScroll();
          return;
        }
        _floatingPos = _clampFloatingPosition(_floatingPos, visible);
        _floatingGhost?.markNeedsBuild();
        _applyFloatingHit(_floatingPos);
        _updateAutoScroll(_floatingPos);
      });
    } else if (_dragGlobal != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _dragGlobal != null) _applyPointerDrag(_dragGlobal!);
      });
    } else if (_longPressPoint != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _longPressPoint != null) {
          _applyLongPressSelection(_longPressPoint!);
        }
      });
    } else if (_handles?.isShowing ?? false) {
      _handles!.reapplyDrag();
    } else if (_collapsedHandle?.isShowing ?? false) {
      _onCollapsedHandleDragMoved(drag);
    }
  }

  void _stopAutoScroll() {
    _autoScrollStep = 0;
    _autoScrollTicker?.stop();
  }

  IslandSelection? _lastIslandSel;

  /// 当前恰好整选的单岛(选区 = 岛 0..1)→ 岛块 + 全局矩形;其余 null。
  IslandSelection? _computeIslandSelection() {
    final norm = widget.state.normalizedSelection();
    if (norm == null) return null;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return null;
    if (from.offset != 0 || to.offset != 1) return null;
    final idx = widget.state.indexOfBlock(from.blockId);
    if (idx < 0) return null;
    final block = widget.state.blocks[idx];
    if (block is! IslandBlock) return null;
    final box = _islandKeys[block.id]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final tl = box.localToGlobal(Offset.zero);
    if (!tl.dx.isFinite || !tl.dy.isFinite) return null;
    return IslandSelection(island: block, globalRect: tl & box.size);
  }

  /// 岛是否处于「整选」态(选区恰覆盖该岛 0..1)。
  bool _isSingleIslandSelection(String id) {
    final selection = widget.state.selection;
    return selection != null &&
        selection.base.blockId == id &&
        selection.extent.blockId == id &&
        _isIslandSelected(id);
  }

  bool _isIslandSelected(String islandId) {
    final norm = widget.state.normalizedSelection();
    if (norm == null) return false;
    final (from, to) = norm;
    final fi = widget.state.indexOfBlock(from.blockId);
    final ti = widget.state.indexOfBlock(to.blockId);
    final ii = widget.state.indexOfBlock(islandId);
    if (fi < 0 || ti < 0 || ii < 0) return false;
    // 岛在选区块区间内;端点在岛上时按四象限(0=含,1=起于岛后)
    if (ii < fi || ii > ti) return false;
    if (ii == fi && from.blockId == islandId && from.offset >= 1) return false;
    if (ii == ti && to.blockId == islandId && to.offset <= 0) return false;
    return true;
  }

  // -----------------------------------------------------------------
  // 坐标桥接
  // -----------------------------------------------------------------

  SelectableBlockId _renderIdOf(int index) => SelectableBlockId(index);

  DocumentPosition? _toDocumentPosition(
    EditorPosition pos, {
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    final index = widget.state.indexOfBlock(pos.blockId);
    if (index < 0) return null;
    final id = _renderIdOf(index);
    final proj = _controller.registry.logicalById(id)?.projection;
    // ir 大一统后光标坐标全是真实文本坐标(mark 内 = 物化字面),
    // 单一口径映射;投影显形只剩不可物化 mark 的只读兜底,其零宽
    // 定界符由 renderOffsetForContent 的延迟归属自然跳过。
    //
    // 例外:光标 = 连续编辑位(刚打完字停在 mark.end)时用**末端归属**
    // (renderEndForContent)—— 延迟归属会把 caret 排到显形闭定界符
    // 投影之后(格式外),但此刻打字明明落格式内(末端延伸豁免),
    // 光标画外面 = 所见与所得错位。末端归属画在闭定界符前,与输入
    // 落点一致。
    final atEditPos = widget.state.lastEditPos == pos;
    final renderOffset = proj == null
        ? pos.offset
        : atEditPos
        ? proj.renderEndForContent(pos.offset)
        : proj.renderOffsetForContent(pos.offset);
    return DocumentPosition(
      blockId: id,
      renderOffset: renderOffset,
      affinity: affinity,
    );
  }

  /// Preserve direction and object endpoints in the shared selection mirror.
  DocumentSelection? _toDocumentSelection(EditorSelection? sel) {
    if (sel == null || sel.isCollapsed) return null;
    final base = _toDocumentPosition(sel.base);
    final extent = _toDocumentPosition(sel.extent);
    if (base == null || extent == null) return null;
    return DocumentSelection(base: base, extent: extent);
  }

  EditorPosition? _toEditorPosition(DocumentPosition pos) {
    final index = pos.blockId.docOrder;
    final blocks = widget.state.blocks;
    if (index < 0 || index >= blocks.length) return null;
    final proj = _controller.registry.logicalById(pos.blockId)?.projection;
    final offset =
        proj?.contentOffsetForRender(pos.renderOffset) ?? pos.renderOffset;
    return EditorPosition(blockId: blocks[index].id, offset: offset);
  }

  /// 编辑光标固定行高:按**光标所在块的有效样式**取 preferredLineHeight
  /// (heading 块光标更高)。缓存键 = (baseStyle, kind, level)。
  double _caretLineHeight = 16;
  (TextStyle, TextBlockKind, int)? _caretHeightKey;

  void _ensureCaretLineHeight(TextStyle base) {
    final sel = widget.state.selection;
    final block = sel == null
        ? null
        : widget.state.textBlockById(sel.extent.blockId);
    final kind = block?.kind ?? TextBlockKind.paragraph;
    final level = block?.headingLevel ?? 1;
    final key = (base, kind, level);
    if (_caretHeightKey == key) return;
    _caretHeightKey = key;
    final style = kind == TextBlockKind.heading
        ? headingStyleFor(base, level)
        : base;
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    _caretLineHeight = painter.preferredLineHeight;
    painter.dispose();
  }

  /// 光标位置的软换行归属侧:点击时取命中结果的 affinity(点第一行行末
  /// 就显示在行末,而不是跳到第二行行首);键盘移动/编辑后重置 downstream。
  TextAffinity _caretAffinity = TextAffinity.downstream;

  Rect? _computeLocalCaretRect() {
    if (_explicitObjectTarget != null) return null;
    final sel = widget.state.selection;
    // hasPrimaryFocus:焦点在表格 cell 等子输入框时编辑器光标必须消失
    // (否则与 TextField 自己的光标形成双光标)。浮动/虚拟指针进行中
    // 例外 —— 失焦也要能看到吸附残影(工具栏滑钮随时可拖)。
    if (sel == null ||
        !sel.isCollapsed ||
        (!_focusNode.hasPrimaryFocus && !_floatingCursor)) {
      return null;
    }
    final docPos = _toDocumentPosition(sel.extent, affinity: _caretAffinity);
    if (docPos == null) return null;
    // 岛位(连续岛折叠等边缘态)无文本 caret:退回对象几何边缘位,
    // 避免实光标无声消失(看起来像失焦)。
    final globalRect =
        _hitTester.editingCaretRectAt(docPos, lineHeight: _caretLineHeight) ??
        _hitTester.caretRectAt(docPos);
    if (globalRect == null) return null;
    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (rootBox is! RenderBox || !rootBox.attached) return null;
    final topLeft = rootBox.globalToLocal(globalRect.topLeft);
    return topLeft & globalRect.size;
  }

  LinkCaretInfo? _lastLinkCaret;

  /// collapsed 光标/原子整选 ↔ 链接的进出检测(帧后;变化才通知)。
  /// 手势进行中(长按/拖手柄/浮动)不更新 —— end 后帧收敛时补。
  void _notifyLinkCaret() {
    final cb = widget.onLinkCaret;
    if (cb == null) return;
    LinkCaretInfo? info;
    final sel = widget.state.selection;
    if (sel != null &&
        _focusNode.hasPrimaryFocus &&
        !_longPressing &&
        !_handleDragging &&
        !_floatingCursor) {
      final block = widget.state.textBlockById(sel.extent.blockId);
      final norm = widget.state.normalizedSelection();
      final startOffset = norm?.$1.offset;
      final atom = block?.content.atoms[startOffset];
      final selectedLink =
          atom is LinkRun &&
          norm!.$1.blockId == norm.$2.blockId &&
          norm.$2.offset == startOffset! + 1;
      final range = selectedLink
          ? (startOffset, startOffset + 1, atom.origHref ?? atom.href)
          : sel.isCollapsed
          ? block?.content.linkRangeAt(sel.extent.offset)
          : null;
      if (block != null && range != null) {
        final (start, end, href) = range;
        final rect = _linkRangeGlobalRect(sel.extent.blockId, start, end);
        if (rect != null) {
          info = LinkCaretInfo(
            blockId: sel.extent.blockId,
            start: start,
            end: end,
            href: href,
            text: selectedLink
                ? EditableTextContent.fromInlines(atom.children).text
                : block.content.text.substring(start, end),
            rangeGlobal: rect,
          );
        }
      }
    }
    if (info != _lastLinkCaret) {
      _lastLinkCaret = info;
      cb(info);
    }
  }

  /// 链接区间(编辑偏移)的全局包围矩形:首尾光标矩形并集(单行即
  /// 精确;跨软换行取包围盒,工具条锚定够用)。
  Rect? _linkRangeGlobalRect(String blockId, int start, int end) {
    final from = _toDocumentPosition(
      EditorPosition(blockId: blockId, offset: start),
    );
    final to = _toDocumentPosition(
      EditorPosition(blockId: blockId, offset: end),
      affinity: TextAffinity.upstream,
    );
    if (from == null || to == null) return null;
    final a = _hitTester.editingCaretRectAt(from, lineHeight: _caretLineHeight);
    final b = _hitTester.editingCaretRectAt(to, lineHeight: _caretLineHeight);
    if (a == null || b == null) return null;
    return a.expandToInclude(b);
  }

  /// macOS AppKit selector 快捷键 → 编辑器命令(键事件路径的镜像;
  /// 两条路径幂等,重复触发无害:selectAll 幂等、剪贴板由 ticket 防重)。
  bool _onImeSelector(String name) {
    switch (name) {
      case 'selectAll:':
        widget.state.selectAll();
        return true;
      case 'copy:':
        _clipboardCopy();
        return true;
      case 'cut:':
        _clipboardCut();
        return true;
      case 'paste:':
        _clipboardPaste();
        return true;
    }
    return false;
  }

  // -----------------------------------------------------------------
  // 三指手势
  // -----------------------------------------------------------------

  /// 三指手势派发。只在编辑器持有焦点时响应 —— 否则页面上只是
  /// “碰到了编辑区”的三指滑动会改到文档(用户未在编辑时误操作)。
  void _onThreeFingerGesture(ThreeFingerGesture gesture) {
    if (!_focusNode.hasFocus) return;
    switch (gesture) {
      case ThreeFingerGesture.undo:
        widget.state.sealHistory();
        widget.state.undo();
        _ime.syncFromState(show: false);
      case ThreeFingerGesture.redo:
        widget.state.redo();
        _ime.syncFromState(show: false);
      case ThreeFingerGesture.copy:
        _clipboardCopy();
      case ThreeFingerGesture.cut:
        _clipboardCut();
      case ThreeFingerGesture.paste:
        _clipboardPaste();
    }
    HapticFeedback.selectionClick();
  }

  // -----------------------------------------------------------------
  // 剪贴板
  // -----------------------------------------------------------------

  /// 复制:选区 → markdown 写系统剪贴板(跨 app 通用;粘回自身经
  /// markdownImporter 还原富内容)。
  void _clipboardCopy() {
    final md = widget.state.copySelectionAsMarkdown();
    if (md.isEmpty) return;
    Clipboard.setData(ClipboardData(text: md));
  }

  void _clipboardCut() {
    final md = widget.state.copySelectionAsMarkdown();
    if (md.isEmpty) return;
    Clipboard.setData(ClipboardData(text: md));
    widget.state.deleteSelection();
    _ime.syncFromState(show: false);
  }

  /// 粘贴序号:异步 cook 期间用户再按一次 Cmd+V / 继续打字时,旧结果
  /// 作废(防乱序插入)。
  int _pasteTicket = 0;

  /// input rule `--- ` 命中:插分隔线岛。经 markdownImporter(cook)产
  /// HorizontalRuleNode;importer 缺席时无操作(标记文本已被规则清空,
  /// 用户可用插入菜单)。
  Future<void> _insertHorizontalRule(String blockId) async {
    if (widget.semanticMarkdownInserter != null) {
      await _insertSemanticRule('---', widget.state.selection);
      return;
    }
    final importer = widget.markdownImporter;
    if (importer == null) return;
    List<EditorBlock>? frag;
    try {
      frag = await importer('---');
    } catch (_) {
      return;
    }
    if (!mounted || frag == null || frag.isEmpty) return;
    // 光标已在触发块(规则清空后 offset 0),粘贴语义插入
    widget.state.pasteBlocks(frag);
    _ime.syncFromState(show: false);
  }

  /// input rule `[!type] ` 命中:征集完整内容(标题/正文/折叠态)后一次性
  /// 插 callout 岛。见 [FluxdoEditor.onCalloutTypeTrigger] 注释——不能
  /// 先插空壳再等用户续行打字,岛不是可续写容器。
  Future<void> _insertCalloutFromTyping(String blockId) async {
    final type = widget.state.pendingCalloutType;
    widget.state.pendingCalloutType = null;
    final trigger = widget.onCalloutTypeTrigger;
    final importer = widget.markdownImporter;
    final semantic = widget.semanticMarkdownInserter;
    final selection = widget.state.selection;
    final revision = widget.state.docRevision;
    if (trigger == null ||
        (importer == null && semantic == null) ||
        type == null ||
        type.isEmpty) {
      return;
    }
    final markdown = await trigger(type);
    if (!mounted || markdown == null || markdown.isEmpty) return;
    if (semantic != null) {
      if (revision != widget.state.docRevision ||
          selection != widget.state.selection) {
        return;
      }
      await _insertSemanticRule(markdown, selection);
      return;
    }
    List<EditorBlock>? frag;
    try {
      frag = await importer!(markdown);
    } catch (_) {
      return;
    }
    if (!mounted || frag == null || frag.isEmpty) return;
    widget.state.pasteBlocks(frag);
    _ime.syncFromState(show: false);
  }

  /// 规则生成的源码也走同一语义入口，失败保留完整源码，不吞掉已清空标记。
  Future<void> _insertSemanticRule(
    String markdown,
    EditorSelection? selection,
  ) async {
    final revision = widget.state.docRevision;
    if (await _trySemanticMarkdown(markdown, selection)) return;
    if (!mounted ||
        revision != widget.state.docRevision ||
        selection != widget.state.selection) {
      return;
    }
    List<EditorBlock>? fragment;
    try {
      fragment = await widget.markdownImporter?.call(markdown);
    } catch (_) {}
    if (!mounted ||
        revision != widget.state.docRevision ||
        selection != widget.state.selection) {
      return;
    }
    if (fragment != null && fragment.isNotEmpty) {
      widget.state.pasteBlocks(fragment);
    } else {
      widget.state.pastePlainText(markdown);
    }
    _ime.syncFromState(show: false);
  }

  Future<bool> _trySemanticMarkdown(
    String markdown,
    EditorSelection? selection,
  ) async {
    try {
      final consumed =
          await widget.semanticMarkdownInserter?.call(markdown, selection) ??
          false;
      if (consumed && mounted) _ime.syncFromState(show: false);
      return consumed;
    } catch (_) {
      return false;
    }
  }

  Future<void> _clipboardPaste() async {
    final ticket = ++_pasteTicket;
    final selection = widget.state.selection;
    final revision = widget.state.docRevision;
    final semantic =
        widget.semanticMarkdownInserter != null ||
        widget.semanticRichPasteInserter != null;
    // 未启用语义入口时保留旧行为；启用后迟到的回落绝不覆盖新输入。
    bool valid() =>
        mounted &&
        ticket == _pasteTicket &&
        (!semantic ||
            (revision == widget.state.docRevision &&
                selection == widget.state.selection));
    final semanticRich = widget.semanticRichPasteInserter;
    // 必须在本方法的首个 await 前调用，让宿主同步捕获语义书签。
    if (semanticRich != null) {
      try {
        if (await semanticRich(selection)) {
          if (mounted) _ime.syncFromState(show: false);
          return;
        }
      } catch (_) {}
      if (!valid()) return;
    }

    // 富格式优先(text/html 等):宿主读剪贴板+转换,拿到块直接插;
    // 任何一步落空回落纯文本路径(不叠加插入)。
    final rich = widget.richPasteImporter;
    if (rich != null) {
      List<EditorBlock>? frag;
      try {
        frag = await rich();
      } catch (_) {
        frag = null;
      }
      if (!valid()) return;
      if (frag != null && frag.isNotEmpty) {
        widget.state.pasteBlocks(frag);
        _ime.syncFromState(show: false);
        return;
      }
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (!valid()) return;

    if (widget.semanticMarkdownInserter != null) {
      if (await _trySemanticMarkdown(text, selection)) return;
      if (!valid()) return;
    }
    final importer = widget.markdownImporter;
    List<EditorBlock>? fragment;
    if (importer != null) {
      try {
        fragment = await importer(text);
      } catch (_) {
        fragment = null; // 导入失败降级纯文本
      }
      if (!valid()) return;
    }

    if (fragment != null && fragment.isNotEmpty) {
      widget.state.pasteBlocks(fragment);
    } else {
      widget.state.pastePlainText(text);
    }
    _ime.syncFromState(show: false);
  }

  // -----------------------------------------------------------------
  // 垂直光标移动(上下键)
  // -----------------------------------------------------------------

  /// goal column:连续上下移动时记住起始 x,途经短行不丢列位
  /// (所有编辑器的标准行为)。横向移动/点击/编辑时清空。
  double? _verticalGoalX;

  void _moveCaretVertical(int direction, {required bool extend}) {
    final sel = widget.state.selection;
    if (sel == null) return;
    final docPos = _toDocumentPosition(sel.extent);
    if (docPos == null) return;
    final caret = _hitTester.editingCaretRectAt(
      docPos,
      lineHeight: _caretLineHeight,
    );
    if (caret == null) return;

    final goalX = _verticalGoalX ??= caret.center.dx;
    // 目标点:上一行/下一行的行内(半行高步进;positionAt 有最近块兜底,
    // 文档首尾越界会停在首/末行 —— 此时若位置没变说明到顶/到底)。
    final targetY = direction < 0
        ? caret.top - caret.height / 2
        : caret.bottom + caret.height / 2;
    final hit = _hitTester.positionAt(
      Offset(goalX, targetY),
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (hit == null) return;
    final next = _toEditorPosition(hit);
    if (next == null) return;

    // 到顶/到底:位置不变 → 跳到段首/文档端点(对齐系统编辑器)。
    if (next == sel.extent) {
      final blocks = widget.state.blocks;
      final idx = widget.state.indexOfBlock(sel.extent.blockId);
      if (idx < 0) return;
      final EditorPosition endpoint = direction < 0
          ? EditorPosition(blockId: blocks.first.id, offset: 0)
          : EditorPosition(
              blockId: blocks.last.id,
              offset: blocks.last.selectionLength,
            );
      if (endpoint == sel.extent) return;
      widget.state.updateSelection(
        extend
            ? EditorSelection(base: sel.base, extent: endpoint)
            : EditorSelection.collapsed(endpoint),
      );
      _ime.syncFromState(show: false);
      return;
    }

    widget.state.updateSelection(
      extend
          ? EditorSelection(base: sel.base, extent: next)
          : EditorSelection.collapsed(next),
    );
    _ime.syncFromState(show: false);
  }

  // -----------------------------------------------------------------
  // 手势
  // -----------------------------------------------------------------

  /// 命中 → 编辑位置;顺带带出命中侧 affinity(软换行行末/行首)。
  (EditorPosition, TextAffinity)? _hitAtGlobal(
    Offset global, {
    EditorPosition? selectionBase,
  }) {
    final pos = _hitTester.positionAt(
      global,
      selectionBase: selectionBase == null
          ? null
          : _toDocumentPosition(selectionBase),
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (pos == null) return null;
    final editor = _toEditorPosition(pos);
    if (editor == null) return null;
    return (editor, pos.affinity);
  }

  TextSelectionRules get _selectionRules =>
      TextSelectionRules(defaultTargetPlatform, TextSelectionSurface.editable);
  int _effectiveTapCount(int count) => _selectionRules.tapCount(count, null);
  int _tapCount = 1;
  bool _shiftPressed = false;
  bool _focusedAtDown = false;
  EditorSelection? _selectionBeforeTap;
  (EditorPosition, TextAffinity)? _irTapAnchor;
  Offset? _irTapPoint;
  EditorSelection? _tapUnit;

  void _onTapTrackStart() {
    _shiftPressed = shiftModifierHeld();
    _selectionBeforeTap = widget.state.selection;
    _focusedAtDown = _focusNode.hasPrimaryFocus;
  }

  void _onTapTrackReset() {
    _irTapAnchor = null;
    _irTapPoint = null;
  }

  /// 本次按下已被专用路径消费(自管区/岛区/图原子整选/双击选词/无命中)
  /// → 松手(tapUp)不再落光标。
  bool _tapUpConsumed = false;
  Offset? _pendingImageTap;
  PointerDeviceKind? _pendingImageKind;
  DateTime? _lastImageClickTime;
  (String, int)? _lastImageClick;

  /// tap 序列进行中(down 已落光标,等 up 结算展开 / cancel 作废)。
  /// 期间显形压住:down 落进 mark 不能当帧显形 —— 若随后长按/滚动
  /// 接管,闪出的定界符又缩回去(闪烁),回流还让手势命中坐标漂移。
  bool _tapPending = false;
  TapDragDownDetails? _pendingTouchTap;

  void _onTapDown(TapDragDownDetails details) {
    // 触屏的 tapDown 在竞技场裁决前就会触发。按住片刻再滚动时，
    // 不得提前改选区、抢焦点或弹键盘；确认 tapUp 后再统一落光标。
    if ((details.kind != PointerDeviceKind.mouse ||
            defaultTargetPlatform == TargetPlatform.iOS) &&
        _effectiveTapCount(details.consecutiveTapCount) == 1) {
      _pendingTouchTap = details;
      return;
    }
    _beginTap(details);
  }

  void _beginTap(TapDragDownDetails details) {
    _tapCount = _effectiveTapCount(details.consecutiveTapCount);
    _tapUnit = null;
    _pendingImageTap = null;
    _pendingImageKind = details.kind;
    _tapUpConsumed = false;
    // 点在表格网格等自管交互区:编辑器手势完全让路 —— 抢焦点/设选区/
    // 弹 IME 都不做(否则:选区兜底跳到邻块 + 编辑器光标与 cell
    // TextField 光标并存 = 双光标,焦点还来回闪)。
    if (_hitsSelfManagedRegion(details.globalPosition)) {
      _tapUpConsumed = true;
      return;
    }
    // 岛的点击/长按由内部控件处理。共享几何仅用于从正文拖入的选区，
    // 不抢岛内菜单、轮播和子编辑器的焦点。
    if (_hitsIslandRegion(details.globalPosition)) {
      _tapUpConsumed = true;
      return;
    }
    _wantCollapsedBar = false; // 新 tap:收 collapsed 粘贴条
    var hit = _hitAtGlobal(details.globalPosition);
    _focusNode.requestFocus();
    if (hit == null) {
      _tapUpConsumed = true;
      return;
    }

    // 图片原子探测(**先于落光标**,官方 NodeSelection 语义)
    if (_trySelectImageAtomAt(hit.$1, details.globalPosition, select: false)) {
      _pendingImageTap = details.globalPosition;
      _tapUpConsumed = true;
      return;
    }

    if (_tapCount > 1) {
      // Only retain the first click's logical location when IR expansion moved
      // the text under an otherwise stationary pointer. Ordinary clicks always
      // hit-test the new point, like RenderEditable.
      final anchored =
          _irTapAnchor != null &&
          _irTapPoint != null &&
          (details.globalPosition - _irTapPoint!).distance <= 1;
      final target = anchored ? _irTapAnchor! : hit;
      final unit = _selectionUnitAt(target.$1, target.$2, _tapCount);
      if (unit != null) {
        _tapUnit = unit;
        _touchToolbarSuppressed = false;
        _touchSelection = details.kind != PointerDeviceKind.mouse;
        widget.state.sealHistory();
        widget.state.updateSelection(unit, deferIrReconcile: true);
        _ime.syncFromState(show: false);
        _tapUpConsumed = true;
        return;
      }
    }

    if (!_shiftPressed &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        (details.kind == PointerDeviceKind.touch ||
            details.kind == PointerDeviceKind.unknown)) {
      final previous = _selectionBeforeTap;
      final position = _linearOffset(hit.$1);
      final low = previous == null
          ? -1
          : math.min(
              _linearOffset(previous.base),
              _linearOffset(previous.extent),
            );
      final high = previous == null
          ? -1
          : math.max(
              _linearOffset(previous.base),
              _linearOffset(previous.extent),
            );
      final onSelection =
          previous != null &&
          (previous.isCollapsed
              ? position == low && hit.$2 == _caretAffinity
              : position > low && position < high);
      if (_focusedAtDown && onSelection) {
        final showing = _contextBar?.isShowing ?? false;
        _touchToolbarSuppressed = showing;
        _wantCollapsedBar = !showing;
        if (showing) _contextBar?.hide();
        _touchSelection = true;
        _tapUpConsumed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _afterFrame();
        });
        return;
      }
      final doc = _toDocumentPosition(hit.$1, affinity: hit.$2);
      final paragraph = doc == null
          ? null
          : _controller.registry.byId(doc.blockId)?.paragraph;
      if (paragraph != null && doc != null) {
        final word = paragraph.getWordBoundary(
          TextPosition(offset: doc.renderOffset, affinity: doc.affinity),
        );
        final trailing = doc.renderOffset > word.start;
        final edge = _toEditorPosition(
          DocumentPosition(
            blockId: doc.blockId,
            renderOffset: trailing ? word.end : word.start,
          ),
        );
        if (edge != null) {
          hit = (
            edge,
            trailing ? TextAffinity.upstream : TextAffinity.downstream,
          );
        }
      }
    }
    _touchToolbarSuppressed = false;

    // 单击:**按下即落光标**(用户预期:点下去光标立刻出现在指位),
    // 但「展开」两件事延迟到松手(Vditor:落下后才展开):
    // - 物化(deferIrReconcile,tapUp 结算);
    // - 显形(_tapPending 压住 revealMarkdownAt,tapUp 放开)。
    // 鼠标拖选随后接管(tapCancel)时形态不变；触屏到 tapUp 才走这里。
    _touchSelection =
        details.kind == PointerDeviceKind.touch ||
        details.kind == PointerDeviceKind.stylus;
    _verticalGoalX = null;
    _caretAffinity = hit.$2;
    _tapPending = true;
    widget.state.sealHistory();
    widget.state.updateSelection(
      _shiftPressed && _selectionBeforeTap != null
          ? _shiftSelection(_selectionBeforeTap!, hit.$1)
          : EditorSelection.collapsed(hit.$1),
      deferIrReconcile: true,
    );
    _ime.syncFromState();
  }

  /// tap 赢得竞技场且松手(确认单击)→ 结算展开:补跑延迟的 ir 收口
  /// (物化落点 mark 簇/折叠离开的字面)+ 放开显形。这是 ir 展开唯一
  /// 的指针触发点。
  void _onTapUp(TapDragUpDetails details) {
    final touchTap = _pendingTouchTap;
    _pendingTouchTap = null;
    if (touchTap != null) _beginTap(touchTap);
    final imageTap = _pendingImageTap;
    _pendingImageTap = null;
    if (imageTap != null) {
      _tapUpConsumed = false;
      final hit = _hitAtGlobal(details.globalPosition);
      if (hit != null) _trySelectImageAtomAt(hit.$1, details.globalPosition);
      if (_pendingImageKind == PointerDeviceKind.mouse) {
        final selected = _computeImageAtomSelection();
        if (selected != null) {
          final now = DateTime.now();
          final identity = (selected.blockId, selected.offset);
          if (_lastImageClick == identity &&
              _lastImageClickTime != null &&
              now.difference(_lastImageClickTime!) < kDoubleTapTimeout) {
            widget.onImageAtomOpenRequest?.call(selected);
            _lastImageClickTime = null;
          } else {
            _lastImageClick = identity;
            _lastImageClickTime = now;
          }
        }
      }
      return;
    }
    final wasPending = _tapPending;
    _tapPending = false;
    if (_tapUpConsumed) {
      _tapUpConsumed = false;
      return;
    }
    if (!wasPending) return;
    widget.onEditingActivity?.call();
    final before = widget.state.docRevision;
    widget.state.commitDeferredIrReconcile();
    if (widget.state.docRevision != before) {
      final caret = widget.state.selection;
      if (_tapCount == 1 && caret != null && caret.isCollapsed) {
        _irTapAnchor = (caret.extent, _caretAffinity);
        _irTapPoint = details.globalPosition;
      }
      // 物化改了文本:IME 窗口强制重喂,防平台侧 diff 错位。
      _ime.syncFromState(show: false, force: true);
    } else {
      // 无文本变化也要重建一帧:放开 _tapPending 压住的显形。
      setState(() {});
    }

    // 可编辑原子(date chip)单击 → 请求编辑(对齐官方:chip 是节点,
    // 点击/工具栏弹 modal 改属性)。命中位置左右各探一格:tap 落点在
    // 原子字符两侧边界都算点中它。
    final onAtomTap = widget.onAtomTap;
    final sel = widget.state.selection;
    if (sel == null || !sel.isCollapsed) return;
    final block = widget.state.textBlockById(sel.extent.blockId);
    if (block == null) return;
    for (final off in [sel.extent.offset, sel.extent.offset - 1]) {
      if (off < 0) continue;
      final atom = block.content.atoms[off];
      if (atom is LinkRun) {
        widget.state.updateSelection(
          EditorSelection(
            base: EditorPosition(blockId: block.id, offset: off),
            extent: EditorPosition(blockId: block.id, offset: off + 1),
          ),
        );
        return;
      }
      if (atom is LocalDateRun) {
        onAtomTap?.call(sel.extent.blockId, off, atom);
        return;
      }
    }
  }

  /// tap 输给竞技场(长按/滚动/拖选接管)→ 不展开:光标留在按下位,
  /// 延迟收口作废(形态零变化;后续手势自己驱动选区)。
  void _onTapCancel() {
    if (_dragBase != null) {
      _magnifier?.hide();
      _dragBase = null;
      _dragUnit = null;
      _dragGlobal = null;
      _stopAutoScroll();
    }
    widget.state.cancelDeferredIrReconcile();
    _pendingTouchTap = null;
    _onTapTrackReset();
    _pendingImageTap = null;
    _lastImageClickTime = null;
    _tapUpConsumed = false;
    if (_tapPending) {
      _tapPending = false;
      widget.state.cancelDeferredIrReconcile();
      setState(() {});
    }
  }

  /// [pos] 附近若命中图片原子(渲染盒内)→ 整选/打开,返回 true。
  /// tap 与长按共用(长按图片 = tap 同款 NodeSelection 语义)。
  ///
  /// 命中判定 = tap 点**落在图的渲染盒内**(getBoxesForSelection):
  /// 只按"最近文本位置左右一格"判会把图片行右侧整片空白都当图 ——
  /// 点空白误选图/误开查看器。
  bool _trySelectImageAtomAt(
    EditorPosition pos,
    Offset global, {
    bool select = true,
  }) {
    final tapBlock = widget.state.textBlockById(pos.blockId);
    if (tapBlock == null) return false;
    for (final off in [pos.offset, pos.offset - 1]) {
      if (off < 0) continue;
      final atom = tapBlock.content.atoms[off];
      if (atom is! ImageRun) continue;
      if (!_tapInsideAtomBox(tapBlock.id, off, global)) continue;
      if (!select) return true;
      final already = _imageAtomSelectionAt(tapBlock.id, off) != null;
      if (!already) {
        widget.state.sealHistory();
        widget.state.updateSelection(
          EditorSelection(
            base: EditorPosition(blockId: tapBlock.id, offset: off),
            extent: EditorPosition(blockId: tapBlock.id, offset: off + 1),
          ),
        );
        _ime.syncFromState(show: false); // 选中图不弹软键盘
      }
      return true;
    }
    return false;
  }

  void _selectObject(EditorObjectTarget target) {
    final object = resolveEditorObject(widget.state, target);
    if (object == null) return;
    if (target is EditorGridImageTarget) {
      final image = _gridKeys[target.blockId]?.currentState?.selectionFor(
        target.index,
      );
      if (image != null) {
        _explicitObjectTarget = null;
        _setGridImageSelection(image);
        _afterFrame();
      }
      return;
    }
    _explicitObjectTarget =
        target is EditorBlockTarget || target is EditorContainerTarget
        ? target
        : null;
    _setGridImageSelection(null);
    _focusNode.requestFocus();
    widget.state.sealHistory();
    widget.state.updateSelection(object.selection);
    _touchSelection = false;
    _contextBar?.hide();
    _ime.syncFromState(show: false);
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFrame());
  }

  void _continueAfterDocument() {
    _explicitObjectTarget = null;
    _setGridImageSelection(null);
    widget.state.continueAfterDocument();
    _focusNode.requestFocus();
    _ime.syncFromState();
  }

  EditorObjectSelection? _computeObjectSelection() {
    final grid = _gridImageSel;
    if (grid != null) {
      final image = _gridKeys[grid.$1]?.currentState?.selectionFor(grid.$2);
      if (image != null) {
        return EditorObjectSelection(
          target: EditorGridImageTarget(grid.$1, grid.$2, image.image.src),
          globalRect: image.globalRect,
          revision: widget.state.docRevision,
        );
      }
    }
    final explicit = _explicitObjectTarget;
    if (explicit != null) {
      final object = resolveEditorObject(widget.state, explicit);
      if (object == null) return null;
      final key = explicit is EditorContainerTarget
          ? _containerKeys[(explicit.groupId, object.blocks.first.id)]
          : _blockKeys[explicit.blockId];
      final rect = _objectRect(key);
      return rect == null
          ? null
          : EditorObjectSelection(
              target: explicit,
              globalRect: rect,
              revision: widget.state.docRevision,
            );
    }
    final image = _computeImageAtomSelection();
    if (image != null) {
      return EditorObjectSelection(
        target: EditorImageTarget(image.blockId, image.offset, image.image.src),
        globalRect: image.globalRect,
        revision: widget.state.docRevision,
      );
    }
    final island = _computeIslandSelection();
    return island == null
        ? null
        : EditorObjectSelection(
            target: EditorBlockTarget(island.island.id),
            globalRect:
                _objectRect(_blockKeys[island.island.id]) ?? island.globalRect,
            revision: widget.state.docRevision,
          );
  }

  Rect? _objectRect(GlobalKey? key) {
    final box = key?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  List<Rect> _visiblePaintedRects() {
    final viewport = _visibleViewportRect();
    final result = <Rect>[];
    void add(Rect? rect) {
      if (rect == null || !rect.isFinite || rect.isEmpty) return;
      final visible = viewport == null ? rect : rect.intersect(viewport);
      if (!visible.isEmpty) result.add(visible);
    }

    // Header rows stretch across their container, but only their title/icons
    // occupy that space. Inspect painted glyphs, not the row's layout width.
    void addHeader(GlobalKey? key, Rect bounds) {
      final root = key?.currentContext?.findRenderObject();
      if (root == null) return;
      final header = Rect.fromLTRB(
        bounds.left,
        bounds.top,
        bounds.right,
        (bounds.top + 48).clamp(bounds.top, bounds.bottom),
      );
      void visit(RenderObject object) {
        if (object is RenderBox && object.attached && object.hasSize) {
          final rect = object.localToGlobal(Offset.zero) & object.size;
          if (!rect.isFinite || !rect.overlaps(header)) return;
          if (object is RenderParagraph) {
            for (final line in mergeSelectionBoxesByLine(
              object.getBoxesForSelection(
                TextSelection(
                  baseOffset: 0,
                  extentOffset: object.text.toPlainText().length,
                ),
              ),
            )) {
              add(
                line.shift(object.localToGlobal(Offset.zero)).intersect(header),
              );
            }
          }
        }
        object.visitChildren(visit);
      }

      visit(root);
    }

    for (final entry in _blockKeys.entries) {
      final rect = _objectRect(entry.value);
      if (rect == null || (viewport != null && !rect.overlaps(viewport))) {
        continue;
      }
      final index = widget.state.indexOfBlock(entry.key);
      if (index < 0) continue;
      final block = widget.state.blocks[index];
      if (block is TextBlock) {
        final paragraph = _controller.registry
            .byId(_renderIdOf(index))
            ?.paragraph;
        if (paragraph == null || !paragraph.attached || !paragraph.hasSize) {
          add(rect);
          continue;
        }
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: 0,
            extentOffset: paragraph.text.toPlainText().length,
          ),
        );
        final origin = paragraph.localToGlobal(Offset.zero);
        for (final line in mergeSelectionBoxesByLine(boxes)) {
          add(line.shift(origin));
        }
      } else if (block is IslandBlock && block.node is ImageGridNode) {
        final grid = _gridKeys[block.id]?.currentState;
        if (grid == null) {
          add(rect);
          continue;
        }
        final node = block.node as ImageGridNode;
        for (var i = 0; i < node.images.length; i++) {
          add(grid.selectionFor(i)?.globalRect.intersect(rect));
        }
        addHeader(entry.value, rect);
      } else {
        add(rect);
      }
    }
    for (final key in _containerKeys.values) {
      final rect = _objectRect(key);
      if (rect != null && (viewport == null || rect.overlaps(viewport))) {
        addHeader(key, rect);
      }
    }
    return result;
  }

  EditorObjectSelection? _blockAt(Offset position, {double leadingSlop = 0}) {
    final viewport = _visibleViewportRect();
    if (viewport != null && !viewport.contains(position)) return null;
    EditorObjectSelection snapshot(EditorObjectTarget target, Rect rect) =>
        EditorObjectSelection(
          target: target,
          globalRect: rect,
          revision: widget.state.docRevision,
        );
    final blocks = <(String, Rect)>[];
    for (final entry in _blockKeys.entries) {
      final rect = _objectRect(entry.value);
      if (rect == null || !rect.isFinite || rect.isEmpty) continue;
      if (rect.contains(position)) {
        return snapshot(EditorBlockTarget(entry.key), rect);
      }
      if (leadingSlop > 0 &&
          Rect.fromLTRB(
            rect.left - leadingSlop,
            rect.top,
            rect.right,
            rect.bottom,
          ).contains(position)) {
        blocks.add((entry.key, rect));
      }
    }
    EditorObjectSelection? containerAt(double slop) {
      EditorObjectSelection? closest;
      var area = double.infinity;
      for (final entry in _containerKeys.entries) {
        final rect = _objectRect(entry.value);
        if (rect == null || !rect.isFinite || rect.isEmpty) continue;
        if (!Rect.fromLTRB(
          rect.left - slop,
          rect.top,
          rect.right,
          rect.bottom,
        ).contains(position)) {
          continue;
        }
        if (rect.width * rect.height < area) {
          closest = snapshot(
            EditorContainerTarget(entry.key.$2, entry.key.$1),
            rect,
          );
          area = rect.width * rect.height;
        }
      }
      return closest;
    }

    // Text belongs to its paragraph; a header/border selects the surrounding
    // container. The leading gutter also reaches the outer container as a unit.
    final container =
        containerAt(0) ?? (leadingSlop > 0 ? containerAt(leadingSlop) : null);
    if (container != null) return container;
    if (blocks.isEmpty) return null;
    final block = blocks.first;
    return snapshot(EditorBlockTarget(block.$1), block.$2);
  }

  void _requestObjectMenu() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _afterFrame();
      final object = _lastObjectSelection;
      if (object != null && widget.onObjectMenuRequested != null) {
        widget.onObjectMenuRequested!(
          EditorObjectMenuRequest(target: object.target),
        );
      } else {
        widget.onObjectContextMenuRequest?.call();
      }
    });
  }

  void _secondaryObjectMenu(EditorObjectTarget target, Offset global) {
    final object = resolveEditorObject(widget.state, target);
    if (object == null) return;
    if (target is! EditorGridImageTarget) _selectObject(target);
    if (widget.onObjectMenuRequested != null) {
      widget.onObjectMenuRequested!(
        EditorObjectMenuRequest(
          target: target,
          globalPosition: global,
          transient: true,
        ),
      );
    } else {
      _requestObjectMenu();
    }
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final global = details.globalPosition;
    final hit = _hitAtGlobal(global);
    if (hit != null && _trySelectImageAtomAt(hit.$1, global, select: false)) {
      _trySelectImageAtomAt(hit.$1, global);
      final image = _computeImageAtomSelection();
      if (image != null) {
        _secondaryObjectMenu(
          EditorImageTarget(image.blockId, image.offset, image.image.src),
          global,
        );
      }
      return;
    }
    if (widget.onObjectMenuRequested == null) return;
    for (final entry in _blockKeys.entries) {
      if (_objectRect(entry.value)?.contains(global) != true) continue;
      if (_explicitObjectTarget == null &&
          widget.state.selection?.isCollapsed == false &&
          widget.state.textBlockById(entry.key) != null) {
        _showContextBarForSelection(anchor: global);
      } else {
        _secondaryObjectMenu(EditorBlockTarget(entry.key), global);
      }
      return;
    }
    // 标题/边框没有文本命中时，选择覆盖指针的最内层容器。
    (EditorContainerTarget, double)? closest;
    for (final entry in _containerKeys.entries) {
      final rect = _objectRect(entry.value);
      if (rect == null || !rect.contains(global)) continue;
      final area = rect.width * rect.height;
      if (closest == null || area < closest.$2) {
        closest = (EditorContainerTarget(entry.key.$2, entry.key.$1), area);
      }
    }
    if (closest != null) _secondaryObjectMenu(closest.$1, global);
  }

  // -----------------------------------------------------------------
  // 长按选词(触摸/触控笔;S2)
  // -----------------------------------------------------------------

  /// 长按进行中(选区高频变化不逐帧重喂 IME,end 统一 sync)。
  bool _longPressing = false;
  bool _longPressMovesCaret = false;
  EditorSelection? _longPressUnit;
  Offset? _longPressPoint;

  /// 本次 collapsed 光标是否该配动作条(仅"长按空白落光标"那次 true;
  /// 普通点击/打字/移动光标一概 false —— 否则每次点击都弹粘贴条)。
  /// 移动端惯例:长按无选中处 → 出「粘贴 | 全选」。
  bool _wantCollapsedBar = false;

  /// 最近一次选区变化来自触摸(长按/双击/拖手柄)→ 手柄显示依据。
  bool _touchSelection = false;
  bool _touchToolbarSuppressed = false;

  SelectionMagnifier? _magnifier;

  void _onLongPressStart(LongPressStartDetails details) {
    // The SDK tap recognizer resets its click sequence when long press wins.
    _onTapTrackReset();
    final global = details.globalPosition;
    if (_hitsSelfManagedRegion(global) || _hitsIslandRegion(global)) return;
    final docPos = _hitTester.positionAt(
      global,
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos == null) return;
    _longPressMovesCaret =
        _focusNode.hasPrimaryFocus &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    _longPressUnit = null;
    _touchToolbarSuppressed = false;
    _focusNode.requestFocus();

    // 图片原子:长按 = tap 同款整选(不选词)
    final editorPos = _toEditorPosition(docPos);
    if (editorPos != null && _trySelectImageAtomAt(editorPos, global)) {
      _touchSelection = true;
      _requestObjectMenu();
      return;
    }

    if (editorPos == null) return;
    widget.state.sealHistory();
    _longPressUnit = _longPressMovesCaret
        ? null
        : _selectionUnitAt(editorPos, docPos.affinity, 2);
    widget.state.updateSelection(
      _longPressUnit ?? EditorSelection.collapsed(editorPos),
      deferIrReconcile: true,
    );
    if (_longPressUnit?.isCollapsed == false) HapticFeedback.selectionClick();
    _touchSelection = true;
    _longPressing = true;
    _longPressPoint = global;
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_longPressing) return;
    _longPressPoint = details.globalPosition;
    _applyLongPressSelection(details.globalPosition);
    _updateAutoScroll(details.globalPosition);
    final docPos = _hitTester.positionAt(
      details.globalPosition,
      hitTestRoot: _rootKey.currentContext?.findRenderObject(),
    );
    if (docPos == null) return;
    // 放大镜跟手
    final caret = _hitTester.editingCaretRectAt(
      docPos,
      lineHeight: _caretLineHeight,
    );
    if (caret != null) {
      _showEditorMagnifier(
        gestureGlobal: details.globalPosition,
        caret: caret,
        docPos: docPos,
      );
    }
  }

  void _applyLongPressSelection(Offset global) {
    final hit = _hitAtGlobal(global);
    if (hit == null) return;
    final anchor = _longPressUnit;
    final target = anchor == null
        ? null
        : _selectionUnitAtPoint(hit, global, 2);
    final range = anchor == null || target == null
        ? null
        : TextSelectionRules.extendUnit(
            anchorStart: anchor.base,
            anchorEnd: anchor.extent,
            targetStart: target.base,
            targetEnd: target.extent,
            compare: (EditorPosition a, EditorPosition b) =>
                _linearOffset(a).compareTo(_linearOffset(b)),
          );
    final selection = range == null
        ? EditorSelection.collapsed(hit.$1)
        : EditorSelection(base: range.base, extent: range.extent);
    widget.state.updateSelection(selection, deferIrReconcile: true);
  }

  void _onLongPressEnd(LongPressEndDetails details) => _finishLongPress();

  void _finishLongPress() {
    if (!_longPressing) {
      _magnifier?.hide();
      return;
    }
    _longPressing = false;
    _longPressPoint = null;
    _longPressUnit = null;
    _stopAutoScroll();
    _magnifier?.hide();
    // 长按序列的延迟 ir 收口结算:终态 collapsed(长按空白落光标)补
    // 物化;终态 range(选词/拖扩)收口守卫 no-op,选择保持不展开。
    final beforeRev = widget.state.docRevision;
    widget.state.commitDeferredIrReconcile();
    // 长按落在空白/空段(collapsed)→ 松手配「粘贴 | 全选」动作条
    // (长按选词是 range,走 showRange 分支,与此无关)
    final sel = widget.state.selection;
    _wantCollapsedBar = sel != null && sel.isCollapsed;
    _ime.syncFromState(
      show: false,
      force: widget.state.docRevision != beforeRev,
    );
    // end 无状态变化不触发 _onStateChanged → 帧后手动收敛一次
    // (动作条在 _longPressing 期间被压着,此刻弹出)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _afterFrame();
    });
  }

  /// [global] 是否落在孤岛区域内(EditorIsland 的 MetaData 标记)。
  /// 岛内起手时让路给对象操作；从正文起手的跨块拖选仍访问岛的几何。
  bool _hitsIslandRegion(Offset global) {
    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (rootBox is! RenderBox || !rootBox.attached) return false;
    final result = BoxHitTestResult();
    rootBox.hitTest(result, position: rootBox.globalToLocal(global));
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderMetaData && t.metaData == kEditorIslandRegion) {
        return true;
      }
    }
    return false;
  }

  /// 当前选区是否恰好整选 [blockId] 块 [offset] 处的图片原子。
  /// 是则返回 (blockId, offset),否则 null。
  (String, int)? _imageAtomSelectionAt(String blockId, int offset) {
    final norm = widget.state.normalizedSelection();
    if (norm == null) return null;
    final (from, to) = norm;
    if (from.blockId != blockId || to.blockId != blockId) return null;
    if (from.offset != offset || to.offset != offset + 1) return null;
    return (blockId, offset);
  }

  /// tap 全局坐标是否落在 [blockId] 块 [offset] 原子的渲染盒内。
  /// 横向命中即可(纵向放 4px 容差):FFFC 的 selection box 覆盖整行高,
  /// 图旁小字行的纵向空白仍算图列范围,与直觉一致。
  bool _tapInsideAtomBox(String blockId, int offset, Offset global) {
    final index = widget.state.indexOfBlock(blockId);
    if (index < 0) return false;
    final id = _renderIdOf(index);
    final proj = _controller.registry.logicalById(id)?.projection;
    final p = _controller.registry.byId(id)?.paragraph;
    if (proj == null || p == null || !p.attached) return false;
    final rs = proj.renderOffsetForContent(offset);
    final re = proj.renderOffsetForContent(offset + 1);
    final boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: rs, extentOffset: re),
      boxHeightStyle: ui.BoxHeightStyle.tight,
    );
    final local = p.globalToLocal(global);
    for (final b in boxes) {
      if (b.toRect().inflate(4).contains(local)) return true;
    }
    return false;
  }

  /// 当前文档选区若恰覆盖单个图片原子,返回其选中态(矩形帧后算)。
  ImageAtomSelection? _lastImageAtomSel;

  /// grid 岛内图片子选中(islandId, imageIndex)。与编辑器主选区独立
  /// (点瓦片在自管区内不动主选区);主选区**后续变化**即清(基线快照
  /// 对比 —— 不能用「选区不在岛上」判,点瓦片时主选区本就停在别处)。
  (String, int)? _gridImageSel;
  GridImageSelection? _lastGridImageSel;
  EditorSelection? _gridSelBaseline;

  void _setGridImageSelection(GridImageSelection? sel) {
    final previous = _gridImageSel;
    // 子选图时清掉旧文字选区，避免复制/退格仍作用于之前的内容。
    if (sel != null) widget.state.updateSelection(null);
    _gridImageSel = sel == null ? null : (sel.islandId, sel.imageIndex);
    _gridSelBaseline = sel == null ? null : widget.state.selection;
    if (sel != _lastGridImageSel) {
      _lastGridImageSel = sel;
      widget.onGridImageSelectionChanged?.call(sel);
    }
    if (previous != _gridImageSel) setState(() {}); // 瓦片描边
  }

  /// grid 内瓦片 alt 原位编辑保存:images[index] copyWith(alt) 后
  /// updateIslandNode 原位换。
  void _setGridImageAlt(String islandId, int index, String alt) {
    final i = widget.state.indexOfBlock(islandId);
    if (i < 0) return;
    final block = widget.state.blocks[i];
    if (block is! IslandBlock || block.node is! ImageGridNode) return;
    final grid = block.node as ImageGridNode;
    if (index < 0 || index >= grid.images.length) return;
    final images = [...grid.images];
    images[index] = images[index].copyWith(alt: alt);
    widget.state.updateIslandNode(
      islandId,
      ImageGridNode(
        id: grid.id,
        images: images,
        columns: grid.columns,
        mode: grid.mode,
      ),
    );
  }

  /// grid 内瓦片拖拽排序落地:结构命令重排 + 子选中下标跟随(被拖图
  /// 落位 to;from→to 之间的图让位漂移一格)。
  void _onGridReorder(String islandId, int from, int to) {
    final sel = _gridImageSel;
    if (!reorderImageInGrid(widget.state, islandId, from, to)) return;
    if (sel == null || sel.$1 != islandId) return;
    var s = sel.$2;
    if (s == from) {
      s = to;
    } else if (from < s && s <= to) {
      s -= 1;
    } else if (to <= s && s < from) {
      s += 1;
    }
    if (s != sel.$2) _gridImageSel = (islandId, s);
  }

  ImageAtomSelection? _computeImageAtomSelection() {
    final norm = widget.state.normalizedSelection();
    if (norm == null) return null;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return null;
    if (to.offset != from.offset + 1) return null;
    final block = widget.state.textBlockById(from.blockId);
    if (block == null) return null;
    final atom = block.content.atoms[from.offset];
    if (atom is! ImageRun) return null;

    final index = widget.state.indexOfBlock(from.blockId);
    if (index < 0) return null;
    final id = _renderIdOf(index);
    final proj = _controller.registry.logicalById(id)?.projection;
    final p = _controller.registry.byId(id)?.paragraph;
    if (proj == null || p == null || !p.attached) return null;

    final rs = proj.renderOffsetForContent(from.offset);
    final re = proj.renderOffsetForContent(to.offset);
    final boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: rs, extentOffset: re),
      boxHeightStyle: ui.BoxHeightStyle.tight,
    );
    Rect? rect;
    for (final b in boxes) {
      final tl = p.localToGlobal(Offset(b.left, b.top));
      final br = p.localToGlobal(Offset(b.right, b.bottom));
      if (!tl.dx.isFinite || !br.dx.isFinite) continue;
      final r = Rect.fromPoints(tl, br);
      rect = rect == null ? r : rect.expandToInclude(r);
    }
    if (rect == null) return null;
    return ImageAtomSelection(
      blockId: from.blockId,
      offset: from.offset,
      image: atom,
      globalRect: rect,
    );
  }

  /// [global] 是否落在自管交互区(表格网格)内 —— 命中路径上找
  /// 区域标记 RenderMetaData。
  bool _hitsSelfManagedRegion(Offset global) {
    final rootBox = _rootKey.currentContext?.findRenderObject();
    if (rootBox is! RenderBox || !rootBox.attached) return false;
    final result = BoxHitTestResult();
    rootBox.hitTest(result, position: rootBox.globalToLocal(global));
    for (final entry in result.path) {
      final t = entry.target;
      if (t is RenderMetaData && t.metaData == kEditorSelfManagedRegion) {
        return true;
      }
    }
    return false;
  }

  int _linearOffset(EditorPosition position) {
    var offset = position.offset;
    for (final block in widget.state.blocks) {
      if (block.id == position.blockId) break;
      offset += block.selectionLength + 1;
    }
    return offset;
  }

  EditorSelection _shiftSelection(
    EditorSelection previous,
    EditorPosition target,
  ) {
    final apple =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final nearBase =
        (_linearOffset(target) - _linearOffset(previous.base)).abs() <
        (_linearOffset(target) - _linearOffset(previous.extent)).abs();
    return EditorSelection(
      base: apple && nearBase ? previous.extent : previous.base,
      extent: target,
    );
  }

  EditorSelection? _selectionUnitAtPoint(
    (EditorPosition, TextAffinity) hit,
    Offset global,
    int count,
  ) {
    final atom = _hitTester.atomicRangeAt(
      global,
      position: _toDocumentPosition(hit.$1),
    );
    if (atom != null) {
      final base = _toEditorPosition(atom.start);
      final extent = _toEditorPosition(atom.end);
      if (base != null && extent != null) {
        return EditorSelection(base: base, extent: extent);
      }
    }
    return _selectionUnitAt(hit.$1, hit.$2, count);
  }

  EditorSelection? _selectionUnitAt(
    EditorPosition position,
    TextAffinity affinity,
    int count,
  ) {
    final blockIndex = widget.state.indexOfBlock(position.blockId);
    if (blockIndex >= 0 && widget.state.blocks[blockIndex] is IslandBlock) {
      return EditorSelection(
        base: EditorPosition(blockId: position.blockId, offset: 0),
        extent: EditorPosition(blockId: position.blockId, offset: 1),
      );
    }
    final block = widget.state.textBlockById(position.blockId);
    if (block == null) return null;
    final index = widget.state.indexOfBlock(block.id);
    final hasNext = index + 1 < widget.state.blocks.length;
    EditorPosition local(int offset) => offset > block.content.length && hasNext
        ? EditorPosition(blockId: widget.state.blocks[index + 1].id, offset: 0)
        : EditorPosition(
            blockId: block.id,
            offset: offset.clamp(0, block.content.length),
          );
    if (count == 3 && !_selectionRules.tripleSelectsLine) {
      final text = block.content.text + (hasNext ? '\n' : '');
      final range = _selectionRules.paragraphBoundary(
        text,
        TextPosition(offset: position.offset, affinity: affinity),
      );
      return EditorSelection(
        base: local(range.start),
        extent: local(range.end),
      );
    }
    final doc = _toDocumentPosition(position, affinity: affinity);
    if (doc == null) return null;
    final paragraph = _controller.registry.byId(doc.blockId)?.paragraph;
    if (paragraph == null || !paragraph.attached) return null;
    final geometry = ParagraphGeometry(paragraph);
    final plain = geometry.plainText;
    final at = TextPosition(offset: doc.renderOffset, affinity: affinity);
    if (count == 2 && at.offset >= plain.length && !hasNext) {
      return EditorSelection.collapsed(position);
    }
    if (count == 2 && plain.isEmpty && hasNext) {
      if (defaultTargetPlatform == TargetPlatform.iOS && index > 0) {
        final previous = _adjacentTextWord(index, -1);
        if (previous != null) {
          return EditorSelection(base: previous.base, extent: position);
        }
        final next = _adjacentTextWord(index, 1);
        if (next != null) {
          return EditorSelection(base: position, extent: next.extent);
        }
      }
      return EditorSelection(base: position, extent: local(1));
    }
    var boundary = _selectionRules.wordBoundary(
      geometry,
      at,
      endOfDocument: !hasNext,
    );
    if (count == 3) {
      final caret = paragraph.getOffsetForCaret(
        at,
        const Rect.fromLTWH(0, 0, 2, 20),
      );
      final lineY = caret.dy + _caretLineHeight / 2;
      final left = paragraph
          .getPositionForOffset(Offset(-1000000, lineY))
          .offset;
      final right = paragraph
          .getPositionForOffset(Offset(1000000, lineY))
          .offset;
      boundary = TextRange(
        start: math.min(left, right),
        end: math.max(left, right),
      );
    }
    if (count == 2 && defaultTargetPlatform == TargetPlatform.iOS) {
      final effective = at.offset - (affinity == TextAffinity.upstream ? 1 : 0);
      if ((effective > 0 || index > 0) &&
          effective >= 0 &&
          effective < plain.length &&
          TextLayoutMetrics.isWhitespace(plain.codeUnitAt(effective))) {
        TextRange? previous;
        var cursor = boundary.start;
        while (cursor > 0) {
          final candidate = paragraph.getWordBoundary(
            TextPosition(offset: cursor - 1),
          );
          if (candidate.start >= cursor) break;
          if (plain
              .substring(candidate.start, candidate.end)
              .trim()
              .isNotEmpty) {
            previous = candidate;
            break;
          }
          cursor = candidate.start;
        }
        if (previous != null) {
          boundary = TextRange(start: previous.start, end: at.offset);
        } else {
          final previousBlockWord = _adjacentTextWord(index, -1);
          if (previousBlockWord != null) {
            return EditorSelection(
              base: previousBlockWord.base,
              extent: position,
            );
          }
          var end = boundary.end;
          while (end < plain.length) {
            final next = paragraph.getWordBoundary(TextPosition(offset: end));
            if (next.end <= end) break;
            end = next.end;
            if (plain.substring(next.start, next.end).trim().isNotEmpty) break;
          }
          boundary = TextRange(start: at.offset, end: end);
        }
      }
    }
    final base = _toEditorPosition(
      DocumentPosition(blockId: doc.blockId, renderOffset: boundary.start),
    );
    final extent = _toEditorPosition(
      DocumentPosition(blockId: doc.blockId, renderOffset: boundary.end),
    );
    return base == null || extent == null
        ? null
        : EditorSelection(base: base, extent: extent);
  }

  EditorSelection? _adjacentTextWord(int index, int direction) {
    final blocks = widget.state.blocks;
    for (
      var i = index + direction;
      i >= 0 && i < blocks.length;
      i += direction
    ) {
      final block = blocks[i];
      if (block is! TextBlock) return null;
      final text = block.content.text;
      if (text.trim().isEmpty) continue;
      final offset = direction < 0
          ? text.trimRight().length - 1
          : text.length - text.trimLeft().length;
      return _selectionUnitAt(
        EditorPosition(blockId: block.id, offset: offset),
        TextAffinity.downstream,
        2,
      );
    }
    return null;
  }

  EditorPosition? _dragBase;
  EditorSelection? _dragUnit;
  EditorSelection? _dragStartSelection;
  Offset? _dragGlobal;
  PointerDeviceKind? _dragKind;

  void _onPanStart(TapDragStartDetails details) {
    _pendingTouchTap = null;
    _tapPending = false;
    widget.state.cancelDeferredIrReconcile();
    _tapCount = _effectiveTapCount(details.consecutiveTapCount);
    _dragKind = details.kind;
    final precise =
        details.kind == PointerDeviceKind.mouse ||
        details.kind == PointerDeviceKind.stylus ||
        details.kind == PointerDeviceKind.invertedStylus;
    if (!precise &&
        _tapCount == 1 &&
        (!_focusedAtDown || defaultTargetPlatform == TargetPlatform.iOS)) {
      return;
    }
    if (!precise && _tapCount == 3) {
      return; // Native mobile triple-tap has no drag extension.
    }
    _touchSelection = details.kind != PointerDeviceKind.mouse;
    final hit = _hitAtGlobal(details.globalPosition);
    if (hit == null) return;
    if (details.kind != PointerDeviceKind.mouse &&
        _trySelectImageAtomAt(hit.$1, details.globalPosition, select: false)) {
      _pendingImageTap = null;
      return;
    }
    _dragBase = _shiftPressed ? widget.state.selection?.base ?? hit.$1 : hit.$1;
    _dragUnit = _tapCount > 1
        ? _tapUnit ?? _selectionUnitAt(hit.$1, hit.$2, _tapCount)
        : null;
    _dragStartSelection = widget.state.selection;
    _contextBar?.hide();
    _focusNode.requestFocus();
    _dragGlobal = details.globalPosition;
    _applyPointerDrag(details.globalPosition);
  }

  void _applyPointerDrag(Offset global) {
    final base = _dragBase;
    final hit = _hitAtGlobal(global, selectionBase: base);
    if (base == null || hit == null) return;
    final unit = _dragUnit;
    EditorSelection next;
    if (!_shiftPressed && unit != null) {
      final target = _selectionUnitAtPoint(hit, global, _tapCount);
      if (target == null) return;
      final range = TextSelectionRules.extendUnit(
        anchorStart: unit.base,
        anchorEnd: unit.extent,
        targetStart: target.base,
        targetEnd: target.extent,
        compare: (EditorPosition a, EditorPosition b) =>
            _linearOffset(a).compareTo(_linearOffset(b)),
      );
      next = EditorSelection(base: range.base, extent: range.extent);
    } else if (_shiftPressed) {
      final start = _dragStartSelection;
      final current = widget.state.selection;
      final apple =
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS;
      var anchor = current?.base ?? base;
      if (apple && start != null && !start.isCollapsed) {
        final forward = _linearOffset(start.base) < _linearOffset(start.extent);
        final inverted = forward
            ? _linearOffset(hit.$1) < _linearOffset(start.base)
            : _linearOffset(hit.$1) > _linearOffset(start.base);
        if (inverted && anchor == start.base) {
          anchor = start.extent;
        } else if (!inverted && hit.$1 != start.base && anchor != start.base) {
          anchor = start.base;
        }
      }
      next = EditorSelection(base: anchor, extent: hit.$1);
    } else if (_dragKind == PointerDeviceKind.touch) {
      next = EditorSelection.collapsed(hit.$1);
    } else {
      next = EditorSelection(base: base, extent: hit.$1);
    }
    _caretAffinity = hit.$2;
    widget.state.updateSelection(next, deferIrReconcile: true);
  }

  void _onPanUpdate(TapDragUpdateDetails details) {
    if (_dragBase == null) return;
    _dragGlobal = details.globalPosition;
    _applyPointerDrag(details.globalPosition);
    _updateAutoScroll(details.globalPosition);
    if (details.kind != PointerDeviceKind.mouse) {
      final doc = _hitTester.positionAt(
        details.globalPosition,
        hitTestRoot: _rootKey.currentContext?.findRenderObject(),
      );
      final caret = doc == null
          ? null
          : _hitTester.editingCaretRectAt(doc, lineHeight: _caretLineHeight);
      if (doc != null && caret != null) {
        _showEditorMagnifier(
          gestureGlobal: details.globalPosition,
          caret: caret,
          docPos: doc,
        );
      }
    }
  }

  void _onPanEnd(TapDragEndDetails details) {
    _dragBase = null;
    _dragUnit = null;
    _dragGlobal = null;
    _magnifier?.hide();
    _stopAutoScroll();
    widget.state.commitDeferredIrReconcile();
    _ime.syncFromState(show: false);
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _afterFrame();
    });
  }

  void _onEditingTapOutside(PointerDownEvent event) {
    if (!_focusNode.hasPrimaryFocus) return;
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.fuchsia;
    if (mobile && event.kind == PointerDeviceKind.touch && !kIsWeb) return;
    _dismissTouchSelection();
    // Leaving the editing surface also closes IR's temporary source view.
    // Its offsets are no longer meaningful after delimiters are folded.
    if (widget.state.mode == EditorMode.ir) {
      widget.state.updateSelection(null);
    }
    _focusNode.unfocus();
  }

  // -----------------------------------------------------------------
  // build
  // -----------------------------------------------------------------

  /// 编辑器键盘处理器。命名方法而非闭包:dispose 时需 identical 比对
  /// 后从共享 FocusNode 上摘除(见 dispose 注释)。
  KeyEventResult _editorOnKeyEvent(FocusNode node, KeyEvent event) {
    // 焦点在子树内其他可聚焦组件(表格 cell TextField / 壳内输入)
    // 时**完全让路**:此时 primaryFocus 是那个组件,事件只是沿焦点
    // 链冒泡经过本编辑器 —— 拦截会把退格/方向键/回车吞掉,cell
    // 变成"只能覆盖不能编辑"。
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    // 宿主浮层(斜杠菜单/mention)激活时优先:上下/回车/Esc 归它
    if (widget.keyEventInterceptor?.call(event) ?? false) {
      return KeyEventResult.handled;
    }
    // 非上下键的任何按键动作都终结 goal column 记忆
    if (event is KeyDownEvent &&
        event.logicalKey != LogicalKeyboardKey.arrowUp &&
        event.logicalKey != LogicalKeyboardKey.arrowDown) {
      _verticalGoalX = null;
    }
    // 键盘操作后光标回 downstream(点击行末的 upstream 只对那次点击有效)
    if (event is KeyDownEvent) {
      _caretAffinity = TextAffinity.downstream;
      _touchSelection = false; // 物理键盘操作 → 收触摸选区 UI
    }
    return handleEditorKeyEvent(
      widget.state,
      event,
      onEdited: () => _ime.syncFromState(show: false),
      onMoveVertical: _moveCaretVertical,
      onClipboardCopy: _clipboardCopy,
      onClipboardCut: _clipboardCut,
      onClipboardPaste: _clipboardPaste,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final baseStyle =
        widget.baseTextStyle ??
        Theme.of(context).textTheme.bodyMedium ??
        const TextStyle(fontSize: 14);
    _ensureCaretLineHeight(baseStyle);

    final composingBlockId = state.hasComposing
        ? state.selection?.extent.blockId
        : null;

    // 定界符显形位置(仅 ir 模式,见 [EditorMode]):**只跟随 collapsed
    // 光标**(Vditor 语义)——选区一变 range 立即折叠,选择过程中不
    // 显示任何格式符:
    // - 高亮不会框进定界符(截图实锤:从 mark 首字开始选时 `[spoiler]`
    //   被框了半截);
    // - 折叠回流只发生在 range 出现的第一帧,选区端点是**内容坐标**,
    //   回流后高亮仍指向同一字符不错位;此后整个选择过程布局稳定,
    //   拖拽命中全程在同一布局上进行 —— 这才是丝滑的来源。
    //   (曾用「range 存续期间冻结显形」防回流,方向反了:冻结让
    //   定界符在选择全程杵在文字中间,起点在 mark 内时体验更差。)
    // composing 期间同样不显形(IME 预编辑中 mark 边界随上屏抖动)。
    // 手势进行中不显形(tap 按下未松/手柄/长按/浮动光标/鼠标拖选):
    // 按下即落光标(光标要立刻可见),但展开=松手结算 —— 中途显形
    // 会闪烁,定界符插入还让后续命中坐标漂移。
    final gestureDragging =
        _tapPending ||
        _handleDragging ||
        _longPressing ||
        _floatingCursor ||
        _dragBase != null;
    final revealSelection =
        widget.state.mode == EditorMode.ir &&
            !gestureDragging &&
            _focusNode.hasPrimaryFocus &&
            !state.hasComposing &&
            (state.selection?.isCollapsed ?? false)
        ? state.selection
        : null;

    // 有序列表序号(派生渲染态):连续 listItem run 内扫描,run 首项取
    // listStart;ordered/depth 切换重新起算(同 depth 的 ol 连续编号)。
    final ordinals = List<int>.filled(state.blocks.length, 1);
    final counters = <(bool, int), int>{}; // (ordered,depth) → 下一序号
    for (var i = 0; i < state.blocks.length; i++) {
      final b = state.blocks[i];
      if (b is! TextBlock || !b.isListItem) {
        counters.clear();
        continue;
      }
      final key = (b.ordered, b.depth);
      final next = counters[key] ?? b.listStart;
      ordinals[i] = next;
      counters[key] = next + 1;
      // 更浅层计数不清(嵌套子列表结束回到父层继续编号);更深层清零
      counters.removeWhere((k, _) => k.$2 > b.depth);
    }

    /// 单块 → widget(文本段落/岛)。
    ///
    /// 外层 Padding **必须带 key**:顶层/壳内 Column 的 children 是
    /// keyed(壳)与块混合列表,unkeyed 块会被 updateChildren 按位置
    /// 配对 —— 弹层/插块后旧岛 Padding 与新位置段落 Padding 错配,
    /// child 类型不同导致岛整棵 deactivate 重建(真机 hover/滚动态下
    /// 深层 InheritedElement dependents 清理时序炸 _dependents 断言,
    /// 红屏)。全 keyed 后 diff 恒按身份匹配,块只随真实删除而摘除。
    Widget buildBlockBody(int i) {
      final block = state.blocks[i];
      // 表格岛 + 宿主接了 onTableEdited:cell 级原位编辑网格
      // (不走 EditorIsland 的 AbsorbPointer 只读壳)
      if (block is IslandBlock &&
          block.node is TableNode &&
          widget.onTableEdited != null) {
        return Padding(
          key: ValueKey('blk_${block.id}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: EditorTableGrid(
            key: _islandKeys.putIfAbsent(block.id, GlobalKey.new),
            node: block.node as TableNode,
            autoEdit: widget.state.consumeIslandEditRequest(block.id),
            // 宿主视口底部被键盘/工具栏遮挡的高度:编辑中追加滚动余量,
            // 让内容末尾的表格也有路滚到遮挡区之上(与正文光标 reveal
            // 同一数值口径)。
            viewportBottomInset: widget.caretViewportInsets.bottom,
            onContextMenu: widget.objectToolbarManaged
                ? _requestObjectMenu
                : null,
            onChanged: (md) => widget.onTableEdited!(block, md),
            onNodeChanged: (node) =>
                widget.state.updateIslandNode(block.id, node),
            selected:
                !widget.objectToolbarManaged &&
                _isSingleIslandSelection(block.id),
            // 左上角选择柄:整选表格块(选中后退格/Delete 删整表)。
            // cell 区自管让路后,这是表格作为"块"的唯一选择入口。
            onSelectRequest: () => _selectObject(EditorBlockTarget(block.id)),
          ),
        );
      }
      // 代码块岛 + 宿主接了 onCodeBlockEdited:岛内原位编辑
      // (mermaid 除外 —— 图表块有自己的整块 override 视觉,原位编辑的
      // 展示态会与图表壳冲突,仍走通用岛 + 双击源码)
      if (block is IslandBlock &&
          block.node is CodeBlockNode &&
          (block.node as CodeBlockNode).language != 'mermaid' &&
          widget.onCodeBlockEdited != null) {
        return Padding(
          key: ValueKey('blk_${block.id}'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: EditorCodeBlock(
            key: _islandKeys.putIfAbsent(block.id, GlobalKey.new),
            node: block.node as CodeBlockNode,
            onContextMenu: widget.objectToolbarManaged
                ? _requestObjectMenu
                : null,
            onChanged: (code, lang) =>
                widget.onCodeBlockEdited!(block, code, lang),
            selected:
                !widget.objectToolbarManaged &&
                _isSingleIslandSelection(block.id),
            autoEdit: widget.state.consumeIslandEditRequest(block.id),
            highlightBuilder: _islandFactory.codeBlockHighlighter,
            onSelectRequest: () => _selectObject(EditorBlockTarget(block.id)),
          ),
        );
      }
      return Padding(
        key: ValueKey('blk_${state.blocks[i].id}'),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: switch (state.blocks[i]) {
          // key 绑块 id:分段/合并时 Element 正确复用/重建
          final TextBlock tb => EditableParagraph(
            key: ValueKey(tb.id),
            block: tb,
            documentOrder: i,
            baseStyle: baseStyle,
            composing: tb.id == composingBlockId
                ? state.composing
                : TextRange.empty,
            revealMarkdownAt: revealSelection?.extent.blockId == tb.id
                ? revealSelection!.extent.offset
                : null,
            // ir 字面语法着色:物化字面/手打字面的内容段带格式、定界符
            // 淡色(Vditor「符号可见 + 格式保持」)。
            syntaxHighlight: widget.state.mode == EditorMode.ir,
            listMarkerOrdinal: ordinals[i],
            // 行内图片原子走岛同一图片管线(upload 解析/解码上限);
            // hover=click(可点选)。注意:builder 产物进 flatten 缓存
            // (content 不变不重跑),不能在闭包里读选中态等易变状态
            // ——不会刷新,还误导性能分析。
            imageContentBuilder: _islandFactory.imageContentBuilder == null
                ? null
                : (ctx, img, total) => MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: _islandFactory.imageContentBuilder!(ctx, img, total),
                  ),
            // emoji 原子同走宿主管线(CDN 重写/缓存池;不接的话编辑
            // 已有帖的相对 URL emoji 全裂成 :name: 占位胶囊)
            emojiImageBuilder: _islandFactory.emojiImageBuilder,
          ),
          // 孤岛:NodeFactory 渲染,tap 整选,双击请求编辑,选中态描边
          final IslandBlock ib => EditorIsland(
            key: _islandKeys.putIfAbsent(ib.id, GlobalKey.new),
            node: ib.node,
            nodeFactory: _islandFactory,
            selected:
                !widget.objectToolbarManaged && _isSingleIslandSelection(ib.id),
            showInsertHandles: !widget.objectToolbarManaged,
            onContextMenu:
                (widget.onObjectContextMenuRequest == null &&
                    widget.onObjectMenuRequested == null)
                ? null
                : _requestObjectMenu,
            onSecondaryMenu: (position) =>
                _secondaryObjectMenu(EditorBlockTarget(ib.id), position),
            onTapSelect: () => _selectObject(EditorBlockTarget(ib.id)),
            onEditRequest: widget.onIslandEditRequest == null
                ? null
                : () => widget.onIslandEditRequest!(ib),
            // 选中态上下缘「加段」把手:岛前/后建空段落光标(首块是
            // 岛/岛在尾时移动端唯一的加段途径;状态层已有同语义命令)
            onInsertParagraph: ({required bool before}) {
              final idx = widget.state.indexOfBlock(ib.id);
              if (idx < 0) return;
              widget.state.placeCaretBesideObject(ib.id, after: !before);
              _ime.syncFromState();
            },
            // grid 岛内容换官方 composer 内聚交互视图:模式切换/移除
            // 网格/瓦片删除/移出/alt 全内聚(纯结构命令,宿主只管
            // 查看器);瓦片单击子选中
            contentOverride: ib.node is ImageGridNode
                ? EditorImageGrid(
                    key: _gridKeys.putIfAbsent(
                      ib.id,
                      () => GlobalKey<EditorImageGridState>(),
                    ),
                    onSecondaryMenu: widget.onObjectMenuRequested == null
                        ? null
                        : (image, position) => _secondaryObjectMenu(
                            EditorGridImageTarget(
                              ib.id,
                              image.imageIndex,
                              image.image.src,
                            ),
                            position,
                          ),
                    node: ib.node as ImageGridNode,
                    onAddImages: widget.onAddGridImages == null
                        ? null
                        : () => widget.onAddGridImages!(ib.id),
                    addingImages: widget.addingImageGrids.contains(ib.id),
                    pendingUploads:
                        widget.gridPendingUploadsBuilder?.call(
                          context,
                          ib.id,
                        ) ??
                        const [],
                    controlSurfaceBuilder: widget.gridControlSurfaceBuilder,
                    onImageMenu: widget.onObjectMenuRequested == null
                        ? null
                        : (image, anchor) {
                            _setGridImageSelection(image);
                            if (widget.onObjectMenuRequested != null) {
                              widget.onObjectMenuRequested!(
                                EditorObjectMenuRequest(
                                  target: EditorGridImageTarget(
                                    ib.id,
                                    image.imageIndex,
                                    image.image.src,
                                  ),
                                  globalAnchorRect: anchor,
                                  transient: true,
                                ),
                              );
                            } else {
                              _requestObjectMenu();
                            }
                          },
                    islandId: ib.id,
                    showSelectionControls: !widget.objectToolbarManaged,
                    onContextMenu:
                        widget.onObjectMenuRequested != null ||
                            widget.onObjectContextMenuRequest != null
                        ? _requestObjectMenu
                        : null,
                    onSelectGrid: widget.objectToolbarManaged
                        ? () {
                            _selectObject(EditorBlockTarget(ib.id));
                            _requestObjectMenu();
                          }
                        : null,
                    nodeFactory: _islandFactory,
                    selectedIndex: (_gridImageSel?.$1 == ib.id)
                        ? _gridImageSel!.$2
                        : null,
                    onImageTap: _setGridImageSelection,
                    onImageOpen: (sel) =>
                        widget.onGridImageOpenRequest?.call(sel),
                    onModeChange: (mode) =>
                        setImageGridMode(widget.state, ib.id, mode),
                    onRemoveGrid: () => removeImageGrid(widget.state, ib.id),
                    onRemoveImage: (index) =>
                        removeImageFromGrid(widget.state, ib.id, index),
                    onMoveImageOut: (index) =>
                        moveImageOutsideGrid(widget.state, ib.id, index),
                    onAltChanged: (index, alt) =>
                        _setGridImageAlt(ib.id, index, alt),
                    onReorder: (from, to) => _onGridReorder(ib.id, from, to),
                  )
                : null,
          ),
        },
      );
    }

    Widget buildBlockContent(int i) {
      final block = state.blocks[i];
      final transient = widget.transientBlockBuilder?.call(context, block);
      if (transient != null) return transient;
      final content = buildBlockBody(i);
      if (block is! IslandBlock) return content;
      return SelectableObjectBlock(
        key: ValueKey('blk_${block.id}'),
        documentOrder: i,
        text: '\uFFFC',
        isolateChildren: true,
        paintSelection: !_isSingleIslandSelection(block.id),
        child: content,
      );
    }

    Widget buildBlock(int i) {
      final block = state.blocks[i];
      final selected =
          widget.objectToolbarManaged &&
          (_explicitObjectTarget == EditorBlockTarget(block.id) ||
              _explicitObjectTarget == null &&
                  block is IslandBlock &&
                  _isSingleIslandSelection(block.id));
      return EditorObjectFrame(
        onLayout: _scheduleObjectGeometry,
        key: _blockKeys.putIfAbsent(block.id, GlobalKey.new),
        selected: selected,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            buildBlockContent(i),
            if (widget.emptyParagraphHint != null &&
                block is TextBlock &&
                block.content.length == 0 &&
                _focusNode.hasFocus &&
                state.selection?.isCollapsed == true &&
                state.selection?.extent.blockId == block.id)
              Positioned.fill(
                child: IgnorePointer(
                  child: Padding(
                    padding: EdgeInsets.only(
                      top:
                          4 +
                          (block.isHeading
                              ? (baseStyle.fontSize ?? 16) *
                                    kHeadingMargin[block.headingLevel - 1] /
                                    2
                              : 0),
                      left: block.isListItem
                          ? (baseStyle.fontSize ?? 16) * 1.5 * (block.depth + 1)
                          : 0,
                    ),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: KeyedSubtree(
                        key: widget.emptyParagraphHintKey,
                        child: Text(
                          widget.emptyParagraphHint!,
                          key: const ValueKey('editor-empty-paragraph-hint'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (block.isHeading
                                      ? headingStyleFor(
                                          baseStyle,
                                          block.headingLevel,
                                        )
                                      : baseStyle)
                                  .copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                  ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    /// 递归分组(M5-B):`[from, to)` 内容器栈深度 [level] 上的分组渲染。
    /// 相邻块 containers[level] 相等 → 同容器实例,包 EditorContainerShell
    /// 后递归下一层;无该层帧 → 直接渲染块本体。
    List<Widget> buildLevel(int from, int to, int level) {
      final out = <Widget>[];
      var i = from;
      while (i < to) {
        final b = state.blocks[i];
        final frames = b is TextBlock ? b.containers : const <ContainerFrame>[];
        if (frames.length > level) {
          final frame = frames[level];
          final runStart = i;
          while (i < to) {
            final c = state.blocks[i];
            final cf = c is TextBlock ? c.containers : const <ContainerFrame>[];
            if (cf.length > level && cf[level] == frame) {
              i++;
            } else {
              break;
            }
          }
          out.add(
            Padding(
              // 容器壳自身与外界的间距(块本体的 vertical 4 在壳内)。
              // key 在 Padding 上(children 列表的直接成员必须 keyed,
              // 见 buildBlock 注释)。
              // 同一容器被孤岛分割后可能有多个不连续片段；身份需与
              // 下方 _containerKeys 一致，不能只按 groupId 复用。
              key: ValueKey(
                'shell_${frame.groupId}_${state.blocks[runStart].id}_$level',
              ),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: EditorObjectFrame(
                onLayout: _scheduleObjectGeometry,
                key: _containerKeys.putIfAbsent((
                  frame.groupId,
                  state.blocks[runStart].id,
                ), GlobalKey.new),
                selected:
                    _explicitObjectTarget is EditorContainerTarget &&
                    (_explicitObjectTarget as EditorContainerTarget).groupId ==
                        frame.groupId &&
                    resolveEditorObject(state, _explicitObjectTarget!)?.start ==
                        runStart,
                child: EditorContainerShell(
                  frame: frame,
                  onContextMenu: widget.onObjectSelectionChanged == null
                      ? null
                      : () {
                          _selectObject(
                            EditorContainerTarget(
                              state.blocks[runStart].id,
                              frame.groupId,
                            ),
                          );
                          _requestObjectMenu();
                        },
                  onTitleTap:
                      widget.onContainerTitleEdit != null &&
                          (frame is DetailsFrame || frame is CalloutFrame)
                      ? () => widget.onContainerTitleEdit!(frame)
                      : null,
                  children: buildLevel(runStart, i, level + 1),
                ),
              ),
            ),
          );
          continue;
        }
        out.add(buildBlock(i));
        i++;
      }
      return out;
    }

    final children = buildLevel(0, state.blocks.length, 0);
    if (widget.showTrailingParagraph) {
      children.add(
        MouseRegion(
          key: const ValueKey('editor-trailing-paragraph'),
          cursor: SystemMouseCursors.text,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _continueAfterDocument,
            child: Semantics(
              button: true,
              label: '继续输入',
              child: SizedBox(
                height: 72,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '点击此处继续输入',
                    style: baseStyle.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withValues(alpha: .65),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final content = Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _editorOnKeyEvent,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        // RawGestureDetector 按输入设备分流(阅读端 selection_gesture_layer
        // 同款口径):
        // - tap:全设备(落光标/图原子选中/双击选词);
        // - pan 拖选:**仅鼠标按键拖动** —— 触控板双指 pan/zoom 和
        //   触摸的 pan 不进竞技场，触控板按住点击拖动仍上报 mouse。
        //   竖向滑动完全让给宿主滚动(此前触屏滚页面被编辑器拦成拖选);
        //   回调里判 kind 早退没用,recognizer 赢了竞技场滚动照样被劫持,
        //   必须构造期 supportedDevices 分流;
        // - 长按:仅触摸/触控笔(选词 + 放大镜 + 手柄,系统编辑器惯例)。
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(debugOwner: this),
                  (r) => r..onSecondaryTapUp = _onSecondaryTapUp,
                ),
            RegionTapAndPanGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  RegionTapAndPanGestureRecognizer
                >(
                  () => RegionTapAndPanGestureRecognizer(
                    debugOwner: this,
                    supportedDevices:
                        defaultTargetPlatform == TargetPlatform.iOS
                        ? const {}
                        : const {PointerDeviceKind.mouse},
                    canStartAt: (point) =>
                        !_hitsSelfManagedRegion(point) &&
                        !_hitsIslandRegion(point),
                  ),
                  (r) => r
                    ..dragStartBehavior = DragStartBehavior.down
                    ..eagerVictoryOnDrag =
                        defaultTargetPlatform != TargetPlatform.iOS
                    ..onTapTrackStart = _onTapTrackStart
                    ..onTapTrackReset = _onTapTrackReset
                    ..onTapDown = _onTapDown
                    ..onTapUp = _onTapUp
                    ..onCancel = _onTapCancel
                    ..onDragStart = _onPanStart
                    ..onDragUpdate = _onPanUpdate
                    ..onDragEnd = _onPanEnd,
                ),
            RegionTapAndHorizontalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  RegionTapAndHorizontalDragGestureRecognizer
                >(
                  () => RegionTapAndHorizontalDragGestureRecognizer(
                    debugOwner: this,
                    supportedDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.invertedStylus,
                      PointerDeviceKind.unknown,
                      if (defaultTargetPlatform == TargetPlatform.iOS)
                        PointerDeviceKind.mouse,
                    },
                    canStartAt: (point) =>
                        !_hitsSelfManagedRegion(point) &&
                        !_hitsIslandRegion(point),
                  ),
                  (r) => r
                    ..dragStartBehavior = DragStartBehavior.down
                    ..eagerVictoryOnDrag =
                        defaultTargetPlatform != TargetPlatform.iOS
                    ..onTapTrackStart = _onTapTrackStart
                    ..onTapTrackReset = _onTapTrackReset
                    ..onTapDown = _onTapDown
                    ..onTapUp = _onTapUp
                    ..onCancel = _onTapCancel
                    ..onDragStart = _onPanStart
                    ..onDragUpdate = _onPanUpdate
                    ..onDragEnd = _onPanEnd,
                ),
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    debugOwner: this,
                    supportedDevices: const {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.invertedStylus,
                    },
                  ),
                  (r) => r
                    ..onLongPressStart = _onLongPressStart
                    ..onLongPressMoveUpdate = _onLongPressMoveUpdate
                    ..onLongPressEnd = _onLongPressEnd
                    ..onLongPressCancel = _finishLongPress,
                ),
            // 三指文本编辑手势(撤销/重做/复制/剪切/粘贴)。
            // 源码模式走原生 TextField 白拿这些,富文本自绘必须自己识别。
            // 与上面三个单指/指针识别器不冲突(它只接 touch 且要求 3 指)。
            ThreeFingerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  ThreeFingerGestureRecognizer
                >(
                  () => ThreeFingerGestureRecognizer(
                    debugOwner: this,
                    onGesture: _onThreeFingerGesture,
                  ),
                  (r) => r.onGesture = _onThreeFingerGesture,
                ),
          },
          child: SelectionScope(
            controller: _controller,
            child: Stack(
              key: _rootKey,
              // Clip.none:表格块选择柄/列柄等悬挂装饰 top:-6/left:-2 挂在
              // 块边界外(不同于列表圆点在块内左 padding 区),hardEdge 会
              // 把它们裁掉(被切)。外层滚动区 12px padding 吸收溢出;宽
              // 表格由自身横向 scroll 裁剪,不会外溢盖工具栏。
              clipBehavior: Clip.none,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
                ValueListenableBuilder<(Rect?, int)>(
                  valueListenable: _caretInfo,
                  builder: (context, info, _) => EditorCaret(
                    caretRect: info.$1,
                    // 浮动光标期间 = 灰色吸附残影、常亮不闪(iOS 系统
                    // 同款:浮动 caret 跟手,原位灰 caret 停在吸附位;
                    // EditableText backgroundCursorColor 同语义)。
                    color: _floatingCursor
                        ? Theme.of(context).colorScheme.outline
                        : Theme.of(context).colorScheme.primary,
                    alwaysVisible: state.hasComposing || _floatingCursor,
                    moveGeneration: info.$2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return TextFieldTapRegion(
      onTapOutside: _onEditingTapOutside,
      child: content,
    );
  }
}
