/// 代码块岛内原位编辑(EditorCodeBlock):展示/编辑态切换、提交/取消
/// 语义、选择柄整选、mermaid 不接管。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

(EditorState, IslandBlock) codeDoc({String lang = 'dart'}) {
  final island = IslandBlock(
    id: 'e_code',
    node: CodeBlockNode(id: 'b_0', code: 'main() {}', language: lang),
  );
  final s = EditorState(
    blocks: [
      TextBlock(
        id: 'e_0',
        content: EditableTextContent(text: '前文'),
      ),
      island,
    ],
  );
  return (s, island);
}

Future<void> pump(
  WidgetTester tester,
  EditorState state, {
  void Function(IslandBlock, String, String?)? onCodeBlockEdited,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FluxdoEditor(state: state, onCodeBlockEdited: onCodeBlockEdited),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('Markdown源码节点显示源码且不提供语言编辑', (tester) async {
    const node = CodeBlockNode(
      id: 'mock_source',
      code: '[poll]\n* 模拟甲\n[/poll]',
      rawMarkdown: true,
    );
    final state = EditorState(
      blocks: [IslandBlock(id: 'mock_island', node: node)],
    );
    addTearDown(state.dispose);
    await pump(tester, state, onCodeBlockEdited: (_, _, _) {});
    expect(find.text('Markdown 源码'), findsOneWidget);
    await tester.tap(find.text(node.code));
    await tester.pump();
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(docToMarkdown(state.blocks), node.code);
  });

  testWidgets('宿主接线:代码块渲染为 EditorCodeBlock(mermaid 除外)', (tester) async {
    final (s, _) = codeDoc();
    addTearDown(s.dispose);
    await pump(tester, s, onCodeBlockEdited: (_, _, _) {});
    expect(find.byType(EditorCodeBlock), findsOneWidget);
    expect(find.text('DART'), findsOneWidget);

    // mermaid:仍走通用岛(图表壳冲突)
    final (s2, _) = codeDoc(lang: 'mermaid');
    addTearDown(s2.dispose);
    await pump(tester, s2, onCodeBlockEdited: (_, _, _) {});
    expect(find.byType(EditorCodeBlock), findsNothing);
    expect(find.byType(EditorIsland), findsOneWidget);
  });

  testWidgets('未接线(onCodeBlockEdited=null):走通用只读岛', (tester) async {
    final (s, _) = codeDoc();
    addTearDown(s.dispose);
    await pump(tester, s);
    expect(find.byType(EditorCodeBlock), findsNothing);
    expect(find.byType(EditorIsland), findsOneWidget);
  });

  testWidgets('单击代码区进编辑态,改码失焦提交新 code/language', (tester) async {
    final (s, island) = codeDoc();
    addTearDown(s.dispose);
    (IslandBlock, String, String?)? committed;
    await pump(
      tester,
      s,
      onCodeBlockEdited: (ib, code, lang) => committed = (ib, code, lang),
    );

    // 单击代码文本区进编辑态
    await tester.tap(find.text('main() {}'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(2), reason: 'code + lang 两框');

    // 改代码 + 改语言
    final codeField = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'main() {}',
    );
    await tester.enterText(codeField, 'void main() => print(1);');
    final langField = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'dart',
    );
    await tester.enterText(langField, 'Python');

    // 点外部(前文段落)失焦 → 提交
    await tester.tap(find.text('前文'), warnIfMissed: false);
    await tester.pump();
    await tester.pump();

    expect(committed, isNotNull);
    expect(committed!.$1.id, island.id);
    expect(committed!.$2, 'void main() => print(1);');
    expect(committed!.$3, 'python', reason: '语言小写归一');
  });

  testWidgets('Esc 放弃修改退出编辑态(不上抛)', (tester) async {
    final (s, _) = codeDoc();
    addTearDown(s.dispose);
    var commits = 0;
    await pump(tester, s, onCodeBlockEdited: (_, _, _) => commits++);

    await tester.tap(find.text('main() {}'));
    await tester.pump();
    await tester.pump();
    final codeField = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'main() {}',
    );
    await tester.enterText(codeField, '改了');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();

    expect(commits, 0);
    expect(find.text('main() {}'), findsOneWidget, reason: '展示态回原文');
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('提交后 updateIslandNode:岛 id 不变,undo 一步回原码', (tester) async {
    final (s, island) = codeDoc();
    addTearDown(s.dispose);
    await pump(
      tester,
      s,
      onCodeBlockEdited: (ib, code, lang) => s.updateIslandNode(
        ib.id,
        CodeBlockNode(id: ib.node.id, code: code, language: lang),
      ),
    );

    await tester.tap(find.text('main() {}'));
    await tester.pump();
    await tester.pump();
    final codeField = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'main() {}',
    );
    await tester.enterText(codeField, 'x = 1');
    await tester.tap(find.text('前文'), warnIfMissed: false);
    await tester.pump();
    await tester.pump();

    final updated = s.blocks[1] as IslandBlock;
    expect(updated.id, island.id, reason: '岛身份保持');
    expect((updated.node as CodeBlockNode).code, 'x = 1');

    s.undo();
    expect(
      ((s.blocks[1] as IslandBlock).node as CodeBlockNode).code,
      'main() {}',
    );
  });

  testWidgets('hover 出选择柄,点击整选(选区覆盖岛)', (tester) async {
    final (s, island) = codeDoc();
    addTearDown(s.dispose);
    await pump(tester, s, onCodeBlockEdited: (_, _, _) {});

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byType(EditorCodeBlock)));
    await tester.pump();
    await tester.pump();

    final handle = find.byTooltip('选中代码块(选中后退格删除)');
    expect(handle, findsOneWidget);
    await tester.tap(handle);
    await tester.pump();
    await tester.pump();

    final sel = s.selection!;
    expect(sel.base.blockId, island.id);
    expect(sel.extent.offset, 1, reason: '整选岛');
  });
}
