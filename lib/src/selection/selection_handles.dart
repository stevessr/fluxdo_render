/// 移动端选区拖拽手柄 —— 选区两端的把手,可拖动调整选区范围;拖动时联动放大镜。
///
/// 架构(借鉴 super_editor,简化):单一数据源 [SelectionController];手柄位置永远
/// 由「当前选区端点全局锚点」(SelectionExporter.endpointAnchors)派生,不另存坐标。
/// 复用 Flutter 系统的 buildHandle/getHandleAnchor/getHandleSize(纯绘制函数,
/// 可脱离 SelectableRegion 单独用),定位+拖动用 Positioned + GestureDetector 自管。
///
/// 拖动:命中文本得新 DocumentPosition → 固定另一端、动被拖端;越过另一端时
/// base/extent 自然交换(由 orderedEndpoints 视觉序归一化吸收)。
library;

import 'package:flutter/cupertino.dart' show cupertinoTextSelectionControls;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'hit_tester.dart';
import 'selection_exporter.dart';
import 'selection_geometry.dart';
import 'selection_magnifier.dart';
import 'selection_range.dart';
import 'selection_registry.dart';

class SelectionHandlesController {
  SelectionHandlesController({
    required this.context,
    required this.controller,
    this.onDragStart,
    this.onDragMove,
    this.onDragEnd,
  }) : _hit = SelectionHitTester(controller.registry),
       _exporter = SelectionExporter(controller.registry),
       _magnifier = SelectionMagnifier(context);

  final BuildContext context;
  final SelectionController controller;

  /// 手柄开始拖动 —— 上层据此隐藏 toolbar(拖动中不挡视线)。
  final VoidCallback? onDragStart;

  /// 拖拽点移动上报(全局坐标,已含「端点锚起步 + 手势 delta 累加」)。
  /// 上层驱动边缘自动滚用;不接不影响既有行为。
  final ValueChanged<Offset>? onDragMove;

  /// 手柄结束拖动 —— 上层据此按新选区重新定位显示 toolbar。
  final VoidCallback? onDragEnd;

  final SelectionHitTester _hit;
  final SelectionExporter _exporter;
  final SelectionMagnifier _magnifier;

  OverlayEntry? _entry;
  // 拖动中:被拖的是哪个端(视觉 start / end),拖动期间固定另一端。
  _DragSide? _dragging;

  /// 拖动开始时锁定的「固定端」(另一端的文档位置),整个拖动期间不变。
  /// 不每帧从当前 selection 重算,否则拖过另一端后固定端会漂移、手柄错位、
  /// 无法向回选。松手清空。
  DocumentPosition? _fixedAnchor;

  /// 拖拽点(全局)—— 对齐 SDK SelectableRegion(_handleSelectionEndHandleDrag*):
  /// 起拖时 = **被拖端点的文本锚点**(box 底角),之后累加手势 delta,而非直接用
  /// 手指坐标。手指按在手柄图形上、低于文本行一整行,直接 hit-test 手指位置会
  /// 命中下一行 → extent 永远落在固定端之后,无法向回反选。
  Offset _dragPosition = Offset.zero;

  /// 被拖端点所在行高。命中点 = _dragPosition 上移半行(行中心),
  /// 对齐 SDK 的 `- Offset(0, lineHeight / 2)` 补偿;跨行时随 extent 刷新。
  double _dragLineHeight = 0;

  /// 被拖端点的当前文档位置(拖动中随命中刷新)。放大镜的 caret/行边界
  /// 几何按它实时取。
  DocumentPosition? _dragDocPosition;

  /// 上一帧成功计算的端点锚。拖动中几何瞬时不可得时兜底(见 [_build]),
  /// 防止把正在拖拽的手柄摘树。
  SelectionEndpoints? _lastBuiltAnchors;

  /// 竖直滞后补偿(本帧 scroll delta)——滚动时 endpointAnchors 几何滞后一帧,
  /// _build 把手柄竖直坐标减去它 → 与内容同帧对齐,消滚动抖动。拖动/显示时归零。
  double _yComp = 0;

  bool get isShowing => _entry != null;

  /// 显示手柄(选区存在时)。重复调 = 刷新位置。
  void show() {
    if (controller.selection == null) return;
    _yComp = 0;
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _entry = OverlayEntry(builder: _build);
    overlay.insert(_entry!);
  }

  /// 选区变了 / 滚动了 → 刷新手柄位置。[yCompensation] = 本帧 scroll delta
  /// (滚动跟随时由上层传入,消一帧滞后抖动;选区变化等非滚动场景传 0)。
  void update({double yCompensation = 0}) {
    _yComp = yCompensation;
    _entry?.markNeedsBuild();
  }

  void hide() {
    _magnifier.hide();
    _entry?.remove();
    _entry = null;
    _dragging = null;
    _fixedAnchor = null;
    _lastBuiltAnchors = null;
  }

