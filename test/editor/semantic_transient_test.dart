import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

SemanticNode p(String text) =>
    SemanticNode('paragraph', content: [SemanticNode('text', text: text)]);

void main() {
  test('空文档全岛临时节点与多个不透明来源保留落点且互不影响', () {
    final session = SemanticEditorSession(SemanticNode('doc'));
    addTearDown(session.dispose);
    final unknown = SemanticNode('mock_upload', attrs: {'progress': 0});
    session.insertTransientNodeAtBlock(0, 'a', unknown);
    session.insertTransientNodeAtBlock(0, 'b', unknown);
    expect(session.exportTree().content, isEmpty);
    expect(session.editor.blocks.whereType<TextBlock>(), isNotEmpty);
    session.resolveTransient('b');
    expect(session.tree.content.single.type, 'mock_upload');
    session.resolveTransient('a');
    expect(session.tree.content, isEmpty);
    for (var i = 0; i < 2; i++) {
      session.editor.undo();
      expect(session.tree.content, isEmpty);
      expect(session.editor.blocks.whereType<TextBlock>(), isNotEmpty);
    }
    for (var i = 0; i < 2; i++) {
      session.editor.redo();
      expect(session.tree.content, isEmpty);
    }
  });
  for (final replace in [false, true]) {
    test('${replace ? '替换' : '取消'}映射全部历史且不丢用户输入与相同内容来源', () {
      final same = p('临时');
      final session = SemanticEditorSession(
        SemanticNode('doc', content: [p('左'), same, p('右')]),
      );
      addTearDown(session.dispose);
      final e = session.editor;
      session.insertTransientNodeAtBlock(1, 'mock-upload', same);
      final transientId = e.blocks[1].id;
      expect(session.exportTree().content.map((n) => n.textContent), [
        '左',
        '临时',
        '右',
      ]);
      e.imeReplace(e.blocks.last.id, 0, 1, '右改', caretOffset: 2);
      e.sealHistory();
      e.imeReplace(e.blocks.first.id, 0, 1, '左改', caretOffset: 2);
      e.undo(); // 同时存在当前、undo 和 redo 中的临时来源。
      session.resolveTransient('mock-upload', replace ? p('完成') : null);
      void valid() {
        expect(e.blocks.any((b) => b.id == transientId), isFalse);
        expect(
          session.tree.content.where((n) => n.textContent == '临时'),
          hasLength(1),
        );
        expect(session.exportTree().toJson(), session.tree.toJson());
        final selection = e.selection;
        if (selection != null) {
          for (final pos in [selection.base, selection.extent]) {
            final block = e.blocks.firstWhere((b) => b.id == pos.blockId);
            expect(pos.offset, inInclusiveRange(0, block.selectionLength));
          }
        }
      }

      valid();
      expect(session.tree.content.last.textContent, '右改');
      expect(session.tree.content.first.textContent, '左');
      e.redo();
      valid();
      expect(session.tree.content.first.textContent, '左改');
      e.undo();
      valid();
      e.undo();
      valid();
      expect(session.tree.content.last.textContent, '右');
      e.undo();
      valid();
      expect(session.tree.content.map((n) => n.textContent), ['左', '临时', '右']);
      for (var i = 0; i < 3; i++) {
        e.redo();
        valid();
      }
      expect(session.tree.content.map((n) => n.textContent), [
        '左改',
        if (replace) '完成',
        '临时',
        '右改',
      ]);
    });
  }

  test('undo 后完成仍重写 redo；多个 token 仅处理对应来源', () {
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [p('正文')]),
    );
    addTearDown(session.dispose);
    session.insertTransientNodeAtBlock(1, 'a', p('同'));
    session.insertTransientNodeAtBlock(2, 'b', p('同'));
    session.editor.undo();
    session.resolveTransient('b', p('完成'));
    expect(session.exportTree().content.map((n) => n.textContent), ['正文']);
    session.editor.redo();
    expect(session.exportTree().content.map((n) => n.textContent), [
      '正文',
      '完成',
    ]);
    session.resolveTransient('a');
    expect(session.tree.content.map((n) => n.textContent), ['正文', '完成']);
    expect(
      () => session.insertTransientNodeAtBlock(0, 'a', p('重复')),
      throwsArgumentError,
    );
  });

  test('非根边界与临时正文修改移动删除均拒绝且保持历史', () {
    final session = SemanticEditorSession(
      SemanticNode(
        'doc',
        content: [
          SemanticNode('blockquote', content: [p('一'), p('二')]),
          p('尾'),
        ],
      ),
    );
    addTearDown(session.dispose);
    expect(
      () => session.insertTransientNodeAtBlock(1, 'a', p('临时')),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
    session.insertTransientNodeAtBlock(2, 'a', p('临时'));
    final e = session.editor;
    final before = session.tree.toJson();
    expect(
      () => e.imeReplace(e.blocks[2].id, 0, 1, '改', caretOffset: 1),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(
      () => session.deleteNodesAtBlockRange(2, 3),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
    final moved = [...e.blocks];
    moved.add(moved.removeAt(2));
    expect(
      () => e.replaceBlockRange(0, e.blocks.length - 1, moved),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(session.tree.toJson(), before);
    e.undo();
    expect(session.tree.content.length, 2);
  });
}
