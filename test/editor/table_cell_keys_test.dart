/// 回归:表格 cell 编辑时,退格/方向键必须进 cell TextField,
/// 不能被编辑器 Focus.onKeyEvent 拦走(症状:只能覆盖不能删改)。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/widget/fluxdo_editor.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  testWidgets('提交回声到达时保留下一单元格编辑和未提交内容', (tester) async {
    var n = 0;
    final blocks = blockNodesToDoc(ParagraphParser().parse(
      '<p>正文</p><table><thead><tr><th>A</th><th>B</th></tr></thead></table>'), () => 'e_${n++}');
    final state = EditorState(blocks: blocks);
    addTearDown(state.dispose);
    String? submitted;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: FluxdoEditor(state: state, onTableEdited: (_, md) => submitted = md),
    ))));
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '新A');
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(submitted, contains('新A'));
    await tester.enterText(find.byType(EditableText), '正在写B');
    final updated = blockNodesToDoc(ParagraphParser().parse(
      '<table><thead><tr><th>新A</th><th>B</th></tr></thead></table>'), () => 'r_${n++}');
    final table = updated.first as dynamic;
    state.updateIslandNode(blocks[1].id, table.node);
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsOneWidget);
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, '正在写B');
    expect(field.focusNode.hasFocus, true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('新插入表格请求编辑后直接聚焦首格', (tester) async {
    var n = 0;
    final state = EditorState(blocks: blockNodesToDoc(
      ParagraphParser().parse('<p>正文</p><table><tbody><tr><td>首格</td><td>次格</td></tr></tbody></table>'),
      () => 'e_${n++}'));
    addTearDown(state.dispose);
    state.requestIslandEdit(state.blocks[1].id);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: FluxdoEditor(state: state, onTableEdited: (_, _) {}),
    ))));
    await tester.pump();
    await tester.pump();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, '首格');
    expect(field.focusNode.hasFocus, true);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cell 编辑中退格删字符(不被编辑器拦截)', (tester) async {
    var n = 0;
    final state = EditorState(
        blocks: blockNodesToDoc(
            ParagraphParser().parse(
                '<p>正文</p>'
                '<div class="md-table"><table><tbody><tr><td>ABC</td></tr></tbody></table></div>'),
            () => 'e_${n++}'));
    addTearDown(state.dispose);
    String? edited;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FluxdoEditor(
            state: state,
            onTableEdited: (island, md) => edited = md,
          ),
        ),
      ),
    ));
    await tester.pump();

    // 点 cell 进入编辑(初值 ABC,自动全选)
    await tester.tap(find.text('ABC'));
    await tester.pump();
    await tester.pump(); // post-frame 焦点请求
    final tf = find.byType(EditableText);
    expect(tf, findsOneWidget);

    // 光标移到末尾(取消全选),退格删一个字符
    final controller = tester.widget<EditableText>(tf).controller;
    controller.selection = TextSelection.collapsed(
        offset: controller.text.length);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, 'AB',
        reason: '退格必须删 cell 字符 —— 被编辑器 onKeyEvent 拦走则不变');

    // 方向键也不该被拦(左移后中间插入)
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(controller.selection.baseOffset, 1);

    // 编辑器文档不受牵连(正文块没被退格改掉)
    final para = state.blocks.first;
    expect((para as dynamic).content.text, '正文');

    // 提交(失焦:点正文)→ onTableEdited 收到新 markdown
    // (硬件 Enter 在 widget 测试不走 IME action,onSubmitted 不触发;
    // 真机两条路都通,失焦是共同路径)
    await tester.tap(find.textContaining('正文', findRichText: true));
    await tester.pump();
    expect(edited, isNotNull);
    expect(edited, contains('AB'));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('cell 失焦回编辑器正文:编辑器按键恢复正常', (tester) async {
    var n = 0;
    final state = EditorState(
        blocks: blockNodesToDoc(
            ParagraphParser().parse(
                '<p>xy</p>'
                '<div class="md-table"><table><tbody><tr><td>A</td></tr></tbody></table></div>'),
            () => 'e_${n++}'));
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FluxdoEditor(state: state, onTableEdited: (i, m) {}),
        ),
      ),
    ));
    await tester.pump();

    // 进 cell 再点回正文
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.textContaining('xy', findRichText: true));
    await tester.pump();

    // 正文块尾退格:编辑器处理(删 y)
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks.first.id, offset: 2)));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect((state.blocks.first as dynamic).content.text, 'x');
    await tester.pump(const Duration(seconds: 1));
  });


  testWidgets('双光标回归:cell 编辑时编辑器 caret 消失、点 cell 不动编辑器选区',
      (tester) async {
    var n = 0;
    final state = EditorState(
        blocks: blockNodesToDoc(
            ParagraphParser().parse(
                '<p>正文文字</p>'
                '<div class="md-table"><table><tbody><tr><td>CELL</td></tr></tbody></table></div>'),
            () => 'e_${n++}'));
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FluxdoEditor(state: state, onTableEdited: (i, m) {}),
        ),
      ),
    ));
    await tester.pump();

    // 先聚焦正文(光标在正文块)
    await tester.tap(find.textContaining('正文文字', findRichText: true));
    await tester.pump();
    await tester.pump();
    final selBefore = state.selection;
    expect(selBefore, isNotNull);
    expect(selBefore!.extent.blockId, state.blocks.first.id);

    // 点 cell 进入编辑:编辑器选区**不该被 tap 兜底改走**(自管区让路)
    await tester.tap(find.text('CELL'));
    await tester.pump();
    await tester.pump();
    expect(state.selection?.extent.blockId, selBefore.extent.blockId,
        reason: '点 cell 不该触发编辑器 tap 选区兜底');

    // primary focus 应在 cell 编辑框内(编辑器 caret 依
    // hasPrimaryFocus 判定 → 此刻不绘制,无双光标)
    expect(
      find.byWidgetPredicate(
          (w) => w is EditableText && w.focusNode.hasPrimaryFocus),
      findsOneWidget,
      reason: 'cell 编辑框应持有 primary focus',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('选择柄整选表格:描边 + 退格删整表', (tester) async {
    var n = 0;
    final state = EditorState(
        blocks: blockNodesToDoc(
            ParagraphParser().parse(
                '<p>前</p>'
                '<div class="md-table"><table><tbody><tr><td>T</td></tr></tbody></table></div>'),
            () => 'e_${n++}'));
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FluxdoEditor(state: state, onTableEdited: (i, m) {}),
        ),
      ),
    ));
    await tester.pump();

    // hover 表格显出选择柄
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('T')));
    await tester.pump();
    final handle = find.byIcon(Icons.drag_indicator);
    expect(handle, findsOneWidget, reason: 'hover 应显选择柄');

    // 点柄整选
    await tester.tap(handle);
    await tester.pump();
    final island = state.blocks.whereType<IslandBlock>().single;
    expect(state.selection!.base.blockId, island.id);
    expect(state.selection!.extent.offset, 1);

    // 退格删整表
    state.backspace();
    await tester.pump();
    expect(state.blocks.whereType<IslandBlock>(), isEmpty,
        reason: '整选态退格应删整个表格');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });


  testWidgets('触屏(无鼠标)cell 编辑态:行/列柄与加条常显', (tester) async {
    // 测试环境 mouseIsConnected=false,天然触屏态
    var n = 0;
    final state = EditorState(
        blocks: blockNodesToDoc(
            ParagraphParser().parse(
                '<div class="md-table"><table><tbody><tr><td>A</td><td>B</td></tr></tbody></table></div>'),
            () => 'e_${n++}'));
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FluxdoEditor(
            state: state,
            onTableEdited: (island, md) {},
          ),
        ),
      ),
    ));
    await tester.pump();

    double addBarOpacity() => tester
        .widget<AnimatedOpacity>(find.descendant(
          of: find.byTooltip('添加行'),
          matching: find.byType(AnimatedOpacity),
        ).first)
        .opacity;

    // 未编辑未选中:加条透明(不可见)
    expect(addBarOpacity(), 0);

    // 点 cell 进入编辑 → 柄/加条常显(手机加行加列的入口)
    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.pump();
    expect(addBarOpacity(), greaterThan(0));
    await tester.pump(const Duration(seconds: 1));
  });
}