  Widget _build(BuildContext ctx) {
    final sel = controller.selection;
    var anchors = (sel == null || sel.isCollapsed)
        ? null
        : _exporter.endpointAnchors(sel);
    if (anchors == null) {
      // 拖动中几何瞬时不可得(两端重合 collapsed / 端点块离屏)→ 沿用上一帧
      // 锚点,**绝不返回 shrink 摘树**:摘树会 dispose 正在拖拽的
      // GestureDetector,onPanEnd/onPanCancel 都不会再来 → 拖拽死亡 +
      // 放大镜永久残留(SDK 手柄 overlay 拖动期同样常驻,collapsed 只换类型)。
      if (_dragging == null || _lastBuiltAnchors == null) {
        return const SizedBox.shrink();
      }
      anchors = _lastBuiltAnchors!;
    } else {
      _lastBuiltAnchors = anchors;
    }

    final controls = Theme.of(context).platform == TargetPlatform.iOS
        ? cupertinoTextSelectionControls
        : materialTextSelectionControls;

    // 与内容/toolbar 同 groupId(= controller):点手柄不触发 onTapOutside 清除。
    return TapRegion(
      groupId: controller,
      child: Stack(
        children: [
          _handle(
            ctx,
            controls,
            _DragSide.start,
            anchors.start,
            anchors.startLineHeight,
          ),
          _handle(
            ctx,
            controls,
            _DragSide.end,
            anchors.end,
            anchors.endLineHeight,
          ),
        ],
      ),
    );
  }

