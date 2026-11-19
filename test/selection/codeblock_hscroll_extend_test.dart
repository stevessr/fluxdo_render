/// 验证「代码块内部横向滚动器」参与选区边缘自动滚:
/// 拖选到代码块可视区右缘时,横滚自动滚动、extent 扩到屏外溢出内容
/// (此前只驱动外层页面纵滚 → 代码块横向溢出部分永远选不到)。
library;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';
import 'package:fluxdo_render/src/selection/selection_gesture_layer.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

void main() {
  testWidgets('代码块 handle 注册内部滚动器链(横滚在内)', (tester) async {
    final c = SelectionController(SelectionRegistry());
    final factory = NodeFactory();
    // 一行超长代码 → 横向溢出。
    final longLine = 'x' * 400;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: c,
            child: SelectionGestureLayer(
              controller: c,
              onSelectionChanged: (_, {bool fromTouch = false}) {},
              child: Builder(
                builder: (ctx) => factory.build(
                  ctx,
                  CodeBlockNode(id: 'cb', code: longLine, language: 'text'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final handle = c.registry.liveHandles.firstWhere(
      (h) => h.interiorScrollablesGetter != null,
      orElse: () => fail('代码块 handle 未注册 interiorScrollablesGetter'),
    );
    final scrollables = handle.interiorScrollablesGetter!();
    expect(
      scrollables.any(
          (s) => axisDirectionToAxis(s.axisDirection) == Axis.horizontal),
      isTrue,
      reason: '内部滚动器链应含代码块的横向 SingleChildScrollView',
    );
  });

  testWidgets('拖选到代码块右缘:横滚自动滚动 + extent 扩到溢出内容',
      (tester) async {
    final c = SelectionController(SelectionRegistry());
    final factory = NodeFactory();
    final longLine = 'x' * 400;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: c,
            child: SelectionGestureLayer(
              controller: c,
              onSelectionChanged: (_, {bool fromTouch = false}) {},
              child: Builder(
                builder: (ctx) => factory.build(
                  ctx,
                  CodeBlockNode(id: 'cb', code: longLine, language: 'text'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final handle = c.registry.liveHandles
        .firstWhere((h) => h.interiorScrollablesGetter != null);
    final hScrollable = handle.interiorScrollablesGetter!().firstWhere(
        (s) => axisDirectionToAxis(s.axisDirection) == Axis.horizontal);
    expect(hScrollable.position.pixels, 0);

    final blockRect = handle.globalRect()!;
    final y = blockRect.center.dy;

    // 鼠标从块内左侧起拖,拖到块右缘(触发带内)悬停 → 边缘自动滚。
    final g = await tester.startGesture(Offset(blockRect.left + 20, y),
        kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveTo(Offset(blockRect.left + 60, y)); // 越过 slop,进入 drag
    await tester.pump();
    await g.moveTo(Offset(blockRect.right - 4, y)); // 贴右缘 → 触发横向自动滚
    // 自动滚是逐步 animateTo(overDrag ≤20px/步),多 pump 几轮让它滚起来。
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final scrolled = hScrollable.position.pixels;
    final extentOffset = c.selection?.extent.renderOffset ?? 0;
    await g.up();
    await tester.pumpAndSettle();

    expect(scrolled, greaterThan(100),
        reason: '拖到代码块右缘应驱动内部横滚持续自动滚动(实际 $scrolled)');
    // 测试字体 Ahem 14px/字符,视口 ~750px → 首屏约 54 字符;extent 显著
    // 超过它 = 已扩到横向溢出、只有滚动后才可见的内容。
    expect(extentOffset, greaterThan(70),
        reason: '横滚后 extent 应扩到首屏外的溢出内容(实际 $extentOffset)');
  });
}
