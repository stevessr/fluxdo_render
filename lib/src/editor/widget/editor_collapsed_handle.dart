/// collapsed 光标拖柄(移动端单手柄)—— 触摸落光标后光标下方的水滴把手,
/// 拖动微调光标位置。
///
/// 与选区双手柄(SelectionHandlesController)同一套绘制/命中哲学:系统
/// TextSelectionControls 纯绘制函数 + Overlay Positioned + 自管手势;但
/// 数据流不同 —— collapsed 锚点由编辑器喂(光标矩形从 EditorState 派生,
/// 阅读端 DocumentSelection 没有 collapsed 概念),拖动只上报拖拽点
/// (锚点起步 + 手势 delta 累加,与双手柄同款补偿),命中/选区更新/
/// 放大镜全在编辑器侧,控制器不碰文档模型。
///
/// iOS 不创建(见 [platformHasHandle]):系统 collapsed 手柄在 iOS 本来
/// 就是透明空盒(cupertino buildHandle 对 collapsed 画 SizedBox),照插
/// 只会留一块 44px 隐形命中区,挡住光标附近的 tap。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show HapticFeedback;

/// 测试定位用(widget test 无法 find 系统私有的 handle painter)。
const Key kCollapsedHandleKey = ValueKey('editor-collapsed-handle');

class CollapsedHandleController {
  CollapsedHandleController({
    required this.context,
    required this.tapRegionGroupId,
    this.onDragStart,
    this.onDragMove,
    this.onDragEnd,
  });

  final BuildContext context;

  /// 与编辑器内容/双手柄同 groupId:点手柄不触发 onTapOutside 收选区。
  final Object tapRegionGroupId;

  final VoidCallback? onDragStart;

  /// 拖拽点移动上报(全局;光标底锚起步 + delta 累加,**未做半行上移**,
  /// 编辑器命中时自己减半行 —— 与双手柄同口径)。
  final ValueChanged<Offset>? onDragMove;

  final VoidCallback? onDragEnd;

  /// 平台是否存在 collapsed 手柄形态(iOS 系统无:绘制即空盒)。
  static bool platformHasHandle(BuildContext context) =>
      Theme.of(context).platform != TargetPlatform.iOS;

  OverlayEntry? _entry;
  Rect _caretGlobal = Rect.zero;
  double _yComp = 0;
  bool _dragging = false;
  Offset _dragPosition = Offset.zero;

  bool get isShowing => _entry != null;
  bool get isDragging => _dragging;

  /// 显示 / 刷新位置。[caretGlobal] = 编辑光标全局矩形(高 = 行高)。
  void show(Rect caretGlobal) {
    _caretGlobal = caretGlobal;
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

  /// 滚动跟随:光标几何滞后一帧,先按本帧 scroll delta 平移(双手柄
  /// _yComp 同款消抖),帧后 [show] 带新矩形归零。
  void translate(double yCompensation) {
    _yComp = yCompensation;
    _entry?.markNeedsBuild();
  }

  void hide() {
    _entry?.remove();
    _entry = null;
    _dragging = false;
  }

  Widget _build(BuildContext ctx) {
    // iOS 已在创建前由 platformHasHandle 挡掉;这里恒为 material 水滴。
    final controls = materialTextSelectionControls;
    const type = TextSelectionHandleType.collapsed;
    final lineHeight = _caretGlobal.height;
    final handleAnchor = controls.getHandleAnchor(type, lineHeight);
    final size = controls.getHandleSize(lineHeight);

    // overlay 局部坐标(overlay 通常铺满屏 → 全局即局部)。
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final anchorGlobal = _caretGlobal.bottomCenter;
    final local = overlayBox == null
        ? anchorGlobal
        : overlayBox.globalToLocal(anchorGlobal);

    // 命中区放大到 ≥44px(手指友好),手柄绘制居中其中。
    const touch = 44.0;
    final left = local.dx - handleAnchor.dx - (touch - size.width) / 2;
    final top = local.dy - handleAnchor.dy - (touch - size.height) / 2 - _yComp;

    return TapRegion(
      groupId: tapRegionGroupId,
      child: Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: touch.clamp(size.width, double.infinity),
            height: touch.clamp(size.height, double.infinity),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => _onPanStart(),
              onPanUpdate: (d) => _onPanUpdate(d.delta),
              onPanEnd: (_) => _onPanEnd(),
              // PointerCancel(系统手势/来电抢占)不走 onPanEnd,
              // 不收会漏 dragEnd → 放大镜/IME 门残留。
              onPanCancel: _onPanEnd,
              child: Center(
                child: SizedBox(
                  key: kCollapsedHandleKey,
                  width: size.width,
                  height: size.height,
                  child: controls.buildHandle(ctx, type, lineHeight, null),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onPanStart() {
    _dragging = true;
    // 拖拽点 = 光标底部中点锚(非手指位置):手指按在手柄图形上、低于
    // 文本行一整行,直接用手指坐标命中会落到下一行(双手柄同款补偿)。
    _dragPosition = _caretGlobal.bottomCenter;
    HapticFeedback.selectionClick();
    onDragStart?.call();
    onDragMove?.call(_dragPosition);
  }

  void _onPanUpdate(Offset delta) {
    if (!_dragging) return;
    _dragPosition += delta;
    onDragMove?.call(_dragPosition);
  }

  void _onPanEnd() {
    if (!_dragging) return;
    _dragging = false;
    onDragEnd?.call();
  }
}
