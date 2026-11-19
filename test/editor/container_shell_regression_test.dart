/// M5-B 回归压测:容器壳分组重排的 Element 树稳定性。
///
/// 覆盖曾导致红屏(InheritedElement `_dependents.isEmpty` 断言)的路径:
/// 退格弹层/回车分裂/undo-redo/粘贴重排/摘树 —— groupId key 保证壳身份
/// 稳定,分组变动时壳不整棵 deactivate。
library;

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/widget/fluxdo_editor.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

Widget host(EditorState state) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: FluxdoEditor(state: state)),
      ),
    );

void main() {
  testWidgets('quote 卡内容渲染 + 退格弹层壳身份稳定', (tester) async {
    final nodes = ParagraphParser().parse(
        '<aside class="quote" data-username="sam" data-post="2" data-topic="1">'
        '<div class="title">sam:</div>'
        '<blockquote><p>引用正文内容</p><p>第二段</p></blockquote></aside>'
        '<p>外部段落</p>');
    var n = 0;
    final state = EditorState(blocks: blockNodesToDoc(nodes, () => 'e_${n++}'));
    addTearDown(state.dispose);
    await tester.pumpWidget(host(state));
    await tester.pump();
    // 内容与壳头都渲染
    expect(find.textContaining('引用正文内容', findRichText: true), findsOneWidget);
    expect(find.textContaining('sam:'), findsOneWidget);

    // 第二段块首退格弹出卡 → 分组从 2 块缩为 1 块(壳 key=groupId 不变)
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks[1].id, offset: 0)));
    state.backspace();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('第二段', findRichText: true), findsOneWidget);

    // undo → 分组复原;redo → 再弹
    state.undo();
    await tester.pump();
    expect(tester.takeException(), isNull);
    state.redo();
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 首块也弹出 → 壳整体消失
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks[0].id, offset: 0)));
    state.backspace();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('sam:'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('粘贴容器片段到空文档:壳渲染 + 落点空段', (tester) async {
    final state = EditorState.fromTexts(['']);
    addTearDown(state.dispose);
    await tester.pumpWidget(host(state));
    await tester.pump();

    // 模拟插入菜单 [quote] 模板产物
    final frag = blockNodesToDoc(
        ParagraphParser().parse(
            '<aside class="quote no-group"><blockquote><p>模板引用</p></blockquote></aside>'),
        () => 'p_0');
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks.first.id, offset: 0)));
    state.pasteBlocks(frag);
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 壳里的内容显示了(回归断言:此前单块内联并入丢壳变裸文本)
    expect(find.textContaining('模板引用', findRichText: true), findsOneWidget);
    final hasShell = state.blocks
        .whereType<TextBlock>()
        .any((b) => b.containers.isNotEmpty);
    expect(hasShell, isTrue);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('壳内连续打字 + hover 中摘树', (tester) async {
    final nodes = ParagraphParser()
        .parse('<div class="spoiler"><p>abc</p></div>');
    var n = 0;
    final state = EditorState(blocks: blockNodesToDoc(nodes, () => 'e_${n++}'));
    addTearDown(state.dispose);
    await tester.pumpWidget(host(state));
    await tester.pump();

    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks.first.id, offset: 3)));
    for (var i = 0; i < 3; i++) {
      state.insertText('x');
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    // 桌面鼠标 hover 编辑器时直接摘树(MouseRegion + shell 同时 deactivate)
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(
        location: tester.getCenter(find.byType(FluxdoEditor)));
    addTearDown(gesture.removePointer);
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });
}
