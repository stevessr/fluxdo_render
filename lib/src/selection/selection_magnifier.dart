/// 选区放大镜 —— 拖拽手柄时显示放大预览,看清手指下的字。
///
/// 直接用 Flutter SDK 的 **`TextMagnifier.adaptiveMagnifierConfiguration`**
/// (对齐 SelectionOverlay.showMagnifier,text_selection.dart:1151-1181):
/// - Android → Material [TextMagnifier](77.37×37.9,scale 1.25,圆角 40,
///   跨行 70ms 跳变动画,X 夹在当前行内);
/// - iOS → [CupertinoTextMagnifier](80×47.5,椭圆 60/50,主题色边 2.0,
///   下拖阻力 + 超阈值自动隐藏,150ms in/out 动画);
/// - 桌面 → builder 返回 null,不显示。
/// 视觉与跟随动画全部由 SDK 组件自管,本类只负责喂 [MagnifierInfo] 四字段
/// 并管理 [MagnifierController] 的 show/hide。
library;

import 'package:material_ui/material_ui.dart';

class SelectionMagnifier {
  SelectionMagnifier(this.context);

  final BuildContext context;

  final MagnifierController _controller = MagnifierController();

  /// 平台放大镜自己监听它重定位(TextMagnifier/CupertinoTextMagnifier 内部
  /// addListener),show 后每帧只需更新 value,零重插。
  final ValueNotifier<MagnifierInfo> _info =
      ValueNotifier<MagnifierInfo>(MagnifierInfo.empty);

  bool get isShowing => _controller.overlayEntry != null;

  /// 显示/更新放大镜。
  ///
  /// - [gestureGlobal]:拖拽点全局坐标(镜子 X 跟它;iOS 下拖过远自动隐藏)。
  /// - [caretRect]:被拖端点的 caret 全局矩形(焦点锁其**行中心**,对齐 SDK
  ///   MagnifierInfo.caretRect —— 焦点指文字,不指手指)。
  /// - [currentLineBoundaries]:被拖端所在行的全局矩形(Material 镜子 X 夹在
  ///   行首尾之间)。
  /// - [fieldBounds]:内容区全局矩形(Material 焦点 X 不出内容区)。
  /// - [below]:插到该 OverlayEntry 之下(Android 传托柄 entry → 镜内不映
  ///   托柄,对齐 shouldDisplayHandlesInMagnifier=false;iOS 传 null)。
  void show({
    required Offset gestureGlobal,
    required Rect caretRect,
    required Rect currentLineBoundaries,
    required Rect fieldBounds,
    OverlayEntry? below,
  }) {
    _info.value = MagnifierInfo(
      globalGesturePosition: gestureGlobal,
      caretRect: caretRect,
      currentLineBoundaries: currentLineBoundaries,
      fieldBounds: fieldBounds,
    );
    if (_controller.overlayEntry != null) return; // 已在 overlay,listener 自更

    // 按平台构建;桌面返回 null → 不显示(对齐 SDK showMagnifier 的预构建判空)。
    final magnifier = TextMagnifier.adaptiveMagnifierConfiguration
        .magnifierBuilder(context, _controller, _info);
    if (magnifier == null) return;

    _controller.show(
      context: context,
      below: TextMagnifier
              .adaptiveMagnifierConfiguration.shouldDisplayHandlesInMagnifier
          ? null
          : below,
      builder: (_) => magnifier,
    );
  }

  void hide() {
    if (_controller.overlayEntry == null) return;
    _controller.hide();
  }
}
