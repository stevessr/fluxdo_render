import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';

class MockBinding
    implements EditorDocumentBinding, EditorDocumentHistoryBinding {
  int calls = 0;
  int? failAt;
  @override
  Object prepare(Object? previousState, List<EditorBlock> blocks) =>
      List<EditorBlock>.unmodifiable(blocks);
  @override
  EditorDocumentHistorySnapshot remapHistory(
    EditorDocumentHistorySnapshot snapshot,
    Object operation,
  ) {
    calls++;
    if (calls == failAt) throw StateError('mock 历史失败');
    final blocks = snapshot.blocks.where((b) => b.id != operation).toList();
    return EditorDocumentHistorySnapshot(
      blocks,
      List<EditorBlock>.unmodifiable(blocks),
    );
  }
}

void main() {
  test('可选绑定映射失败不发布任何当前或历史变化；成功合法化选区', () {
    final binding = MockBinding();
    final e = EditorState(
      blocks: [
        TextBlock(
          id: 'a',
          content: EditableTextContent(text: '甲'),
        ),
        TextBlock(
          id: 'b',
          content: EditableTextContent(text: '乙'),
        ),
      ],
      documentBinding: binding,
    );
    addTearDown(e.dispose);
    e.imeReplace('a', 1, 1, '一', caretOffset: 2);
    e.sealHistory();
    e.imeReplace('a', 2, 2, '二', caretOffset: 3);
    e.undo();
    e.updateSelection(
      const EditorSelection.collapsed(EditorPosition(blockId: 'b', offset: 1)),
    );
    final before = e.blocks;
    final snapshot = e.documentBindingState;
    final revision = e.docRevision;
    var notified = 0;
    e.addListener(() => notified++);
    binding.failAt = 3; // redo 映射失败，当前与 undo 尚未发布。
    expect(() => e.remapDocumentHistory('b'), throwsStateError);
    expect(e.blocks, same(before));
    expect(e.documentBindingState, same(snapshot));
    expect(e.docRevision, revision);
    expect(notified, 0);
    binding.failAt = null;
    e.remapDocumentHistory('b');
    expect(notified, 1);
    expect(e.selection!.extent.blockId, 'a');
    expect(e.selection!.extent.offset, 0);
    e.redo();
    expect(e.blocks.single.id, 'a');
    expect((e.blocks.single as TextBlock).content.text, '甲一二');
    e.undo();
    e.undo();
    expect(e.blocks.single.id, 'a');
    expect((e.blocks.single as TextBlock).content.text, '甲');
  });

  test('无绑定编辑器保持原有临时历史接口', () {
    final e = EditorState.fromTexts(['正文']);
    addTearDown(e.dispose);
    e.imeReplace(e.blocks.first.id, 0, 0, '改', caretOffset: 1);
    e.forgetTransientBlockInHistory('不存在');
    e.undo();
    expect((e.blocks.first as TextBlock).content.text, '正文');
    expect(() => e.remapDocumentHistory('不存在'), throwsStateError);
  });
}
