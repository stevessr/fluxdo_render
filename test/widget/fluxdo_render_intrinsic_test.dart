/// 无界宽 / 内在尺寸下的布局回归。
///
/// 背景:聊天气泡曾用 `IntrinsicWidth` 包住 FluxdoRender 求「按内容自适应宽度」,
/// 触发两条崩溃链路 —— 段落布局缓存的宽度桶 `(inf * 2).round()` 抛
/// "Unsupported operation: Infinity or NaN toInt",整棵内容子树布局失败,
/// 表现为消息肉眼不可见。这里锁住:
/// 1. 无界宽约束下正常出尺寸,不抛异常;
/// 2. `stretchBlocks: false` 时按内容收缩(气泡自适应宽度的正确姿势)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/widget/fluxdo_render.dart';

/// 把渲染树放进给定包装里,返回 (尺寸, 捕获到的异常)。
Future<(Size?, Object?)> layout(
  WidgetTester tester,
  Widget Function(Widget child) wrap, {
  required String cooked,
  bool stretchBlocks = true,
}) async {
  Object? caught;
  final prev = FlutterError.onError;
  FlutterError.onError = (details) => caught ??= details.exception;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        // 用 maxWidth 而非 SizedBox：给出**宽松**约束，宽度才由内容决定。
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: wrap(
            KeyedSubtree(
              key: const ValueKey('content'),
              child: FluxdoRender(
                cookedHtml: cooked,
                selectionEnabled: false,
                compact: true,
                stretchBlocks: stretchBlocks,
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  FlutterError.onError = prev;
  Size? size;
  try {
    size = tester.getSize(find.byKey(const ValueKey('content')));
  } catch (e) {
    caught ??= e;
  }
  return (size, caught);
}

void main() {
  const shortText = '<p>hi</p>';
  const longText = '<p>这是一条相当长的聊天消息，长到足以在四百逻辑像素的容器里换行显示。</p>';

  testWidgets('IntrinsicWidth 包裹纯文本不抛异常', (tester) async {
    final (size, err) = await layout(
      tester,
      (child) => IntrinsicWidth(child: child),
      cooked: shortText,
    );
    expect(err, isNull, reason: '内在宽度询问不应抛异常');
    expect(size, isNotNull);
    expect(size!.width, greaterThan(0));
    expect(size.height, greaterThan(0));
  });

  // 横向 Scrollable 给的是无穷 maxWidth（Column 的 stretch 语义在无界宽下本就
  // 非法，故配 stretchBlocks: false）—— 走的正是 ParagraphLayoutCache.obtain
  // 的无界宽兜底分支。
  testWidgets('无界宽约束(横向 Scrollable)下正常排版', (tester) async {
    final (size, err) = await layout(
      tester,
      (child) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: child,
      ),
      cooked: longText,
      stretchBlocks: false,
    );
    expect(err, isNull);
    expect(size, isNotNull);
    // 无界宽 = 有多宽排多宽,不换行 → 比 400 容器宽。
    expect(size!.width, greaterThan(400));
  });

  testWidgets('stretchBlocks: false 时按内容收缩', (tester) async {
    final (stretched, errA) = await layout(
      tester,
      (child) => child,
      cooked: shortText,
    );
    final (shrunk, errB) = await layout(
      tester,
      (child) => child,
      cooked: shortText,
      stretchBlocks: false,
    );
    expect(errA, isNull);
    expect(errB, isNull);
    // 默认拉伸占满栏宽;关掉后只占内容自身宽度。
    expect(stretched!.width, 400);
    expect(shrunk!.width, lessThan(400));
    expect(shrunk.width, greaterThan(0));
  });

  testWidgets('stretchBlocks: false 时长文本仍在容器宽度处换行', (tester) async {
    final (size, err) = await layout(
      tester,
      (child) => child,
      cooked: longText,
      stretchBlocks: false,
    );
    expect(err, isNull);
    expect(size!.width, lessThanOrEqualTo(400));
  });
}
