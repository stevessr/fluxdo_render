/// 自研选区手势层 —— 顶层 RawGestureDetector,按设备分流:
/// - 触摸/触控笔:LongPress 起选(词粒度拖扩) + TapAndHorizontalDrag 连击
///   (单击清除/toggle、双击选词、三击选段 + 双击拖词扩)。
/// - 鼠标:TapAndPan(tap-down 定位 + 双击选词 / 三击选段 + drag 扩展)。
///
/// 设计依据 Flutter SDK SelectableRegion(selectable_region.dart):
/// - 触摸 tap 走 SDK TapAndHorizontalDragGestureRecognizer 获得 consecutiveTapCount
///   (SDK :683-715);双击选词/拖词扩对齐 _startNewMouseSelectionGesture case 2 +
///   _handleMouseDragUpdate case 2。
/// - 长按 = 选词 + 拖动按 **word 粒度** 扩(SDK _handleTouchLongPressStart/
///   MoveUpdate,granularity: TextGranularity.word)。
/// - iOS 长按/双击**按下**即显托柄,Android 松手才显(SDK :1005-1010)。
/// - iOS 单击已有选区 = toggle 工具栏(SDK _handleMouseTapUp :938)。
///
/// 页面横向翻页的竞技场让路仍由本层保留；计数、文本边界和单位扩选
/// 与编辑态共享 TextSelectionRules，通过 surface 参数表达原生差异。
library;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart' show HapticFeedback, HardwareKeyboard;
import 'package:flutter/widgets.dart';

import 'hit_tester.dart';
import 'selection_auto_scroller.dart';
import 'selection_data.dart';
import 'selection_exporter.dart';
import 'selection_geometry.dart';
import 'selection_registry.dart';
import 'text_selection_rules.dart';

class SelectionGestureLayer extends StatefulWidget {
  const SelectionGestureLayer({
    super.key,
    required this.controller,
    required this.onSelectionChanged,
    this.onHandlesShowRequest,
    this.onToolbarToggleRequest,
    required this.child,
  });

  final SelectionController controller;

  /// 选区稳定(松手)/ 清除时触发,把 SelectionData 交给上层(弹 toolbar 等)。
  final SelectionResultCallback onSelectionChanged;

  /// 选区已产生但尚未定选(iOS 长按/双击**按下**时)→ 上层立即显示托柄
  /// (无 toolbar)。对齐 SDK :1008-1009 / _startNewMouseSelectionGesture case 2。
  final VoidCallback? onHandlesShowRequest;

  /// iOS 单击落在已有选区上 → 上层 toggle 工具栏显隐(对齐 SDK :938)。
  final VoidCallback? onToolbarToggleRequest;

  final Widget child;

  @override
  State<SelectionGestureLayer> createState() => _SelectionGestureLayerState();
}

