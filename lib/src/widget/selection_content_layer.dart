/// 选区内容层 —— 把手势层 + toolbar 组合,挂在 FluxdoRender 顶层。
///
/// 手势层产出 SelectionData(松手/清除时);本层据此弹/收子包自带 toolbar,
/// 并把「引用」回调透传给主项目、「复制」在 toolbar 内走 Clipboard。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kTouchSlop;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../selection/selection_auto_scroller.dart';
import '../selection/selection_data.dart';
import '../selection/selection_exporter.dart';
import '../selection/selection_gesture_layer.dart';
import '../selection/selection_handles.dart';
import '../selection/selection_navigator.dart';
import '../selection/selection_registry.dart';
import '../selection/selection_toolbar.dart';

class SelectionContentLayer extends StatefulWidget {
  const SelectionContentLayer({
    super.key,
    required this.controller,
    required this.onQuoteRequest,
    required this.onCopyQuoteRequest,
    required this.onCopyToast,
    required this.child,
    this.onDecryptRequest,
    this.decryptTextDetector,
    this.chunkIndex = 0,
  });

  final SelectionController controller;
  final QuoteRequestCallback? onQuoteRequest;
  final QuoteRequestCallback? onCopyQuoteRequest;
  final CopyToastCallback? onCopyToast;

  /// 「解密」回调与密文特征判定(主项目注入;null 时 toolbar 不显示该按钮)
  final DecryptRequestCallback? onDecryptRequest;
  final DecryptTextDetector? decryptTextDetector;
  final Widget child;

  /// 本层所在 chunk 的文档序号(整帖渲染为 0)。用于尺寸变化后判断「本层是否
  /// 选区归属层」(选区 base 所在 chunk),只让归属层在 State 被重建后重弹
  /// toolbar → 避免多个 toolbar。
  final int chunkIndex;

  @override
  State<SelectionContentLayer> createState() => _SelectionContentLayerState();
}

