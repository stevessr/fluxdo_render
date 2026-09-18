import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/document_codec.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

void main() {
  test('相同图片来源重排删除保留各自未知属性与段落结构', () {
    final a = SemanticNode('image', attrs: {'src': '/same.png', 'alt': '模拟', 'owner': 'a'});
    final b = SemanticNode('image', attrs: {'src': '/same.png', 'alt': '模拟', 'owner': 'b'});
    final source = SemanticNode('doc', content: [SemanticNode('image_grid', attrs: {'plugin': true}, content: [
      SemanticNode('paragraph', attrs: {'paragraph': 'first'}, content: [a]),
      SemanticNode('paragraph', attrs: {'paragraph': 'second'}, content: [b]),
    ])]);
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final island = session.editor.blocks.first as IslandBlock;
    final grid = island.node as ImageGridNode;
    session.editor.updateIslandNode(island.id, ImageGridNode(id: grid.id,
        images: [grid.images[1], grid.images[0]]));
    var paragraphs = session.tree.content.single.content;
    expect(paragraphs[0].attrs['paragraph'], 'first');
    expect(paragraphs[1].attrs['paragraph'], 'second');
    expect(paragraphs[0].content.single.attrs['owner'], 'b');
    expect(paragraphs[1].content.single.attrs['owner'], 'a');
    final changed = (session.editor.blocks.first as IslandBlock).node as ImageGridNode;
    session.editor.updateIslandNode(island.id, ImageGridNode(id: changed.id, images: [changed.images[1]]));
    paragraphs = session.tree.content.single.content;
    expect(paragraphs[0].content.single.attrs['owner'], 'a');
    expect(paragraphs[1].attrs['paragraph'], 'second');
    session.editor.undo(); session.editor.undo();
    expect(session.tree, same(source));
  });

  test('块模型局部编辑保留树属性且影响导出', () {
    const codec = SemanticDocumentCodec();
    final fixtures =
        jsonDecode(
              File(
                'test/fixtures/semantic_block_bundle.json',
              ).readAsStringSync(),
            )
            as Map;
    final codeTree = codec.parseTokens(fixtures['code']['tokens'] as List);
    final source = codeTree.copy(
      content: [
        codeTree.content.single.copy(
          attrs: {
            ...codeTree.content.single.attrs,
            'unknown': {'keep': true},
          },
        ),
      ],
    );
    final view = SemanticEditorProjection.project(source);
    final block = view.blocks.first as IslandBlock;
    final edited = view.synchronize([
      IslandBlock(
        id: block.id,
        node: CodeBlockNode(id: block.id, language: 'text', code: '已编辑'),
      ),
      ...view.blocks.skip(1),
    ]);
    expect(edited.content.single.attrs['unknown'], {'keep': true});
    expect(codec.serialize(edited), contains('```text\n已编辑'));
    final grid = SemanticEditorProjection.project(
      codec.parseTokens(fixtures['grid']['tokens'] as List),
    );
    final island = grid.blocks.first as IslandBlock;
    final model = island.node as ImageGridNode;
    final changed = grid.synchronize([
      IslandBlock(
        id: island.id,
        node: ImageGridNode(
          id: model.id,
          images: model.images,
          mode: ImageGridMode.carousel,
        ),
      ),
      ...grid.blocks.skip(1),
    ]);
    expect(codec.serialize(changed), contains('[grid mode=carousel]'));
    final matrix =
        jsonDecode(
              File('test/fixtures/audit_token_matrix.json').readAsStringSync(),
            )
            as Map;
    final pollView = SemanticEditorProjection.project(
      codec.parseTokens(matrix['poll']['tokens'] as List),
    );
    final pollBlock = pollView.blocks.first as IslandBlock;
    final poll = pollBlock.node as PollNode;
    final pollTree = pollView.synchronize([
      IslandBlock(
        id: pollBlock.id,
        node: PollNode(
          id: poll.id,
          pollName: poll.pollName,
          title: poll.title,
          rawHtml: poll.rawHtml.replaceFirst('甲', '新选项'),
        ),
      ),
      ...pollView.blocks.skip(1),
    ]);
    expect(codec.serialize(pollTree), contains('新选项'));
    final table = SemanticEditorProjection.project(
      codec.parseTokens(matrix['table']['tokens'] as List),
    );
    final tableBlock = table.blocks.first as IslandBlock;
    final modelTable = tableBlock.node as TableNode;
    final tableEdit = TableNode(
      id: modelTable.id,
      columnCount: modelTable.columnCount,
      hasHeader: true,
      rows: [
        for (var r = 0; r < modelTable.rows.length; r++)
          [
            for (var c = 0; c < modelTable.rows[r].length; c++)
              r == 1 && c == 0
                  ? TableCellData(
                      isHeader: false,
                      children: [
                        ParagraphNode(
                          id: 'cell',
                          inlines: const [TextRun('新单元格')],
                        ),
                      ],
                    )
                  : modelTable.rows[r][c],
          ],
      ],
    );
    final output = table.synchronize([
      IslandBlock(id: tableBlock.id, node: tableEdit),
      ...table.blocks.skip(1),
    ]);
    expect(codec.serialize(output), contains('新单元格'));
  });
  test('真实 bundle 网格、空节点、嵌套与代码', () {
    const codec = SemanticDocumentCodec();
    final fixtures =
        jsonDecode(
              File(
                'test/fixtures/semantic_block_bundle.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final entry in fixtures.entries) {
      final tree = codec.parseTokens(entry.value['tokens'] as List);
      final view = SemanticEditorProjection.project(tree);
      expect(
        codec.serialize(view.synchronize(view.blocks)),
        codec.serialize(tree),
        reason: entry.key,
      );
      expect(codec.serialize(tree), isNotEmpty, reason: entry.key);
    }
  });

  test('真实 bundle 基础块矩阵可解析、投影和序列化', () {
    final matrix =
        jsonDecode(
              File('test/fixtures/audit_token_matrix.json').readAsStringSync(),
            )
            as Map;
    const codec = SemanticDocumentCodec();
    for (final key in [
      'table',
      'tableAlign',
      'emptySpoiler',
      'mathBlock',
      'spoilerInline',
    ]) {
      final fixture = matrix[key] as Map;
      final tree = codec.parseTokens(fixture['tokens'] as List);
      final view = SemanticEditorProjection.project(tree);
      expect(
        codec.serialize(view.synchronize(view.blocks)),
        codec.serialize(tree),
        reason: key,
      );
    }
    for (final key in [
      'mathAscii',
      'mathTex',
      'footnote',
      'check',
      'bbUnderline',
      'bbStrike',
      'htmlNested',
      'htmlUnderline',
    ]) {
      final tree = codec.parseTokens(matrix[key]['tokens'] as List);
      expect(codec.serialize(tree), isNotEmpty, reason: key);
      final view = SemanticEditorProjection.project(tree);
      expect(
        codec.serialize(view.synchronize(view.blocks)),
        codec.serialize(tree),
        reason: key,
      );
    }
    for (final entry in matrix.entries) {
      if (!(entry.value['tokens'] as List).any((t) => t['type'] == 'poll_open'))
        continue;
      final tree = codec.parseTokens(entry.value['tokens'] as List);
      expect(codec.serialize(tree), contains('[poll'));
      expect(SemanticEditorProjection.project(tree).blocks, isNotEmpty);
    }
  });
}