class _SelectionGestureLayerState extends State<SelectionGestureLayer>
    with AutomaticKeepAliveClientMixin {
  SelectionHitTester get _hit => SelectionHitTester(widget.controller.registry);
  SelectionExporter get _exporter =>
      SelectionExporter(widget.controller.registry);

  /// 本次选区是否由触摸/长按产生(决定上层是否显示移动端拖拽手柄)。
  bool _lastInputWasTouch = false;
  PointerDeviceKind? _pointerKind;
  bool _shiftPressed = false;
  TextSelectionRules get _rules =>
      TextSelectionRules(defaultTargetPlatform, TextSelectionSurface.readOnly);
  bool get _canShiftExtend =>
      _shiftPressed &&
      widget.controller.selection != null &&
      ![
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ].contains(defaultTargetPlatform);
  void _onTapTrackStart() =>
      _shiftPressed = HardwareKeyboard.instance.isShiftPressed;
  void _onTapTrackReset() => _shiftPressed = false;
  void _cancelSelection() {
    _endDrag();
    _clear();
  }

  /// 拖拽进行中(drag/longPress 起→止)。期间:① 保活本 chunk(滚出视口也不
  /// 被回收,recognizer 不死);② 滚动时按钉住的指针位置 re-extend。
  bool _isDragging = false;
  bool _longPressActive = false;

  /// 最后一次指针全局坐标(滚轮滚动时用它在新内容上重算 extent)。
  Offset? _lastDragGlobal;

  /// 词/段粒度拖扩的锚定单元(长按/双击的初始词、三击的初始段)。拖动扩选时
  /// 选区永远包含它,越过它向回选时 base/extent 换端(对齐 SDK word granularity
  /// 的 SelectionEdgeUpdateEvent 语义)。
  ({DocumentPosition start, DocumentPosition end})? _dragAnchor;

  /// 拖扩粒度是否按段落边界(三击拖);false = 按词(长按/双击拖)。
  bool _dragByParagraph = false;

  /// 祖先 Scrollable 的滚动位置(订阅它驱动滚轮扩选)。
  ScrollPosition? _scrollPosition;

  /// 祖先 Scrollable。
  ScrollableState? _scrollable;

  /// 统一边缘自动滚(外层页面 + 拖拽点所在块的内部滚动器,如代码块横滚)。
  /// 移动端无滚轮,跨视口/横向溢出内容的拖选全靠它;桌面拖到边缘也可。
  SelectionEdgeAutoScroller? _autoScroller;

  @override
  bool get wantKeepAlive => _isDragging;

  /// 起拖:记坐标 + 保活(鼠标 onDragStart / 触摸 onLongPressStart 调)。
  void _beginDrag(Offset global) {
    _lastDragGlobal = global;
    if (!_isDragging) {
      _isDragging = true;
      updateKeepAlive();
    }
  }

  /// 止拖:停保活(松手后,若无选区则本 chunk 可回收)+ 停自动滚动。
  void _endDrag() {
    _autoScroller?.stop();
    if (_isDragging) {
      _isDragging = false;
      updateKeepAlive();
    }
    _lastDragGlobal = null;
  }

  /// 拖拽中:指针靠近「页面视口」或「所在块内部滚动器」(代码块横滚等)的
  /// 边缘则自动滚动(配合 [_onScroll]/onScrolled 让 extent 跟随)。
  void _maybeAutoScroll(Offset global) {
    _autoScroller?.update(global);
  }

  /// 滚动中(滚轮 / 自动滚动)且正在拖拽:鼠标钉在原位、内容在底下滚,用钉住的
  /// 全局坐标重跑扩选 → 命中新滚入内容 → extent 跟着扩(= 滚动扩选)。
  /// 对齐 Flutter _ScrollableSelectionContainerDelegate「滚动按指针重算端点」。
  void _onScroll() {
    final g = _lastDragGlobal;
    if (!_isDragging || g == null) return;
    if (_dragAnchor != null) {
      _extendRangedTo(g);
    } else {
      _extendTo(g);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅**祖先** Scrollable(同 SelectionContentLayer:祖先 ScrollNotification
    // 不冒泡到后代,改用 position 这个 Listenable)。
    final scrollable = Scrollable.maybeOf(context);
    final pos = scrollable?.position;
    if (pos != _scrollPosition) {
      _scrollPosition?.removeListener(_onScroll);
      _scrollPosition = pos;
      _scrollPosition?.addListener(_onScroll);
    }
    if (scrollable != _scrollable || _autoScroller == null) {
      _scrollable = scrollable;
      _autoScroller?.stop();
      _autoScroller = SelectionEdgeAutoScroller(
        registry: widget.controller.registry,
        outerScrollable: scrollable,
        // 内部滚动器(代码块横滚)滚动一步后:其 position 不是 _scrollPosition,
        // 不会触发 _onScroll,这里显式按钉住的指针 re-extend(滚动扩选)。
        onScrolled: _onScroll,
      );
    }
  }

  @override
  void dispose() {
    _autoScroller?.stop();
    _scrollPosition?.removeListener(_onScroll);
    super.dispose();
  }

  void _clear() {
    _dragAnchor = null;
    if (widget.controller.selection != null) {
      widget.controller.clear();
      widget.onSelectionChanged(null, fromTouch: _lastInputWasTouch);
    }
  }

  // ── 设备无关的核心动作(触摸/鼠标共用)──────────────────────────

  /// 文档序比较(先块序,再块内渲染偏移)。
  static int _comparePositions(DocumentPosition a, DocumentPosition b) {
    final c = a.blockId.compareTo(b.blockId);
    return c != 0 ? c : a.renderOffset.compareTo(b.renderOffset);
  }

  /// The renderer supplies its exact text offsets for both RichText and the
  /// cached paragraph path. Never fabricate a UTF-16 character on an empty hit.
  ({DocumentPosition start, DocumentPosition end})? _wordRangeAt(
    Offset global,
  ) {
    final pos = _hit.positionAt(
      global,
      hitTestRoot: context.findRenderObject(),
    );
    if (pos == null) return null;
    final atom = _hit.atomicRangeAt(global, position: pos);
    if (atom != null) return atom;
    final geometry = widget.controller.registry.byId(pos.blockId)?.geometry;
    if (geometry == null || !geometry.isLive) return null;
    final range = _rules.wordBoundary(
      geometry,
      TextPosition(offset: pos.renderOffset, affinity: pos.affinity),
    );
    return (
      start: pos.copyWith(renderOffset: range.start),
      end: pos.copyWith(renderOffset: range.end),
    );
  }

  ({DocumentPosition start, DocumentPosition end})? _paragraphRangeAt(
    Offset global,
  ) {
    final pos = _hit.positionAt(
      global,
      hitTestRoot: context.findRenderObject(),
    );
    if (pos == null) return null;
    final atom = _hit.atomicRangeAt(global, position: pos);
    if (atom != null) return atom;
    final geometry = widget.controller.registry.byId(pos.blockId)?.geometry;
    if (geometry == null || !geometry.isLive) return null;
    final range = _rules.paragraphBoundary(
      geometry.plainText,
      TextPosition(offset: pos.renderOffset, affinity: pos.affinity),
    );
    return (
      start: pos.copyWith(renderOffset: range.start),
      end: pos.copyWith(renderOffset: range.end),
    );
  }

  /// 起选:选中所在「词」(￼ 上则整颗 emoji/mention),并记为拖扩锚定单元。
  /// 返回是否成功起选。
  bool _startWordAt(Offset global) {
    final word = _wordRangeAt(global);
    if (word == null) {
      _clear();
      return false;
    }
    _dragAnchor = word;
    _dragByParagraph = false;
    widget.controller.selection = DocumentSelection(
      base: word.start,
      extent: word.end,
    );
    return true;
  }

  /// 折叠定位(鼠标单击 / drag 起点):光标态,后续 drag 扩展。
  void _collapseAt(Offset global) {
    final pos = _hit.positionAt(
      global,
      hitTestRoot: context.findRenderObject(),
    );
    if (pos == null) {
      _clear();
      return;
    }
    _dragAnchor = null;
    widget.controller.selection = DocumentSelection.collapsed(pos);
  }

  /// 整段选中(三击),并记为拖扩锚定单元。
  void _selectParagraphAt(Offset global) {
    final block = _paragraphRangeAt(global);
    if (block == null) {
      _startWordAt(global);
      return;
    }
    _dragAnchor = block;
    _dragByParagraph = true;
    widget.controller.selection = DocumentSelection(
      base: block.start,
      extent: block.end,
    );
  }

  /// 扩展 extent(base 锚不动,字符粒度 —— 鼠标拖选用)。
  void _extendTo(Offset global) {
    final current = widget.controller.selection;
    if (current == null) return;
    final pos = _hit.positionAt(
      global,
      selectionBase: current.base,
      hitTestRoot: context.findRenderObject(),
    );
    if (pos == null) return;
    widget.controller.selection = current.copyWith(extent: pos);
  }

  /// 按锚定单元(词/块)粒度扩选:选区永远包含锚定单元;拖过锚定单元另一侧时
  /// base/extent 自然换端(向回选)。复现 SDK
  /// `SelectionEdgeUpdateEvent(granularity: word/paragraph)` 的语义。
  void _extendRangedTo(Offset global) {
    final anchor = _dragAnchor;
    if (anchor == null) {
      _extendTo(global);
      return;
    }
    final unit = _dragByParagraph
        ? _paragraphRangeAt(global)
        : _wordRangeAt(global);
    if (unit == null) return;
    final range = TextSelectionRules.extendUnit(
      anchorStart: anchor.start,
      anchorEnd: anchor.end,
      targetStart: unit.start,
      targetEnd: unit.end,
      compare: _comparePositions,
    );
    widget.controller.selection = DocumentSelection(
      base: range.base,
      extent: range.extent,
    );
  }

  /// 松手定选:有实际选区则导出弹 toolbar,否则清除。
  void _finish() {
    final sel = widget.controller.selection;
    if (sel == null || sel.isCollapsed) {
      _clear();
      return;
    }
    widget.onSelectionChanged(
      _exporter.export(sel),
      fromTouch: _lastInputWasTouch,
    );
  }

  /// 全局点是否落在当前选区高亮矩形内(iOS 单击选区 toggle 工具栏用)。
  bool _positionIsOnSelection(Offset global) {
    final sel = widget.controller.selection;
    if (sel == null || sel.isCollapsed) return false;
    final data = _exporter.export(sel);
    if (data == null) return false;
    for (final r in data.globalRects) {
      if (r.contains(global)) return true;
    }
    return false;
  }

  int _effectiveTapCount(int raw) => _rules.tapCount(raw, _pointerKind);

  // ── 触摸:长按(词粒度)──────────────────────────────────────
  void _onLongPressStart(LongPressStartDetails d) {
    _longPressActive = true;
    _lastInputWasTouch = true;
    _beginDrag(d.globalPosition);
    if (_startWordAt(d.globalPosition)) {
      // 长按起选震动(对齐系统文本选区)。
      HapticFeedback.selectionClick();
      // iOS 长按即显托柄;Android 松手才显(SDK :1005-1010)。
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        widget.onHandlesShowRequest?.call();
      }
    }
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails d) {
    _lastDragGlobal = d.globalPosition;
    final before = widget.controller.selection?.extent;
    // 词粒度扩选(对齐 SDK _handleTouchLongPressMoveUpdate 的
    // granularity: TextGranularity.word)。
    _extendRangedTo(d.globalPosition);
    // 拖动跨到新位置才震动(不每帧震)。
    if (widget.controller.selection?.extent != before) {
      HapticFeedback.selectionClick();
    }
    _maybeAutoScroll(d.globalPosition);
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    _longPressActive = false;
    _finish();
    _endDrag();
  }

  void _cancelLongPress() {
    if (!_longPressActive) return;
    _longPressActive = false;
    _cancelSelection();
  }

  // ── 鼠标:TapAndPan ────────────────────────────────────────
  // tap-down 按连击数分发:1=折叠定位,2=选词,3=选段。drag 起点已由
  // tap-down 定位,drag-update 扩展,drag-end 定选。
  void _onMouseTapDown(TapDragDownDetails d) {
    _lastInputWasTouch = false;
    _pointerKind = d.kind;
    final count = _effectiveTapCount(d.consecutiveTapCount);
    switch (count) {
      case 1:
        if (_canShiftExtend) {
          _dragAnchor = null;
          _extendTo(d.globalPosition);
        } else if (![
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.fuchsia,
        ].contains(defaultTargetPlatform)) {
          _collapseAt(d.globalPosition);
        }
      case 2:
        _startWordAt(d.globalPosition);
      default:
        _selectParagraphAt(d.globalPosition);
    }
  }

  void _onMouseTapUp(TapDragUpDetails d) {
    if (_toggleToolbarOnSelection(d.globalPosition)) return;
    // 单击(无 drag)落定:折叠选区无内容 → 清除 + 收 toolbar;
    // 双击/三击已选中内容 → 导出弹 toolbar。
    final count = _effectiveTapCount(d.consecutiveTapCount);
    if (count == 1 && !_canShiftExtend) {
      _clear();
    } else {
      _finish();
    }
  }

  void _onMouseDragStart(TapDragStartDetails d) {
    _beginDrag(d.globalPosition);
    final count = _effectiveTapCount(d.consecutiveTapCount);
    if (count == 1) {
      _collapseAt(d.globalPosition);
    } else if (_dragAnchor == null) {
      if (count == 2) {
        _startWordAt(d.globalPosition);
      } else {
        _selectParagraphAt(d.globalPosition);
      }
    }
  }

  void _onMouseDragUpdate(TapDragUpdateDetails d) {
    _lastDragGlobal = d.globalPosition;
    if (_dragAnchor != null) {
      _extendRangedTo(d.globalPosition);
    } else {
      _extendTo(d.globalPosition);
    }
    _maybeAutoScroll(d.globalPosition);
  }

  void _onMouseDragEnd(TapDragEndDetails d) {
    _finish();
    _endDrag();
  }

  // ── 触摸:连击(单击清除/toggle、双击选词、三击选段、双/三击拖扩)────
  void _onTouchTapDown(TapDragDownDetails d) {
    _lastInputWasTouch = true;
    _pointerKind = d.kind;
    final count = _effectiveTapCount(d.consecutiveTapCount);
    switch (count) {
      case 1:
        // 移动端单击的选区处理在 tap-up(对齐 SDK「selection is set on tap up」)。
        break;
      case 2:
        if (_startWordAt(d.globalPosition)) {
          // iOS 双击按下即显托柄(SDK _startNewMouseSelectionGesture case 2)。
          if (defaultTargetPlatform == TargetPlatform.iOS) {
            widget.onHandlesShowRequest?.call();
          }
        }
      default:
        if (_rules.supportsTripleTap(d.kind)) {
          _selectParagraphAt(d.globalPosition);
        }
    }
  }

  void _onTouchTapUp(TapDragUpDetails d) {
    final count = _effectiveTapCount(d.consecutiveTapCount);
    if (_toggleToolbarOnSelection(d.globalPosition)) return;
    if (count == 1) {
      _clear();
    } else {
      // 双击/三击松手:定选弹 toolbar(Android 此刻一并显托柄,
      // 对齐 SDK _handleMouseTapUp case 2)。
      _finish();
    }
  }

  bool _toggleToolbarOnSelection(Offset global) {
    if (defaultTargetPlatform != TargetPlatform.iOS ||
        !_positionIsOnSelection(global)) {
      return false;
    }
    widget.onToolbarToggleRequest?.call();
    return true;
  }

  void _onTouchDragStart(TapDragStartDetails d) {
    // 触摸单击拖 = 滚动,不进选区(SDK「Drag to select is only enabled with a
    // precise pointer device」);双/三击拖 = 词/段粒度扩选。
    final count = _effectiveTapCount(d.consecutiveTapCount);
    if (count < 2 || (count == 3 && !_rules.supportsTripleTap(d.kind))) return;
    _beginDrag(d.globalPosition);
  }

  void _onTouchDragUpdate(TapDragUpdateDetails d) {
    final count = _effectiveTapCount(d.consecutiveTapCount);
    if (count < 2 || (count == 3 && !_rules.supportsTripleTap(d.kind))) return;
    _lastDragGlobal = d.globalPosition;
    final before = widget.controller.selection?.extent;
    _extendRangedTo(d.globalPosition);
    if (widget.controller.selection?.extent != before) {
      HapticFeedback.selectionClick();
    }
    _maybeAutoScroll(d.globalPosition);
  }

  void _onTouchDragEnd(TapDragEndDetails d) {
    if (_isDragging) _finish();
    _endDrag();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin:拖拽期间保活本 chunk
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        // 鼠标:tap 连击 + drag 选区；触控板 pan/zoom 留给滚动。
        RegionTapAndPanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              RegionTapAndPanGestureRecognizer
            >(
              () => RegionTapAndPanGestureRecognizer(
                debugOwner: this,
                supportedDevices: const {PointerDeviceKind.mouse},
              ),
              (r) {
                r
                  ..onTapTrackStart = _onTapTrackStart
                  ..onTapTrackReset = _onTapTrackReset
                  ..onCancel = _cancelSelection
                  ..onTapDown = _onMouseTapDown
                  ..onTapUp = _onMouseTapUp
                  ..onDragStart = _onMouseDragStart
                  ..onDragUpdate = _onMouseDragUpdate
                  ..onDragEnd = _onMouseDragEnd
                  ..dragStartBehavior = DragStartBehavior.down;
              },
            ),
        // 触摸/触控笔:长按起选 + 词粒度拖拽扩展
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                debugOwner: this,
                supportedDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                },
              ),
              (r) {
                r
                  ..onLongPressStart = _onLongPressStart
                  ..onLongPressMoveUpdate = _onLongPressMoveUpdate
                  ..onLongPressEnd = _onLongPressEnd
                  ..onLongPressCancel = _cancelLongPress;
              },
            ),
        // 触摸连击:单击清除/toggle、双击选词、三击选段、双/三击拖扩
        // (对齐 SDK 的 TapAndHorizontalDragGestureRecognizer :683-715)。
        RegionTapAndHorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              RegionTapAndHorizontalDragGestureRecognizer
            >(
              () => RegionTapAndHorizontalDragGestureRecognizer(
                debugOwner: this,
                supportedDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                },
              ),
              (r) {
                r
                  // SDK 仅 iOS false;我们全平台 false:详情页外层有 AI 横滑
                  // PageView,eager 抢横向拖会吃掉翻页手势(有意偏离)。
                  ..eagerVictoryOnDrag = false
                  ..onTapTrackStart = _onTapTrackStart
                  ..onTapTrackReset = _onTapTrackReset
                  ..onCancel = _cancelSelection
                  ..onTapDown = _onTouchTapDown
                  ..onTapUp = _onTouchTapUp
                  ..onDragStart = _onTouchDragStart
                  ..onDragUpdate = _onTouchDragUpdate
                  ..onDragEnd = _onTouchDragEnd
                  ..dragStartBehavior = DragStartBehavior.down;
              },
            ),
      },
      child: widget.child,
    );
  }
}