  Widget _handle(
    BuildContext ctx,
    TextSelectionControls controls,
    _DragSide side,
    Offset anchorGlobal,
    double lineHeight,
  ) {
    // start 手柄用 left 类型(把手在文字左下),end 用 right。
    final type = side == _DragSide.start
        ? TextSelectionHandleType.left
        : TextSelectionHandleType.right;
    final handleAnchor = controls.getHandleAnchor(type, lineHeight);
    final size = controls.getHandleSize(lineHeight);

    // overlay 局部坐标(overlay 通常铺满屏 → 全局即局部)。
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final local = overlayBox == null
        ? anchorGlobal
        : overlayBox.globalToLocal(anchorGlobal);

    // 命中区放大到 ≥44px(手指友好),手柄绘制居中其中。
    // top 减 _yComp:抵消滚动时几何的一帧滞后 → 手柄与内容同帧对齐(消抖)。
    const touch = 44.0;
    final left = local.dx - handleAnchor.dx - (touch - size.width) / 2;
    final top = local.dy - handleAnchor.dy - (touch - size.height) / 2 - _yComp;

    return Positioned(
      left: left,
      top: top,
      width: touch.clamp(size.width, double.infinity),
      height: touch.clamp(size.height, double.infinity),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: (d) => _onDragStart(side, d.globalPosition),
        onPanUpdate: (d) => _onDragUpdate(d.delta),
        onPanEnd: (_) => _onDragEnd(),
        // PointerCancel(如系统手势/来电抢占)不走 onPanEnd —— 不收会导致
        // 放大镜永久残留在 Overlay(对齐 SDK dispose 中 hideMagnifier 注释)。
        onPanCancel: _onDragEnd,
        child: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: controls.buildHandle(ctx, type, lineHeight, null),
          ),
        ),
      ),
    );
  }

  void _onDragStart(_DragSide side, Offset global) {
    _dragging = side;
    // 锁定另一端为固定锚点(拖 start → 固定 visualEnd,拖 end → 固定 visualStart),
    // 整个拖动期间不变 → 支持向回选(拖过另一端)时固定端不漂移。
    final sel = controller.selection;
    final ends = sel == null ? null : _exporter.orderedEndpoints(sel);
    _fixedAnchor = ends == null
        ? null
        : (side == _DragSide.start ? ends.visualEnd : ends.visualStart);
    // 被拖端的初始文档位置(放大镜 caret/行几何按它取)。
    _dragDocPosition = ends == null
        ? null
        : (side == _DragSide.start ? ends.visualStart : ends.visualEnd);
    // 拖拽点初始化为**被拖端点的文本锚点**(非手指位置)——手指按在手柄图形上,
    // 在文本行下方一整行,直接用手指坐标 hit-test 会命中下一行(对齐 SDK
    // _handleSelectionEndHandleDragStart 用 selectionPoint.localPosition)。
    final anchors = sel == null ? null : _exporter.endpointAnchors(sel);
    if (anchors != null) {
      _dragPosition = side == _DragSide.start ? anchors.start : anchors.end;
      _dragLineHeight = side == _DragSide.start
          ? anchors.startLineHeight
          : anchors.endLineHeight;
    } else {
      _dragPosition = global;
      _dragLineHeight = 0;
    }
    _yComp = 0; // 拖动不是滚动,无滞后补偿
    HapticFeedback.selectionClick();
    _showMagnifierAtDragPosition();
    onDragStart?.call();
    onDragMove?.call(_dragPosition);
  }

  /// 用当前拖拽点重新命中一次。边缘自动滚每帧滚动后调:拖拽点全局
  /// 不动、内容已滚过,被拖端应随之继续走(否则只滚屏不扩选)。
  /// 非拖动中 no-op。
  void reapplyDrag() {
    if (_dragging == null) return;
    _onDragUpdate(Offset.zero);
  }

  void _onDragUpdate(Offset delta) {
    final fixed = _fixedAnchor;
    if (_dragging == null || fixed == null) return;
    // 累加手势 delta(对齐 SDK:dragPosition += details.delta),命中点上移
    // 半行指向**行中心** → 拖到哪行选到哪行,且可越过固定端向回反选。
    _dragPosition += delta;
    onDragMove?.call(_dragPosition);
    final hitPoint = _dragPosition - Offset(0, _dragLineHeight / 2);
    final pos = _hit.positionAt(hitPoint, selectionBase: fixed);
    if (pos == null) return;

    // 拖到与固定端**重合**(collapsed)或相邻块边界零宽 → 跳过本帧,选区保持
    // ≥1 字符(对齐系统手柄不可折叠行为)。若放行空选区,_build 无锚可用,
    // 且松手后会残留一个"看不见的选区"。放大镜照常跟随。
    final candidate = DocumentSelection(base: fixed, extent: pos);
    if (candidate.isCollapsed ||
        expandSelection(controller.registry, candidate).isEmpty) {
      _showMagnifierAtDragPosition();
      return;
    }

    // 固定锚点作 base、被拖端 pos 作 extent。pos 越过 base(向回选)时
    // DocumentSelection 自然反向,下次 build 的 orderedEndpoints 归一视觉序。
    final prevExtent = controller.selection?.extent;
    controller.selection = candidate;
    _dragDocPosition = pos;
    // 跨到新位置才震动(不每帧震),对齐系统文本选区拖拽反馈。
    if (prevExtent != pos) HapticFeedback.selectionClick();
    // 跨行后行高可能变(标题↔正文),按新 extent 刷新补偿量。
    final caret = _hit.caretRectAt(pos);
    if (caret != null && caret.height > 0) _dragLineHeight = caret.height;
    _yComp = 0; // 拖动改选区,几何当前,无需补偿
    _showMagnifierAtDragPosition(caretRect: caret);
    _entry?.markNeedsBuild();
  }

  /// 放大镜:喂 SDK MagnifierInfo 四字段(对齐 SelectableRegion
  /// _buildInfoForMagnifier):
  /// - globalGesturePosition = 拖拽点(X 跟手;iOS 下拖过远自动隐藏);
  /// - caretRect = 被拖端 caret 全局矩形(焦点锁**行中心**,指文字不指手指);
  /// - currentLineBoundaries = 该行横向扩到被拖端所在段落全宽(Material 镜子
  ///   X 夹在行内);
  /// - fieldBounds = 本 chunk 内容区全局矩形(Material 焦点 X 不出内容区)。
  void _showMagnifierAtDragPosition({Rect? caretRect}) {
    final caret =
        caretRect ??
        ((_dragDocPosition != null
                ? _hit.caretRectAt(_dragDocPosition!)
                : null) ??
            Rect.fromCenter(
              center: _dragPosition - Offset(0, _dragLineHeight / 2),
              width: 0,
              height: _dragLineHeight,
            ));

    // 内容区全局矩形(SelectionContentLayer 的 RenderBox);取不到时退化为
    // caret 所在行(放大镜仍可用,仅 X 夹边失去段落语义)。
    Rect fieldBounds = caret;
    final contentBox = context.findRenderObject();
    if (contentBox is RenderBox && contentBox.attached && contentBox.hasSize) {
      final tl = contentBox.localToGlobal(Offset.zero);
      if (tl.dx.isFinite && tl.dy.isFinite) {
        fieldBounds = tl & contentBox.size;
      }
    }

    // 被拖端所在段落的全局横向范围 → 行边界。段落不可见时用内容区宽度。
    Rect lineBoundaries = Rect.fromLTRB(
      fieldBounds.left,
      caret.top,
      fieldBounds.right,
      caret.bottom,
    );
    final pos = _dragDocPosition;
    final geometry = pos == null
        ? null
        : controller.registry.byId(pos.blockId)?.geometry;
    if (geometry != null && geometry.isLive) {
      final tl = geometry.renderBox.localToGlobal(Offset.zero);
      if (tl.dx.isFinite && tl.dy.isFinite) {
        lineBoundaries = Rect.fromLTRB(
          tl.dx,
          caret.top,
          tl.dx + geometry.renderBox.size.width,
          caret.bottom,
        );
      }
    }

    _magnifier.show(
      gestureGlobal: _dragPosition,
      caretRect: caret,
      currentLineBoundaries: lineBoundaries,
      fieldBounds: fieldBounds,
      // Android 镜内不映托柄(shouldDisplayHandlesInMagnifier=false → 插到
      // 托柄 entry 之下);iOS 相反,SelectionMagnifier 内部按配置忽略 below。
      below: _entry,
    );
  }

  void _onDragEnd() {
    _dragging = null;
    _fixedAnchor = null;
    _dragDocPosition = null;
    _magnifier.hide();
    _entry?.markNeedsBuild();
    // 通知上层按新选区重新定位并显示 toolbar(拖动中被隐藏了)。
    onDragEnd?.call();
  }
}

enum _DragSide { start, end }
