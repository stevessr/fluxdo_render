import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

SemanticNode p(String text) =>
    SemanticNode('paragraph', content: [SemanticNode('text', text: text)]);
SemanticNode doc(List<SemanticNode> children) =>
    SemanticNode('doc', content: children);

void main() {
  test('非折叠选区上传仅替换选中文本且与插入共用一个 undo 步', () {
    final s = SemanticEditorSession(
      doc([
        SemanticNode('blockquote', content: [p('左选中右')]),
      ]),
    );
    addTearDown(s.dispose);
    final id = s.editor.blocks.first.id;
    final original = s.tree.toJson();
    s.insertTransientAtSelection(
      'a',
      SemanticNode('upload'),
      selection: EditorSelection(
        base: EditorPosition(blockId: id, offset: 1),
        extent: EditorPosition(blockId: id, offset: 3),
      ),
    );
    expect(s.exportTree().textContent, '左右');
    s.editor.undo();
    expect(s.tree.toJson(), original);
    expect(s.transientBlockIds('a'), isEmpty);
    s.resolveTransientFragment('a', doc([p('附件')]));
    s.editor.redo();
    expect(s.tree.textContent, '左附件右');
    expect(s.tree.content.single.type, 'blockquote');
  });
  test('嵌套占位来源过滤整个自身但不误删父容器，多 token 路径位移稳定', () {
    final s = SemanticEditorSession(
      doc([
        SemanticNode('blockquote', content: [p('左右')]),
      ]),
    );
    addTearDown(s.dispose);
    s.insertTransientAtSelection(
      'a',
      SemanticNode('blockquote', content: [p('进度一'), p('进度二')]),
      selection: EditorSelection.collapsed(
        EditorPosition(blockId: s.editor.blocks.first.id, offset: 1),
      ),
    );
    final a = s.transientBlockIds('a');
    expect(a, hasLength(2));
    s.insertTransientAtSelection(
      'b',
      SemanticNode('upload'),
      selection: EditorSelection.collapsed(
        EditorPosition(
          blockId: s.editor.blocks.whereType<TextBlock>().last.id,
          offset: 0,
        ),
      ),
    );
    expect(s.exportTree().textContent, '左右');
    expect(s.exportTree().content.single.type, 'blockquote');
    s.resolveTransientFragment('a', doc([p('甲'), p('乙'), p('丙')]));
    expect(s.transientBlockIds('b'), hasLength(1));
    expect(s.exportTree().textContent, '左甲乙丙右');
    s.resolveTransientFragment('b', null);
    for (var i = 0; i < 2; i++) {
      s.editor.undo();
    }
    for (var i = 0; i < 2; i++) {
      s.editor.redo();
    }
    expect(s.tree.textContent, '左甲乙丙右');
    expect(s.tree.content.single.type, 'blockquote');
  });
  test('当前已撤销时仍正确替换 redo 中的来源与容器', () {
    final s = SemanticEditorSession(doc([p('正文')]));
    addTearDown(s.dispose);
    s.insertTransientAtSelection('a', SemanticNode('upload'),
      selection: EditorSelection.collapsed(
        EditorPosition(blockId: s.editor.blocks.first.id, offset: 1)));
    s.editor.undo();
    final before = s.tree.toJson();
    s.resolveTransientFragment('a', doc([
      SemanticNode('spoiler', content: [p('附件')]),
    ]));
    expect(s.tree.toJson(), before);
    s.editor.redo();
    expect(s.tree.textContent, '正附件文');
    expect(s.transientBlockIds('a'), isEmpty);
    s.editor.undo();
    expect(s.tree.toJson(), before);
    s.editor.redo();
    expect(s.tree.textContent, '正附件文');
  });
  for (final container in ['root', 'blockquote', 'bullet_list']) {
    for (final cancel in [false, true]) {
      test('$container 段中上传${cancel ? '取消' : '多附件完成'}不丢正文与历史', () {
        final body = p('左右');
        final root = container == 'root'
            ? body
            : SemanticNode(
                container,
                content: [
                  if (container == 'bullet_list')
                    SemanticNode('list_item', content: [body])
                  else
                    body,
                ],
              );
        final s = SemanticEditorSession(doc([root]));
        addTearDown(s.dispose);
        final original = s.tree.toJson();
        s.insertTransientAtSelection(
          '上传',
          SemanticNode('upload'),
          selection: EditorSelection.collapsed(
            EditorPosition(blockId: s.editor.blocks.first.id, offset: 1),
          ),
        );
        final ids = s.transientBlockIds('上传');
        expect(ids, hasLength(1));
        expect(() => ids.add('篡改'), throwsUnsupportedError);
        expect(s.exportTree().textContent, '左右');
        if (container != 'root') {
          expect(s.exportTree().content.first.type, container);
        }
        final tail = s.editor.blocks.whereType<TextBlock>().last;
        s.editor.sealHistory();
        s.editor.imeReplace(tail.id, 0, 1, '右改', caretOffset: 2);
        s.editor.undo();
        s.resolveTransientFragment(
          '上传',
          cancel ? null : doc([p('附件一'), p('附件二')]),
        );
        void valid() {
          expect(s.transientBlockIds('上传'), isEmpty);
          expect(s.tree.toJson().toString(), isNot(contains('upload')));
          expect(s.tree.textContent, contains('左'));
          expect(s.tree.textContent, contains('右'));
          expect(s.exportTree().toJson(), s.tree.toJson());
          if (container != 'root') expect(s.tree.content.first.type, container);
        }

        valid();
        expect(s.tree.textContent, cancel ? '左右' : '左附件一附件二右');
        s.editor.redo();
        valid();
        expect(s.tree.textContent, endsWith('右改'));
        s.editor.undo();
        s.editor.undo();
        expect(s.tree.toJson(), original);
        s.editor.redo();
        valid();
      });
    }
  }

  test('段中 paragraph 占位不可吞并正文；失败替换不改 current/redo', () {
    final s = SemanticEditorSession(doc([p('左右')]));
    addTearDown(s.dispose);
    s.insertTransientAtSelection(
      'a',
      p('进度'),
      selection: EditorSelection.collapsed(
        EditorPosition(blockId: s.editor.blocks.first.id, offset: 1),
      ),
    );
    expect(s.exportTree().textContent, '左右');
    s.editor.undo();
    final before = s.tree.toJson();
    expect(
      () => s.resolveTransientFragment(
        'a',
        doc([SemanticNode('text', text: '非法')]),
      ),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
    expect(s.tree.toJson(), before);
    s.editor.redo();
    expect(s.transientBlockIds('a'), hasLength(1));
    s.resolveTransientFragment('a', null);
    expect(s.tree.textContent, '左右');
  });
}
