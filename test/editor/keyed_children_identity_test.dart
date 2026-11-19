/// 顶层 children 全 keyed 回归守护:结构重排(弹层/插壳)时,未被删除
/// 的岛/段落 Element **必须复用**(State identity 不变)。
///
/// unkeyed Padding 混在 keyed 壳之间时,updateChildren 按位置配对,
/// 弹层导致的位移会让岛整棵 deactivate 重建 —— 真机上深层
/// InheritedElement dependents 清理时序炸 '_dependents.isEmpty'(红屏)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/widget/editor_island.dart';
import 'package:fluxdo_render/src/editor/widget/fluxdo_editor.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

EditorState fromHtml(String html) {
  var n = 0;
  return EditorState(
      blocks:
          blockNodesToDoc(ParagraphParser().parse(html), () => 'e_${n++}'));
}

void main() {
  testWidgets('弹层位移后岛 Element 复用(不 deactivate 重建)', (tester) async {
    final state = fromHtml(
        '<blockquote><p>引甲</p><p>引乙</p></blockquote>'
        '<hr>'
        '<p>尾</p>');
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: FluxdoEditor(state: state)),
      ),
    ));
    await tester.pump();

    final islandStateBefore =
        tester.state(find.byType(EditorIsland));

    // 引乙弹层:顶层列表 [壳(2块), 岛, 段] → [壳(1块), 段, 岛, 段],岛位移
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks[1].id, offset: 0)));
    state.backspace();
    await tester.pump();
    expect(tester.takeException(), isNull);

    final islandStateAfter = tester.state(find.byType(EditorIsland));
    expect(
      identical(islandStateBefore, islandStateAfter),
      isTrue,
      reason: '岛未被删除,Element/State 必须复用 —— 重建说明 children '
          'diff 因 unkeyed 成员按位置错配,真机会炸 _dependents 断言',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('壳消失后其余块 Element 复用', (tester) async {
    final state = fromHtml('<blockquote><p>引</p></blockquote><hr><p>尾</p>');
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: FluxdoEditor(state: state)),
      ),
    ));
    await tester.pump();
    final islandBefore = tester.state(find.byType(EditorIsland));

    // 唯一引用块弹层 → 壳整个消失,列表 [壳,岛,段] → [段,岛,段]
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks[0].id, offset: 0)));
    state.backspace();
    await tester.pump();
    expect(tester.takeException(), isNull);

    final islandAfter = tester.state(find.byType(EditorIsland));
    expect(identical(islandBefore, islandAfter), isTrue);
    await tester.pump(const Duration(seconds: 1));
  });
}
