/// 验证「鼠标拖选进行中,滚轮滚动 → extent 按钉住的指针位置跟随扩展」。
///
/// 复现并守护「一滚就断」的修复:拖拽中滚动列表,选区端点应扫过新滚入的内容,
/// 而不是卡在原块。
library;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';
import 'package:fluxdo_render/src/selection/selection_gesture_layer.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';

void main() {
  testWidgets('拖拽中滚轮滚动:extent 随滚动跟随到新内容块', (tester) async {
    final c = SelectionController(SelectionRegistry());
    final sc = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: sc,
            child: SelectionScope(
              controller: c,
              child: SelectionGestureLayer(
                controller: c,
                onSelectionChanged: (_, {bool fromTouch = false}) {},
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 40 段,内容高度远超 600 视口,确保有「视口下方」的块。
                    for (var i = 0; i < 40; i++)
                      InlineSpanText(
                        inlines: [TextRun('第 $i 段文字内容 line')],
                        baseStyle: const TextStyle(fontSize: 16),
                        documentOrder: i,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 固定指针 Y(视口上部),开始鼠标拖拽并轻微移动以进入 drag。
    const p0 = Offset(100, 80);
    final g = await tester.startGesture(p0, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 30));
    await g.moveTo(p0 + const Offset(20, 6)); // 越过 pan slop → drag 开始
    await tester.pump();
    await g.moveTo(const Offset(140, 120)); // 拖到稍下,产生非折叠选区
    await tester.pump();

    final extentBefore = c.selection!.extent.blockId.docOrder;

    // 拖拽不松手,模拟滚轮:向下滚 360px(原本视口下方的块滚到指针处)。
    sc.jumpTo(360);
    await tester.pump();

    final extentAfter = c.selection!.extent.blockId.docOrder;

    await g.up();

    expect(c.selection, isNotNull, reason: '滚动后选区仍在(不中断)');
    expect(extentAfter, greaterThan(extentBefore),
        reason: '滚轮滚动后,extent 应跟随钉住的指针扫到更靠后的块'
            '(before=$extentBefore after=$extentAfter)');
  });

  testWidgets('settled 选区不保活发起 item(keepAlive 仅拖拽中,避免分块重建整套同 id 双高亮)',
      (tester) async {
    final c = SelectionController(SelectionRegistry());
    final sc = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: sc,
            itemCount: 30,
            itemBuilder: (ctx, i) {
              if (i == 0) {
                // 含选区手势层的「发起 item」(模拟一个 chunk)。
                return SelectionScope(
                  controller: c,
                  child: SelectionGestureLayer(
                    controller: c,
                    onSelectionChanged: (_, {bool fromTouch = false}) {},
                    child: const SizedBox(height: 100, child: Text('item0')),
                  ),
                );
              }
              return SizedBox(height: 400, child: Text('item $i'));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SelectionGestureLayer), findsOneWidget);

    // 设一个非空选区(模拟已选中、非拖拽态)。
    c.selection = const DocumentSelection(
      base: DocumentPosition(blockId: SelectableBlockId(0), renderOffset: 0),
      extent: DocumentPosition(blockId: SelectableBlockId(0), renderOffset: 1),
    );
    await tester.pump();

    // 把 item0 滚到远离视口 + 超出 cacheExtent。
    sc.jumpTo(3000);
    await tester.pumpAndSettle();

    // 新行为:keepAlive 仅在「拖拽中」(_isDragging)生效,settled 选区不再
    // 保活发起 item —— 否则分块长帖里「有选区」会让所有 chunk 保活,resize/
    // 重建时旧套被钉住、新套又 mount → 整套同 id 重复注册 → 双高亮/划词跳段。
    // settled 选区下滚出视口的 item 正常回收(选区是逻辑模型,滚回重挂即恢复)。
    expect(find.byType(SelectionGestureLayer, skipOffstage: false), findsNothing,
        reason: 'settled 选区不保活,远离视口的发起 item 应正常回收');
  });
}

