/// 孤岛集成 widget 测试:选岛/删岛/registry 隔离/岛前后建段。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/node/node.dart';

EditorState makeDoc() => EditorState(blocks: [
      TextBlock(id: 'e_0', content: EditableTextContent(text: 'aaa')),
      const IslandBlock(
        id: 'e_1',
        node: CodeBlockNode(id: 'b_0', code: 'print(1)', language: 'py'),
      ),
      TextBlock(id: 'e_2', content: EditableTextContent(text: 'bbb')),
    ]);

Future<EditorState> pumpEditor(WidgetTester tester, EditorState state) async {
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: FluxdoEditor(
            state: state,
            autofocus: true,
            baseTextStyle: const TextStyle(fontSize: 16, height: 1.6),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return state;
}

void main() {
  testWidgets('岛用 NodeFactory 渲染(能找到代码文本)', (tester) async {
    await pumpEditor(tester, makeDoc());
    expect(find.textContaining('print(1)', findRichText: true), findsOneWidget);
  });

  testWidgets('tap 岛 → 整选 + 选中描边;退格删岛', (tester) async {
    final state = await pumpEditor(tester, makeDoc());
    await tester.tap(find.byType(EditorIsland));
    await tester.pump();
    expect(state.selection!.base,
        const EditorPosition(blockId: 'e_1', offset: 0));
    expect(state.selection!.extent,
        const EditorPosition(blockId: 'e_1', offset: 1));
    expect(
      tester.widget<EditorIsland>(find.byType(EditorIsland)).selected,
      true,
    );
    // 整选态退格 → 删岛
    state.backspace();
    await tester.pump();
    expect(state.blocks.whereType<IslandBlock>(), isEmpty);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('岛内块不注册进编辑器 registry(选区隔离)', (tester) async {
    final state = await pumpEditor(tester, makeDoc());
    // 编辑器 registry 只应有 2 个文本块(e_0/e_2);codeblock 的
    // SelectableTextBox 注册进 EditorIsland 的哑控制器
    // 通过点击 codeblock 文本区域验证:命中不落进岛内部 → tap 走整选
    final islandRect = tester.getRect(find.byType(EditorIsland));
    await tester.tapAt(islandRect.center);
    await tester.pump();
    expect(state.selection!.base.blockId, 'e_1');
    expect(state.selection!.isCollapsed, false);
    // 光标/选区仍能落回文本块
    state.updateSelection(const EditorSelection.collapsed(
      EditorPosition(blockId: 'e_0', offset: 1),
    ));
    await tester.pump();
    expect(state.selection!.extent.blockId, 'e_0');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('岛整选态回车:岛后建空段', (tester) async {
    final state = await pumpEditor(tester, makeDoc());
    await tester.tap(find.byType(EditorIsland));
    await tester.pump();
    state.splitBlock();
    await tester.pump();
    expect(state.blocks.length, 4);
    expect(state.blocks[2], isA<TextBlock>());
    expect((state.blocks[2] as TextBlock).content.text, '');
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('AbsorbPointer 冻结岛内交互(无手势穿透崩溃)', (tester) async {
    await pumpEditor(tester, makeDoc());
    // codeblock 内长按/拖动均不应触发岛内部手势
    await tester.longPress(find.byType(EditorIsland));
    await tester.pump();
    // 不崩即过(岛内 recognizer 被 AbsorbPointer 挡住)
    await tester.pump(const Duration(seconds: 1));
  });

}