class _SelectionContentLayerState extends State<SelectionContentLayer>
    with WidgetsBindingObserver {
  SelectionToolbar? _toolbar;
  SelectionHandlesController? _handles;

  /// 接收键盘事件的焦点节点 —— 不 autofocus(避免抢主项目焦点),点选/长按产出
  /// 选区时 requestFocus,后续 Cmd/Ctrl+A、Shift+方向 才进得来。
  final FocusNode _focusNode = FocusNode(debugLabel: 'fluxdo_selection');

  /// 祖先 Scrollable 的滚动位置(监听它驱动 toolbar 跟随)。
  ScrollPosition? _scrollPosition;

  /// 上次滚动像素值,用于算单帧 delta 给 toolbar 做滞后补偿(消滚动抖动)。
  double _lastScrollPixels = 0;

  /// 托柄拖动的边缘自动滚(外层页面 + 拖拽点所在块的内部滚动器,如代码块
  /// 横滚)。SDK 托柄拖出视口边缘会自动滚(每个 Scrollable 的
  /// _ScrollableSelectionContainerDelegate 自滚自轴),这里同语义:滚动一步
  /// 后 reapplyDrag 按钉住的拖拽点重新命中 → 选区跟着扩。
  SelectionEdgeAutoScroller? _handleAutoScroller;

  SelectionExporter get _exporter =>
      SelectionExporter(widget.controller.registry);

  @override
  void initState() {
    super.initState();
    // 监听 controller:被全局协调器(其他帖起选)外部清空时,收掉本帖 toolbar
    // + 手柄;手柄拖动改选区时刷新手柄/toolbar 位置。
    widget.controller.addListener(_onControllerChanged);
    // 失焦清选区(对齐 SDK SelectableRegion._handleFocusChanged :521-542):
    // 弹框/路由 push 时其 FocusScope 抢焦 → 本层失焦 → 清选区收浮层,
    // 根治「工具栏/托柄浮在弹框上面」。
    _focusNode.addListener(_onFocusChanged);
    // 监听窗口/视口尺寸变化(见 didChangeMetrics)。
    WidgetsBinding.instance.addObserver(this);
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) return;
    // 仅前台失焦才清(对齐 SDK:app 切后台的失焦不清,回前台选区仍在)。
    if (SchedulerBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      widget.controller.clear();
    }
  }

  /// 窗口/视口尺寸变化(桌面拖窗口、分屏、旋转、键盘等):内容重排后,选区的
  /// 逻辑位置不变、高亮(每块 CustomPaint)随尺寸自动重画;但 toolbar/手柄是
  /// 绝对定位 overlay。这里在重排完成后(post-frame)按新几何重弹/重定位它们 ——
  /// **选区保留不清**。
  ///
  /// 注意用 `show`(非 `reposition`):reposition 复用冻结的水平位置 `_cachedLeft`
  /// (为消滚动左右抖),resize 后内容重新居中、该缓存失效,必须 `show` 重算;
  /// 且若归属层的 State 被分块重建丢了 toolbar(reposition 因 _entry==null 失效),
  /// 由「选区 base 所在 chunk」的本层重建并显示(判 chunkIndex 防多个 toolbar)。
  @override
  void didChangeMetrics() {
    if (widget.controller.selection == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sel = widget.controller.selection;
      if (sel == null) return;
      final data = _exporter.export(sel);
      if (data == null) return;
      if (_toolbar != null) {
        _toolbar!.show(data); // 重置缓存 + 重定位(_entry 已在则只 markNeedsBuild)
      } else if (sel.base.blockId.chunkIndex == widget.chunkIndex) {
        // 本层是归属层但 toolbar 随 State 重建丢了 → 重建并显示。
        _toolbar = _buildToolbar();
        _toolbar!.show(data);
      }
      _handles?.update();
    });
  }

  void _onControllerChanged() {
    // 任何选区变化都先收掉本层 toolbar:跨 chunk 起新选区时,旧 chunk 只收到本
    // controller 通知(不会走自己的 _onSelectionChanged),若不收掉旧 toolbar 会
    // 残留 → 屏幕上同时出现两个 toolbar。本层若是新选区的归属者,稍后由手势的
    // _onSelectionChanged 重新弹出。
    _toolbar?.hide();
    _toolbar = null;
    if (widget.controller.selection == null) {
      _handles?.hide();
    } else {
      // 选区变(含手柄拖动):刷新手柄位置。
      _handles?.update();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 监听**祖先** Scrollable —— 不能用 NotificationListener(实测:祖先
    // Scrollable 的 ScrollNotification 不冒泡到后代,收不到)。改用
    // Scrollable.of(context).position(Listenable),滚动时直接 notify。
    final scrollable = Scrollable.maybeOf(context);
    final pos = scrollable?.position;
    if (pos != _scrollPosition) {
      _scrollPosition?.removeListener(_onScroll);
      _scrollPosition = pos;
      _lastScrollPixels = pos?.pixels ?? 0;
      _scrollPosition?.addListener(_onScroll);
    }
    if (_handleAutoScroller == null ||
        _handleAutoScroller!.outerScrollable != scrollable) {
      _handleAutoScroller?.stop();
      _handleAutoScroller = SelectionEdgeAutoScroller(
        registry: widget.controller.registry,
        outerScrollable: scrollable,
        // 滚动一步后按钉住的拖拽点重新命中(外层滚动另有 _onScroll 跟随
        // toolbar/手柄;内部滚动器滚动只能靠这里驱动扩选)。
        onScrolled: () => _handles?.reapplyDrag(),
      );
    }
  }

  void _onSelectionChanged(SelectionData? data, {bool fromTouch = false}) {
    _toolbar?.hide();
    _toolbar = null;
    if (data == null) {
      _handles?.hide();
      return;
    }
    // 选区产生 → 抢键盘焦点,后续 Cmd/Ctrl+A、Shift+方向 才进得来。
    _focusNode.requestFocus();
    // 移动端(触摸选区)显示拖拽手柄;鼠标/触控板选区不显示。
    if (fromTouch) {
      _ensureHandles().show();
    } else {
      _handles?.hide();
    }
    // 对齐 Flutter #182663：先手柄后菜单，溢出菜单必须在手柄上层。
    // 菜单浮层由 SDK ContextMenuController 管理，避免自行复制其生命周期。
    _toolbar = _buildToolbar();
    _toolbar!.show(data);
  }

  /// 手柄控制器(懒建,两处共用:定选显示 / iOS 长按按下即显)。
  SelectionHandlesController _ensureHandles() {
    return _handles ??= SelectionHandlesController(
      context: context,
      controller: widget.controller,
      // 拖手柄时隐藏 toolbar(不挡视线/放大镜),松手后按新选区重定位重显。
      onDragStart: () => _toolbar?.hide(),
      // 拖拽点移动:驱动边缘自动滚(页面纵滚 + 代码块横滚等内部滚动器)。
      onDragMove: (global) => _handleAutoScroller?.update(global),
      onDragEnd: () {
        _handleAutoScroller?.stop();
        _reshowToolbarForCurrentSelection();
      },
    );
  }

  /// iOS 长按/双击**按下**即显托柄(无 toolbar,对齐 SDK :1005-1009);
  /// Android 仍在松手 [_onSelectionChanged] 时显示。
  void _showHandlesEarly() {
    if (widget.controller.selection == null) return;
    _focusNode.requestFocus();
    _ensureHandles().show();
  }

  /// iOS 单击落在已有选区上 → toggle 工具栏显隐(对齐 SDK :938)。
  void _toggleToolbar() {
    if (widget.controller.selection != null) _focusNode.requestFocus();
    if (_toolbar != null) {
      _toolbar!.hide();
      _toolbar = null;
    } else {
      _reshowToolbarForCurrentSelection();
    }
  }

  /// toolbar「全选」:全选后移动端**保持** toolbar/手柄并按新选区重定位,
  /// 桌面收起 toolbar(对齐 SDK contextMenuButtonItems onSelectAll :1723-1729)。
  void _handleSelectAll() {
    SelectionNavigator.selectAll(widget.controller);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        _reshowToolbarForCurrentSelection();
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        _toolbar?.hide();
        _toolbar = null;
    }
  }

  /// 构建 toolbar(复制 / 全选 / 复制引用 / 引用 / ProcessText)。两处显示
  /// 共用,避免回调漂移。引用/复制引用回调未注入时(未登录等)对应按钮隐藏。
  SelectionToolbar _buildToolbar() {
    return SelectionToolbar(
      context: context,
      // 与内容同 groupId:点 toolbar 不触发 onTapOutside 清除。
      tapRegionGroupId: widget.controller,
      onSelectAll: _handleSelectAll,
      // ProcessText 动作执行完毕 → 清选区(对齐 SDK 执行后收 toolbar)。
      onProcessTextDone: () => widget.controller.clear(),
      onQuote: widget.onQuoteRequest == null
          ? null
          : (plainText) {
              widget.onQuoteRequest!.call(plainText);
              widget.controller.clear();
            },
      onCopyQuote: widget.onCopyQuoteRequest == null
          ? null
          : (plainText) {
              widget.onCopyQuoteRequest!.call(plainText);
              widget.controller.clear();
            },
      onDecrypt: widget.onDecryptRequest == null
          ? null
          : (plainText) {
              widget.onDecryptRequest!.call(plainText);
              widget.controller.clear();
            },
      decryptTextDetector: widget.decryptTextDetector,
      onCopied: () {
        widget.onCopyToast?.call();
        widget.controller.clear(); // 复制后清选区(与引用/复制引用一致)
      },
    );
  }

  /// 复制当前选区到剪贴板(Cmd/Ctrl+C)。与 toolbar「复制」同口径:选区覆盖
  /// 完整代码块时带 ```` ```lang ````。复制后**保留选区**(桌面习惯,不清除)。
  void _copySelection() {
    final sel = widget.controller.selection;
    if (sel == null) return;
    final data = _exporter.export(sel);
    if (data == null || data.clipboardText.isEmpty) return;
    final code = data.code;
    final text = code != null
        ? '```${code.language ?? ''}\n${data.plainText}\n```'
        : data.clipboardText;
    Clipboard.setData(ClipboardData(text: text));
    widget.onCopyToast?.call();
  }

  /// 按当前选区重新构建并显示 toolbar(手柄拖动松手后用)。
  void _reshowToolbarForCurrentSelection() {
    final sel = widget.controller.selection;
    final data = sel == null ? null : _exporter.export(sel);
    if (data == null) return;
    _toolbar?.hide();
    _toolbar = _buildToolbar();
    _toolbar!.show(data);
  }

  /// 滚动时:toolbar + 手柄按当前选区重算几何并重定位。
  ///
  /// **滞后补偿**:本回调在 scroll 的 transient 阶段触发(pixels 已更新、但本帧
  /// viewport 还没 layout 到新位置),此刻 export 读到的是**上一帧**几何;而内容
  /// 本帧会 paint 到新位置。差值正好 = 本次 scroll 的 delta。把 delta 交给
  /// toolbar 预平移 → 与内容**同帧对齐**,消除滚动抖动。
  void _onScroll() {
    final pos = _scrollPosition;
    final px = pos?.pixels ?? 0;
    final delta = px - _lastScrollPixels;
    _lastScrollPixels = px;
    final sel = widget.controller.selection;
    if (sel == null) return;
    _toolbar?.reposition(_exporter.export(sel), yCompensation: delta);
    _handles?.update(yCompensation: delta);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onControllerChanged);
    _scrollPosition?.removeListener(_onScroll);
    _handleAutoScroller?.stop();
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _toolbar?.hide();
    _handles?.hide();
    super.dispose();
  }

  /// 触摸 outside 按下点(判"滚动 or 点击"):TapRegion 的 onTapOutside 在
  /// **pointer-down** 即触发且不进手势竞技场 —— 移动端在选区外按下手指想滚动,
  /// down 一落就清选区(未滚先清)。对齐系统行为(SelectableRegion 触摸清选区
  /// 走 tap **up**):触摸设备改在 onTapUpOutside 清,且 down→up 位移 ≤
  /// kTouchSlop 才算"点击"(超出 = 滚动/拖拽,不清)。鼠标保持 down 即清。
  Offset? _touchOutsideDownPosition;

  @override
  Widget build(BuildContext context) {
    // TapRegion:点选区/toolbar(同 groupId)**之外**的任意处 → 清除选区。
    // groupId 用本 controller 实例,各 post 独立组;toolbar 的 OverlayEntry 也
    // 用同 groupId(见 SelectionToolbar),故点 toolbar 不算 outside。
    return _wrapKeyboard(
      TapRegion(
        groupId: widget.controller,
        onTapOutside: (event) {
          if (widget.controller.selection == null) return;
          if (event.kind == PointerDeviceKind.mouse ||
              event.kind == PointerDeviceKind.trackpad) {
            // 精确指针:按下即清(桌面习惯,与系统一致)。
            widget.controller.clear();
          } else {
            // 触摸/触控笔:先记按下点,抬手再判(见 onTapUpOutside)。
            _touchOutsideDownPosition = event.position;
          }
        },
        onTapInside: (_) {
          // down 落在区内 → 清掉上一次"down 在外、up 在内"残留的按下点,
          // 防止它与后续某次 upOutside 误配对。
          _touchOutsideDownPosition = null;
        },
        onTapUpOutside: (event) {
          final down = _touchOutsideDownPosition;
          _touchOutsideDownPosition = null;
          if (down == null || widget.controller.selection == null) return;
          // 位移在 slop 内 = 真·点击空白 → 清;超出 = 滚动/拖拽 → 保留选区。
          if ((event.position - down).distance <= kTouchSlop) {
            widget.controller.clear();
          }
        },
        child: SelectionGestureLayer(
          controller: widget.controller,
          onSelectionChanged: _onSelectionChanged,
          onHandlesShowRequest: _showHandlesEarly,
          onToolbarToggleRequest: _toggleToolbar,
          child: widget.child,
        ),
      ),
    );
  }

  /// 在内容外包一层 Focus + Shortcuts/Actions:绑定 Cmd/Ctrl+A 全选、
  /// Cmd/Ctrl+C 复制选区、Shift+左右逐字符扩选、Shift+上下逐行扩选。
  ///
  /// 用现代 [Shortcuts]/[Actions](非废弃的 RawKeyboard);平台键修饰用
  /// [SingleActivator] 的 meta(macOS ⌘)/ control(其他平台)分支。Focus 不
  /// autofocus,选区产生时由 [_onSelectionChanged] 显式 requestFocus。
  Widget _wrapKeyboard(Widget child) {
    final useMeta = defaultTargetPlatform == TargetPlatform.macOS;
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        // Cmd/Ctrl+A 全选
        if (useMeta)
          const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
              const _SelectAllIntent()
        else
          const SingleActivator(LogicalKeyboardKey.keyA, control: true):
              const _SelectAllIntent(),
        // Cmd/Ctrl+C 复制选区
        if (useMeta)
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
              const _CopyIntent()
        else
          const SingleActivator(LogicalKeyboardKey.keyC, control: true):
              const _CopyIntent(),
        // Shift+方向 扩展选区
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
            const _ExtendByCharacterIntent(forward: true),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
            const _ExtendByCharacterIntent(forward: false),
        const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
            const _ExtendByLineIntent(down: true),
        const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
            const _ExtendByLineIntent(down: false),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SelectAllIntent: CallbackAction<_SelectAllIntent>(
            onInvoke: (_) {
              SelectionNavigator.selectAll(widget.controller);
              _reshowToolbarForCurrentSelection();
              return null;
            },
          ),
          _CopyIntent: CallbackAction<_CopyIntent>(
            onInvoke: (_) {
              _copySelection();
              return null;
            },
          ),
          _ExtendByCharacterIntent: CallbackAction<_ExtendByCharacterIntent>(
            onInvoke: (intent) {
              SelectionNavigator.moveExtentByCharacter(
                widget.controller,
                forward: intent.forward,
              );
              _reshowToolbarForCurrentSelection();
              return null;
            },
          ),
          _ExtendByLineIntent: CallbackAction<_ExtendByLineIntent>(
            onInvoke: (intent) {
              SelectionNavigator.moveExtentByLine(
                widget.controller,
                down: intent.down,
              );
              _reshowToolbarForCurrentSelection();
              return null;
            },
          ),
        },
        child: Focus(focusNode: _focusNode, child: child),
      ),
    );
  }
}

/// 全选 Intent(Cmd/Ctrl+A)。
class _SelectAllIntent extends Intent {
  const _SelectAllIntent();
}

/// 复制选区 Intent(Cmd/Ctrl+C)。
class _CopyIntent extends Intent {
  const _CopyIntent();
}

/// 逐字符扩选 Intent(Shift+左右)。
class _ExtendByCharacterIntent extends Intent {
  const _ExtendByCharacterIntent({required this.forward});
  final bool forward;
}

/// 逐行扩选 Intent(Shift+上下)。
class _ExtendByLineIntent extends Intent {
  const _ExtendByLineIntent({required this.down});
  final bool down;
}
