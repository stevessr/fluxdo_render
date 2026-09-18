import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  EditableTextContent source() => EditableTextContent.fromInlines(const [
    TextRun('甲'), LineBreakRun(soft: true), TextRun('乙'),
    LineBreakRun(), TextRun('丙'),
  ]);

  test('软硬换行经文档转换及序列化保持来源', () {
    final doc = blockNodesToDoc([
      ParagraphNode(id: 'p', inlines: source().toInlines()),
    ], () => 'e_0');
    final state = EditorState(blocks: doc);
    addTearDown(state.dispose);
    expect(state.exportMarkdown(), '甲\n乙  \n丙');
    final back = docToBlockNodes(doc).single as ParagraphNode;
    expect(back.inlines.whereType<LineBreakRun>().map((n) => n.soft),
        [true, false]);
    expect(const LineBreakRun(soft: true), isNot(const LineBreakRun()));
  });

  test('编辑原语平移、删除、切分、合并及格式命令保留软换行', () {
    final c = source().insert(1, '新');
    expect(c.softBreaks, {2});
    expect(c.insert(2, '\n').softBreaks, {3});
    expect(c.delete(0, 1).softBreaks, {1});
    expect(c.delete(2, 3).softBreaks, isEmpty);
    expect(c.replace(2, 3, '\n').softBreaks, isEmpty);
    final (a, b) = c.split(2);
    expect(a.softBreaks, isEmpty);
    expect(b.softBreaks, {0});
    expect(a.concat(b), c);
    expect(c.slice(1, 4).softBreaks, {1});
    expect(c.applyMark(0, c.length, MarkKind.strong)
        .removeMark(0, c.length, MarkKind.strong), c);
  });

  test('IR 显形、编辑、导出及撤销不将 softbreak 改成硬换行', () {
    final state = EditorState(blocks: [TextBlock(id: 'e_0', content:
      source().applyMark(0, 1, MarkKind.strong))]);
    addTearDown(state.dispose);
    state.mode = EditorMode.ir;
    state.materializeMarkAt('e_0',
      (state.blocks.single as TextBlock).content.marks.single,
      caretOffset: 3);
    expect(state.exportMarkdown(), '**甲**\n乙  \n丙');
    expect((state.blocks.single as TextBlock).content.softBreaks, {5});
    state.insertText('新');
    expect(state.exportMarkdown(), '**甲新**\n乙  \n丙');
    state.undo();
    expect(state.exportMarkdown(), '**甲**\n乙  \n丙');
    state.mode = EditorMode.wysiwyg;
    expect(state.exportMarkdown(), '**甲**\n乙  \n丙');
  });
}
