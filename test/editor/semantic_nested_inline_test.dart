import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/semantic_editor.dart';

void main() {
  test('新增原子必须显式授权，授权后可无损投影', () {
    final source = SemanticNode('doc', content: [SemanticNode('paragraph', content: [SemanticNode('text', text: '正文')])]);
    final projection = SemanticEditorProjection.project(source);
    final block = projection.blocks.single as TextBlock;
    final next = block.copyWith(content: block.content.insertAtom(1, const MathInlineRun('x')));
    expect(() => projection.synchronize([next]), throwsA(isA<SemanticEditorUnsupported>()));
    final tree = projection.synchronize([next], allowNewAtoms: true);
    expect((SemanticEditorProjection.project(tree).blocks.single as TextBlock).content, next.content);
  });

  for (final type in ['underline', 'strikethrough', 'spoiler']) {
    test('$type 文本编辑保留 mark 来源属性并撤销', () {
      final source = SemanticNode('doc', content: [SemanticNode('paragraph', content: [
        SemanticNode('text', text: '甲乙', marks: [SemanticMark(type, {'未知': '保留'})]),
      ])]);
      final session = SemanticEditorSession(source);
      final block = session.editor.blocks.single;
      session.editor.updateSelection(EditorSelection.collapsed(EditorPosition(blockId: block.id, offset: 1)));
      session.editor.insertText('新');
      expect(session.tree.textContent, '甲新乙');
      expect(session.tree.content.single.content.single.marks.single.attrs['未知'], '保留');
      session.editor.undo();
      expect(session.tree, source);
      session.dispose();
    });
  }

  test('数学、脚注原子编辑与撤销保留未知属性', () {
    for (final entry in <(SemanticNode, InlineNode)>[
      (SemanticNode('math_inline', attrs: {'content': 'x', 'mathType': 'asciimath', '未知': 9}), const MathInlineRun('y')),
      (SemanticNode('footnote_ref', attrs: {'id': 0, 'label': 'a', '未知': 9}), const FootnoteRefRun(number: '1', fnId: 'fn:1', markdownLabel: 'b')),
    ]) {
      final source = SemanticNode('doc', content: [SemanticNode('paragraph', content: [entry.$1])]);
      final session = SemanticEditorSession(source);
      final block = session.editor.blocks.single as TextBlock;
      expect(block.content.atoms.length, 1);
      session.editor.replaceAtomAt(block.id, 0, entry.$2);
      expect(session.tree.content.single.content.single.attrs['未知'], 9);
      final edited = session.tree;
      if (entry.$2 is MathInlineRun) {
        expect(const SemanticDocumentCodec().serialize(edited), '%y%');
      } else {
        final withDefinition = edited.copy(content: [...edited.content,
          SemanticNode('footnote_block', content: [
            SemanticNode('footnote', attrs: {'id': 0, 'label': 'b'}, content: [
              SemanticNode('paragraph', content: [SemanticNode('text', text: '正文')]),
            ]),
          ]),
        ]);
        expect(const SemanticDocumentCodec().serialize(withDefinition), contains('[^b]'));
      }
      session.editor.undo();
      expect(session.tree, source);
      session.editor.redo();
      expect(session.tree, edited);
      session.dispose();
    }
  });
  test('check 保持可编辑字面量且回写勾选属性', () {
    final source = SemanticNode('doc', content: [SemanticNode('paragraph', content: [
      SemanticNode('check', attrs: {'checked': false, '未知': 1}),
    ])]);
    final projection = SemanticEditorProjection.project(source);
    final block = projection.blocks.single as TextBlock;
    expect(block.content.text, '[ ]');
    expect(block.content.atoms, isEmpty);
    final tree = projection.synchronize([block.copyWith(content: block.content.replace(1, 2, 'x'))]);
    expect(tree.content.single.content.single.attrs['checked'], true);
    expect(tree.content.single.content.single.attrs['未知'], 1);
  });
  test('HTML 嵌套编辑经过真实历史快照', () {
    final source = SemanticNode('doc', content: [SemanticNode('paragraph', content: [
      SemanticNode('html_inline', attrs: {'tag': 'small'}, content: [
        SemanticNode('html_inline', attrs: {'tag': 'small'}, content: [SemanticNode('text', text: '原文')]),
      ]),
    ])]);
    final session = SemanticEditorSession(source);
    final block = session.editor.blocks.single;
    session.editor.updateSelection(EditorSelection.collapsed(EditorPosition(blockId: block.id, offset: 1)));
    session.editor.insertText('新');
    expect(session.tree.textContent, '原新文');
    session.editor.undo();
    expect(session.tree, source);
    session.editor.redo();
    expect(session.tree.textContent, '原新文');
    session.dispose();
  });
  for (final tag in ['small', 'big', 'mark', 'sup', 'sub', 'kbd', 'span']) {
    for (final replacement in ['乙', '更长文字', '']) {
      test('HTML $tag 嵌套文本改为「$replacement」保留树与属性', () {
        final source = SemanticNode('doc', content: [
          SemanticNode('paragraph', content: [
            SemanticNode('text', text: '前'),
            SemanticNode('html_inline', attrs: {'tag': tag, 'htmlAttrs': {'data-x': '原'}}, content: [
              SemanticNode('html_inline', attrs: {'tag': 'small'}, content: [
                SemanticNode('text', text: '甲', attrs: {'未知': 1}),
              ]),
            ]),
            SemanticNode('text', text: '后'),
          ]),
        ]);
        final projection = SemanticEditorProjection.project(source);
        final block = projection.blocks.single as TextBlock;
        expect(block.content.text, '前甲后');
        final edited = block.content.replace(1, 2, replacement);
        final result = projection.synchronize([block.copyWith(content: edited)]);
        final outer = result.content.single.content[1];
        expect(outer.attrs, source.content.single.content[1].attrs);
        expect(outer.content.single.attrs['tag'], 'small');
        expect(outer.textContent, replacement);
        if (replacement.isNotEmpty) expect(outer.content.single.content.single.attrs['未知'], 1);
      });
    }
  }
}
