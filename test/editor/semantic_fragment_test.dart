import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';

SemanticNode paragraph(String text) => SemanticNode(
  'paragraph',
  attrs: {'extra': text},
  content: [SemanticNode('text', text: text)],
);

void main() {
  test('显式计划在通知前消费，失败片段不影响后续插入', () {
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [paragraph('旧')]),
    );
    addTearDown(session.dispose);
    // 监听器在提交后的同步通知中也不能复用刚消费的授权。
    var called = false;
    void listener() {
      if (called) return;
      called = true;
      expect(
        () => session.editor.replaceBlockRange(
          0,
          session.editor.blocks.length - 1,
          [
            TextBlock(
              id: 'forged',
              content: EditableTextContent(text: '伪造'),
            ),
          ],
        ),
        throwsA(isA<EditorDocumentRejection>()),
      );
    }

    session.editor.addListener(listener);
    session.insertNodeAtBlock(1, paragraph('一'));
    session.editor.removeListener(listener);
    expect(called, isTrue);
    expect(
      () => session.insertFragmentAtBlock(
        0,
        SemanticNode('doc', content: [SemanticNode('text', text: '裸文本')]),
      ),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
    session.insertNodeAtBlock(2, paragraph('二'));
    expect(session.tree.content.map((n) => n.textContent), ['旧', '一', '二']);
  });

  test('连续插入后新节点编辑和多轮撤销重做保留不透明来源', () {
    final opaque = SemanticNode(
      'unrecognized_media',
      attrs: {'src': '/asset', 'extra': 7},
    );
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [paragraph('旧'), opaque]),
    );
    addTearDown(session.dispose);
    session.insertNodeAtBlock(1, paragraph('一'));
    session.insertNodeAtBlock(2, paragraph('二'));
    final id = session.editor.blocks[2].id;
    session.editor.imeReplace(id, 0, 1, '改', caretOffset: 1);
    expect(session.tree.content[2].textContent, '改');
    expect(identical(session.tree.content.last, opaque), isTrue);
    session.editor.undo();
    expect(session.tree.content[2].textContent, '二');
    session.editor.undo();
    expect(session.tree.content.length, 3);
    session.editor.undo();
    expect(session.tree.content.length, 2);
    session.editor.redo();
    session.editor.redo();
    session.editor.redo();
    expect(session.tree.content[2].textContent, '改');
    expect(session.editor.blocks[2].id, id);
    expect(identical(session.tree.content.last, opaque), isTrue);
  });
  test('显式片段保留节点属性、稳定 id，并与实际 state 历史一起恢复', () {
    final source = SemanticNode(
      'doc',
      content: [paragraph('甲'), paragraph('乙')],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final ids = session.editor.blocks.map((b) => b.id).toList();
    final fragment = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'unknown',
          attrs: {
            'opaque': {'keep': true},
          },
        ),
        paragraph('新'),
      ],
    );
    session.insertFragmentAtBlock(1, fragment);
    expect(session.editor.blocks.first.id, ids.first);
    expect(session.editor.blocks.last.id, ids.last);
    expect(session.tree.content[1].toJson(), fragment.content.first.toJson());
    final insertedIds = session.editor.blocks.map((b) => b.id).toList();
    session.editor.undo();
    expect(session.tree.toJson(), source.toJson());
    expect(session.editor.blocks.map((b) => b.id), ids);
    session.editor.redo();
    expect(session.editor.blocks.map((b) => b.id), insertedIds);
    session.deleteNodesAtBlockRange(1, 3);
    expect(session.tree.toJson(), source.toJson());
    session.editor.undo();
    expect(session.tree.content.length, 4);
  });

  test('相邻相同容器不合并、复制不丢未知属性，容器内部边界拒绝', () {
    final quote = SemanticNode(
      'blockquote',
      attrs: {'hidden': 4},
      content: [paragraph('一'), paragraph('二')],
    );
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [quote]),
    );
    addTearDown(session.dispose);
    final copied = session.copyFragmentAtBlockRange(0, 2);
    expect(copied.content.single.toJson(), quote.toJson());
    expect(
      () => session.insertFragmentAtBlock(1, copied),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
    session.insertFragmentAtBlock(0, copied);
    expect(session.tree.content.length, 2);
    final blocks = session.editor.blocks.cast<TextBlock>();
    expect(
      blocks.first.containers.single.groupId,
      isNot(blocks.last.containers.single.groupId),
    );
    session.editor.imeReplace(blocks.last.id, 0, 1, '三', caretOffset: 1);
    expect(session.tree.content.last.attrs, quote.attrs);
    expect(session.tree.content.first.toJson(), quote.toJson());
  });

  test('删除全部节点保留虚拟落点、撤销恢复来源', () {
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [paragraph('一')]),
    );
    addTearDown(session.dispose);
    session.deleteNodesAtBlockRange(0, 1);
    expect(session.tree.content, isEmpty);
    expect(session.editor.blocks, hasLength(1));
    session.insertNodeAtBlock(0, paragraph('二'));
    expect(session.tree.content.single.textContent, '二');
    session.editor.undo();
    expect(session.tree.content, isEmpty);
    session.editor.undo();
    expect(session.tree.content.single.textContent, '一');
  });

  test('显式调用之外的整文档新块仍无来源且拒绝，不污染历史', () {
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [paragraph('旧')]),
    );
    addTearDown(session.dispose);
    session.insertNodeAtBlock(1, paragraph('新'));
    final tree = session.tree.toJson();
    expect(
      () => session.editor.replaceBlockRange(
        0,
        session.editor.blocks.length - 1,
        [
          TextBlock(
            id: 'unknown_source',
            content: EditableTextContent(text: '随意'),
          ),
        ],
      ),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(session.tree.toJson(), tree);
    session.editor.undo();
    expect(session.tree.content.single.textContent, '旧');
  });
}
