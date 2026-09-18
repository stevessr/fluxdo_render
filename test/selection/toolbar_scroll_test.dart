import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/selection/selection_data.dart';
import 'package:fluxdo_render/src/selection/selection_toolbar.dart';

void main() {
  // 用一个能拿到 Overlay 的 host 测 toolbar show/reposition/hide。
  //
  // toolbar 现由 AdaptiveTextSelectionToolbar 承载:测试环境平台为 android →
  // Material TextSelectionToolbar,copy/selectAll label 走 MaterialLocalizations
  // (默认英文 'Copy'/'Select all');「引用」等自定义按钮仍是中文 label。
  // 定位(上/下翻转、夹边)由 SDK TextSelectionToolbarLayoutDelegate 处理,
  // 这里只验证「跟随选区、始终可见」的宏观行为。
  Future<SelectionToolbar> mountToolbar(
    WidgetTester tester, {
    required void Function(String) onQuote,
    VoidCallback? onSelectAll,
  }) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox(width: 400, height: 800);
          }),
        ),
      ),
    );
    return SelectionToolbar(
      context: ctx,
      onQuote: onQuote,
      onCopied: null,
      onSelectAll: onSelectAll,
    );
  }

  SelectionData dataAt(Rect bounds) => SelectionData(
        plainText: 'hello',
        globalBounds: bounds,
        globalRects: [bounds],
      );

  final copyText = find.text('Copy');

  testWidgets('show 弹出 toolbar(复制/引用按钮可见)', (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    t.show(dataAt(const Rect.fromLTWH(100, 300, 80, 20)));
    await tester.pump();
    expect(copyText, findsOneWidget);
    expect(find.text('引用'), findsOneWidget);
    t.hide();
    await tester.pump();
    expect(copyText, findsNothing);
  });

  testWidgets('onSelectAll 注入时显示「全选」并回调', (tester) async {
    var selectAllCount = 0;
    final t = await mountToolbar(
      tester,
      onQuote: (_) {},
      onSelectAll: () => selectAllCount++,
    );
    t.show(dataAt(const Rect.fromLTWH(100, 300, 80, 20)));
    await tester.pump();
    final selectAll = find.text('Select all');
    expect(selectAll, findsOneWidget);
    await tester.tap(selectAll);
    await tester.pump();
    expect(selectAllCount, 1);
    // 全选不自动收 toolbar(上层按平台决定保持重定位或收起)。
    expect(copyText, findsOneWidget);
    t.hide();
  });

  testWidgets('reposition 选区滚动 → toolbar 跟随移动,且始终夹在视口内可见',
      (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    t.show(dataAt(const Rect.fromLTWH(100, 300, 80, 20)));
    await tester.pump();
    final y0 = tester.getTopLeft(copyText).dy;

    // 选区上移(模拟滚动)→ toolbar 跟着上移(连续,不是突然消失)。
    t.reposition(dataAt(const Rect.fromLTWH(100, 200, 80, 20)));
    await tester.pump();
    final y1 = tester.getTopLeft(copyText).dy;
    expect(y1, lessThan(y0), reason: 'toolbar 应跟随选区连续上移');

    // 选区滚到屏幕上方很远(仍有可见几何)→ toolbar **夹在视口内保持可见**
    // (anchor 已 clamp 进 overlay,SDK delegate 再夹一道;而非滑出屏幕)。
    t.reposition(dataAt(const Rect.fromLTWH(100, -500, 80, 20)));
    await tester.pump();
    final y2 = tester.getTopLeft(copyText).dy;
    expect(y2, greaterThanOrEqualTo(0.0),
        reason: 'toolbar 夹在视口内,始终可见(不滑出屏幕)');
    t.hide();
  });

  testWidgets('选区比视口还高(顶/底都出界,中段可见)→ toolbar 仍在视口内可见',
      (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    final viewH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    // 选区从 y=-200 到 y=1000(高 1200 > 视口),视口只显示中段。
    t.show(SelectionData(
      plainText: 'hello',
      globalBounds: const Rect.fromLTWH(100, -200, 80, 1200),
      globalRects: const [Rect.fromLTWH(100, -200, 80, 1200)],
    ));
    await tester.pump();
    final pos = tester.getTopLeft(copyText);
    // 工具栏必须落在视口内(之前会跑到屏幕外 → 看不见)。
    expect(pos.dy, greaterThanOrEqualTo(0.0));
    expect(pos.dy, lessThan(viewH),
        reason: '选区跨满视口时,工具栏夹到视口内,始终可见');
    t.hide();
  });

  testWidgets('选区完全滚出视口(无可见块)→ toolbar 隐藏(滚回再现)',
      (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    t.show(dataAt(const Rect.fromLTWH(100, 300, 80, 20)));
    await tester.pump();
    expect(copyText, findsOneWidget);
    // 无可见几何(globalRects 空)→ 不显示。
    t.reposition(const SelectionData(
      plainText: 'hello',
      globalBounds: Rect.zero,
      globalRects: [],
    ));
    await tester.pump();
    expect(copyText, findsNothing, reason: '选区完全滚出视口时工具栏隐藏');
    t.hide();
  });

  testWidgets('reposition yCompensation 抵消滚动滞后(toolbar 预平移 delta)',
      (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    t.show(dataAt(const Rect.fromLTWH(100, 400, 80, 20)));
    await tester.pump();
    final y0 = tester.getTopLeft(copyText).dy;

    // 同样几何但补偿 60 → toolbar 上移 60(与内容同帧对齐,消抖)。
    t.reposition(dataAt(const Rect.fromLTWH(100, 400, 80, 20)),
        yCompensation: 60);
    await tester.pump();
    final y1 = tester.getTopLeft(copyText).dy;
    expect(y1, closeTo(y0 - 60, 0.5),
        reason: 'yCompensation=60 → toolbar 竖直预平移 60(抵消一帧滚动滞后)');
    t.hide();
  });

  testWidgets('reposition(null) 隐藏 toolbar', (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    t.show(dataAt(const Rect.fromLTWH(100, 300, 80, 20)));
    await tester.pump();
    t.reposition(null);
    await tester.pump();
    expect(copyText, findsNothing);
  });

  testWidgets('引用按钮回调 plainText', (tester) async {
    String? quoted;
    final t = await mountToolbar(tester, onQuote: (s) => quoted = s);
    t.show(dataAt(const Rect.fromLTWH(100, 300, 80, 20)));
    await tester.pump();
    await tester.tap(find.text('引用'));
    await tester.pump();
    expect(quoted, 'hello');
  });

  testWidgets('上方放不下 → toolbar 翻到选区下方(SDK delegate)', (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    // 选区贴屏幕顶(y=10):上方放不下 toolbar → 翻到选区下方。
    t.show(dataAt(const Rect.fromLTWH(100, 10, 80, 20)));
    await tester.pump();
    final pos = tester.getTopLeft(copyText);
    expect(pos.dy, greaterThan(30),
        reason: '上方放不下应翻到选区下方(bottom=30 之下)');
    t.hide();
  });

  testWidgets('上方放得下 → toolbar 在选区上方', (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    // 选区在 y=400,上方空间充足。
    t.show(dataAt(const Rect.fromLTWH(100, 400, 80, 20)));
    await tester.pump();
    final pos = tester.getTopLeft(copyText);
    expect(pos.dy, lessThan(400), reason: '上方放得下应在选区上方');
    t.hide();
  });

  testWidgets('选区靠屏幕右边 → toolbar 夹回视口内(SDK delegate)',
      (tester) async {
    final t = await mountToolbar(tester, onQuote: (_) {});
    final screenW =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    // 选区贴右边缘。
    t.show(dataAt(Rect.fromLTWH(screenW - 30, 400, 20, 20)));
    await tester.pump();
    // toolbar 整体不应超出右边界(取「引用」= 最右按钮的右沿)。
    final tr = tester.getTopRight(find.text('引用'));
    expect(tr.dx, lessThanOrEqualTo(screenW),
        reason: 'SDK delegate 应把 toolbar 夹回视口内,不超右边界');
    t.hide();
  });
  testWidgets('官方菜单互斥：后显示的菜单替换旧菜单，旧控制器不能关闭新菜单', (tester) async {
    final first = await mountToolbar(tester, onQuote: (_) {});
    first.show(dataAt(const Rect.fromLTWH(100, 200, 80, 20)));
    await tester.pump();
    final ctx = tester.element(find.byType(Scaffold));
    final second = SelectionToolbar(
      context: ctx,
      onQuote: null,
      onCopied: null,
    );
    second.show(dataAt(const Rect.fromLTWH(100, 400, 80, 20)));
    await tester.pump();
    expect(find.byType(TextSelectionToolbar), findsOneWidget);
    expect(find.text('引用'), findsNothing);
    first.hide();
    await tester.pump();
    expect(find.byType(TextSelectionToolbar), findsOneWidget);
    ContextMenuController.removeAny();
    await tester.pump();
    expect(find.byType(TextSelectionToolbar), findsNothing);
  });

}
