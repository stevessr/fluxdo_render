/// 列表整体对齐(容器 `<div align>` 下放)的渲染验证:
/// 居中/右对齐时 li 内容收自然宽整体摆放,marker 跟随悬挂在内容左缘外;
/// 无对齐时保持原有「内容贴左缘铺满」布局(防回归)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/list_item_layout.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

import '../test_text_finders.dart';

void main() {
  // 测试表面 800 宽;bodyMedium 14 → list 左 padding 2.5em = 35,
  // 内容区 [35, 800]。
  const contentLeft = 35.0;
  const surfaceWidth = 800.0;

  Widget pumpList(TextAlign? align) => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => NodeFactory().buildList(
              ctx,
              ListNode(
                id: 'l',
                ordered: false,
                depth: 0,
                textAlign: align,
                items: const [
                  ListItem(inlines: [TextRun('短文本')]),
                ],
              ),
            ),
          ),
        ),
      );

  testWidgets('居中列表:内容整体居中,marker 跟随悬挂在内容左缘外', (tester) async {
    await tester.pumpWidget(pumpList(TextAlign.center));

    final textRect = tester.getRect(findRenderedText('短文本'));
    expect(textRect.center.dx,
        moreOrLessEquals((contentLeft + surfaceWidth) / 2, epsilon: 2),
        reason: '内容未居中: $textRect');

    // marker 右缘 = 内容左缘 - kGapVsMarker(悬挂跟随,而非钉在列表左缘)。
    final markerRight =
        tester.getRect(find.byKey(const ValueKey('ul_marker_disc'))).right;
    expect(textRect.left - markerRight, moreOrLessEquals(kGapVsMarker, epsilon: 1),
        reason: 'marker 未跟随内容');
  });

  testWidgets('右对齐列表:内容右缘贴内容区右缘', (tester) async {
    await tester.pumpWidget(pumpList(TextAlign.right));

    final textRect = tester.getRect(findRenderedText('短文本'));
    expect(textRect.right, moreOrLessEquals(surfaceWidth, epsilon: 2),
        reason: '内容未靠右: $textRect');
  });

  testWidgets('无对齐列表:内容贴内容区左缘(原行为不变)', (tester) async {
    await tester.pumpWidget(pumpList(null));

    final textRect = tester.getRect(findRenderedText('短文本'));
    expect(textRect.left, moreOrLessEquals(contentLeft, epsilon: 2),
        reason: '默认布局被破坏: $textRect');
  });
}
