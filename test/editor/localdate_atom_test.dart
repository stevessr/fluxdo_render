/// M5:local date 行内原子化 —— 不再把含时间 chip 的段落岛化。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/editor/widget/fluxdo_editor.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  test('含 date chip 的段落:可编辑(原子),序列化写回 [date=…]', () {
    final nodes = ParagraphParser().parse(
        '<p>开抢时间 <span class="discourse-local-date" data-date="2026-08-15" '
        'data-time="14:30" data-timezone="Asia/Shanghai">2026-08-15T06:30:00Z</span> 别迟到</p>');
    var n = 0;
    final doc = blockNodesToDoc(nodes, () => 'e_${n++}');
    expect(doc.whereType<IslandBlock>(), isEmpty, reason: '不岛化');
    final tb = doc.single as TextBlock;
    expect(tb.content.atoms.length, 1);
    expect(tb.content.atoms.values.single, isA<LocalDateRun>());
    // 原子占 1:文本 = "开抢时间 ￼ 别迟到"
    expect(tb.content.text.length, '开抢时间  别迟到'.length + 1 - 1 + 1);

    final md = docToMarkdown(doc);
    expect(md,
        '开抢时间 [date=2026-08-15 time=14:30 timezone="Asia/Shanghai"] 别迟到');
  });

  test('date 原子周围编辑:退格整删原子', () {
    final nodes = ParagraphParser().parse(
        '<p>a<span class="discourse-local-date" data-date="2026-01-01">x</span>b</p>');
    var n = 0;
    final state = EditorState(blocks: blockNodesToDoc(nodes, () => 'e_${n++}'));
    addTearDown(state.dispose);
    final tb = state.blocks.single as TextBlock;
    expect(tb.content.length, 3); // a + ￼ + b
    // 光标放原子后退格:原子整删
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: tb.id, offset: 2)));
    state.backspace();
    final after = state.blocks.single as TextBlock;
    expect(after.content.text, 'ab');
    expect(after.content.atoms, isEmpty);
  });

  testWidgets('编辑态渲染 date chip 不崩(WidgetSpan 原子)', (tester) async {
    final nodes = ParagraphParser().parse(
        '<p>时间 <span class="discourse-local-date" data-date="2026-08-15" '
        'data-time="14:30">预渲染文本</span> 后</p>');
    var n = 0;
    final state = EditorState(blocks: blockNodesToDoc(nodes, () => 'e_${n++}'));
    addTearDown(state.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: FluxdoEditor(state: state)),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('预渲染文本'), findsOneWidget);
    // 光标穿越原子(左右移动)不崩
    final tb = state.blocks.single as TextBlock;
    state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: tb.id, offset: 0)));
    for (var i = 0; i < 6; i++) {
      state.moveCaretHorizontal(1);
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });

  test('replaceAtomAt:换 date 原子属性,undo 一步', () {
    final nodes = ParagraphParser().parse(
        '<p>a<span class="discourse-local-date" data-date="2026-01-01">x</span>b</p>');
    var n = 0;
    final state = EditorState(blocks: blockNodesToDoc(nodes, () => 'e_${n++}'));
    addTearDown(state.dispose);
    final tb = state.blocks.single as TextBlock;
    state.replaceAtomAt(tb.id, 1, const LocalDateRun(
      date: '2027-05-05', time: '08:00', fallbackText: '2027-05-05 08:00',
    ));
    final after = state.blocks.single as TextBlock;
    final atom = after.content.atoms[1] as LocalDateRun;
    expect(atom.date, '2027-05-05');
    expect(atom.time, '08:00');
    // 非原子位置无操作
    state.replaceAtomAt(tb.id, 0, const LocalDateRun(date: 'x', fallbackText: 'x'));
    expect(((state.blocks.single as TextBlock).content.atoms[1] as LocalDateRun).date,
        '2027-05-05');
    state.undo();
    expect(((state.blocks.single as TextBlock).content.atoms[1] as LocalDateRun).date,
        '2026-01-01');
  });
}
