/// 守护「键盘选区」:Cmd/Ctrl+A 全选 + Shift+方向扩展。
///
/// 复现并守护键盘导航原语 + Focus/Shortcuts 接线:鼠标拖出非折叠选区(顺带让
/// SelectionContentLayer 的 Focus 拿到焦点),再发键盘事件验证选区按预期变化。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/inline_span_text.dart';
import 'package:fluxdo_render/src/selection/selection_navigator.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';
import 'package:fluxdo_render/src/widget/selection_content_layer.dart';

/// 构造「SelectionScope + SelectionContentLayer + 多个 InlineSpanText」脚手架,
/// 鼠标拖出一个跨字符的非折叠选区(同时让 Focus 拿到焦点)。
Future<SelectionController> _pumpAndSelect(WidgetTester tester) async {
  final c = SelectionController(SelectionRegistry());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SelectionScope(
          controller: c,
          child: SelectionContentLayer(
            controller: c,
            onQuoteRequest: null,
            onCopyQuoteRequest: null,
            onCopyToast: null,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InlineSpanText(
                  inlines: [TextRun('第一段文字内容 alpha')],
                  baseStyle: TextStyle(fontSize: 16),
                  documentOrder: 0,
                ),
                InlineSpanText(
                  inlines: [TextRun('第二段文字内容 beta')],
                  baseStyle: TextStyle(fontSize: 16),
                  documentOrder: 1,
                ),
                InlineSpanText(
                  inlines: [TextRun('第三段文字内容 gamma')],
                  baseStyle: TextStyle(fontSize: 16),
                  documentOrder: 2,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // 鼠标拖出非折叠选区:从第一段内某点拖到稍右(产生选区 + 触发 requestFocus)。
  final p0 = tester.getTopLeft(find.byType(InlineSpanText).first) +
      const Offset(20, 8);
  final g = await tester.startGesture(p0, kind: PointerDeviceKind.mouse);
  await tester.pump(const Duration(milliseconds: 30));
  await g.moveTo(p0 + const Offset(30, 0)); // 越过 pan slop → drag 开始
  await tester.pump();
  await g.moveTo(p0 + const Offset(80, 0)); // 拖出几个字符
  await tester.pump();
  await g.up();
  await tester.pumpAndSettle();

  expect(c.selection, isNotNull, reason: '鼠标拖拽应产生选区');
  expect(c.selection!.isCollapsed, isFalse, reason: '应是非折叠选区');
  return c;
}

void main() {
  testWidgets('Cmd/Ctrl+A 全选:base 在首块起点、extent 在末块终点',
      (tester) async {
    final c = await _pumpAndSelect(tester);

    // 按平台 meta(macOS)/ control 发 A。测试默认 platform 跟随
    // debugDefaultTargetPlatformOverride,这里直接走应用层导航原语等价校验 +
    // 真实快捷键二选一:先发真实键。
    final isMac = debugDefaultTargetPlatformOverride == TargetPlatform.macOS ||
        (debugDefaultTargetPlatformOverride == null &&
            defaultTargetPlatform == TargetPlatform.macOS);
    if (isMac) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    } else {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
    await tester.pumpAndSettle();

    final blocks = c.registry.orderedBlocks();
    expect(blocks.length, 3);
    final sel = c.selection!;
    expect(sel.base.blockId, blocks.first.id, reason: 'base 在首块');
    expect(sel.base.renderOffset, 0, reason: 'base 在首块起点');
    expect(sel.extent.blockId, blocks.last.id, reason: 'extent 在末块');
    expect(sel.extent.renderOffset, blocks.last.renderLength,
        reason: 'extent 在末块终点');
  });

  testWidgets('Shift+ArrowRight:extent.renderOffset +1(或跨到下一块)',
      (tester) async {
    final c = await _pumpAndSelect(tester);

    final before = c.selection!.extent;
    final beforeBlocks = c.registry.orderedBlocks();
    final beforeIdx =
        beforeBlocks.indexWhere((b) => b.id == before.blockId);
    final beforeLen = beforeBlocks[beforeIdx].renderLength;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    final after = c.selection!.extent;
    if (before.renderOffset < beforeLen) {
      // 块内 +1
      expect(after.blockId, before.blockId);
      expect(after.renderOffset, before.renderOffset + 1,
          reason: 'Shift+Right 应使 extent.renderOffset +1');
    } else {
      // 越界跨到下一块开头
      expect(after.blockId, beforeBlocks[beforeIdx + 1].id);
      expect(after.renderOffset, 0);
    }
  });

  testWidgets('Shift+ArrowDown:extent 下移一行/跨块(base 不变)',
      (tester) async {
    final c = await _pumpAndSelect(tester);
    final baseBefore = c.selection!.base;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    // base 不动;extent 应仍是有效选区(单行块 → 跨到下一块边界)。
    expect(c.selection!.base, baseBefore, reason: 'Shift+Down 不动 base');
    expect(c.selection, isNotNull);
  });

  testWidgets('SelectionNavigator.selectAll 纯逻辑:空 registry 不操作',
      (tester) async {
    final c = SelectionController(SelectionRegistry());
    SelectionNavigator.selectAll(c);
    expect(c.selection, isNull, reason: '无可选块时不产生选区');
  });

  testWidgets('SelectionNavigator.moveExtentByCharacter:文档尾 clamp 不动',
      (tester) async {
    final c = await _pumpAndSelect(tester);
    // 先全选 → extent 到末块终点。
    SelectionNavigator.selectAll(c);
    final atEnd = c.selection!.extent;
    // 再 forward 一步:已在文档尾 → clamp 不动。
    SelectionNavigator.moveExtentByCharacter(c, forward: true);
    expect(c.selection!.extent, atEnd, reason: '文档尾再前进应 clamp 不动');
  });

  testWidgets('Cmd/Ctrl+C 复制选区到剪贴板,且保留选区', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final c = await _pumpAndSelect(tester);
    SelectionNavigator.selectAll(c); // 全选,内容确定
    await tester.pump();

    final isMac = debugDefaultTargetPlatformOverride == TargetPlatform.macOS ||
        (debugDefaultTargetPlatformOverride == null &&
            defaultTargetPlatform == TargetPlatform.macOS);
    final mod = isMac ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(mod);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(mod);
    await tester.pumpAndSettle();

    expect(copied, isNotNull, reason: 'Cmd/Ctrl+C 应写入剪贴板');
    expect(copied!.contains('第一段文字内容'), isTrue,
        reason: '剪贴板应含选区文本');
    expect(c.selection, isNotNull, reason: 'Cmd+C 后保留选区(桌面习惯)');
  });
}
