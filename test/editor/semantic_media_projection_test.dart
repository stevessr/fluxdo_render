import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

void main() {
  test('非法媒体地址和尺寸不进入播放器及树快照', () {
    for (final attrs in [
      {'src': 'javascript:alert(1)'},
      {'src': '/v', 'width': double.infinity},
      {'src': '/v', 'height': -1},
    ]) {
      final projection = SemanticEditorProjection.project(
        SemanticNode('doc', content: [SemanticNode('video', attrs: attrs)]),
      );
      expect(
        (projection.blocks.first as IslandBlock).node,
        isA<CodeBlockNode>(),
      );
    }
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode('video', attrs: {'src': '/v'}),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final island = session.editor.blocks.first as IslandBlock;
    expect(
      () => session.editor.updateIslandNode(
        island.id,
        VideoNode(id: island.id, src: 'javascript:alert(1)'),
      ),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(session.tree.toJson(), source.toJson());
    expect((session.editor.blocks.first as IslandBlock).node, island.node);
  });
  for (final type in ['video', 'audio']) {
    for (final raw in [false, true]) {
      test('$type raw=$raw 媒体修改、旁段、容器与撤销保源', () {
        final html =
            '<$type controls data-extra="保留"><source src="/old" '
            'type="$type/mp4" data-extra="源"><source src="/alternate">'
            '<track src="/sub">'
            '<a href="/old">标题</a></$type>';
        final media = raw
            ? SemanticNode(
                'html_block',
                attrs: {'extra': 3},
                content: [
                  SemanticNode('text', text: html, attrs: {'origin': 7}),
                ],
              )
            : SemanticNode(type, attrs: {'src': '/old', 'extra': 3});
        final source = SemanticNode(
          'doc',
          content: [
            SemanticNode(
              'quote',
              attrs: {'extra': 9},
              content: [
                SemanticNode(
                  'details',
                  attrs: {'extra': 8},
                  content: [
                    SemanticNode(
                      'summary',
                      content: [SemanticNode('text', text: '摘要')],
                    ),
                    media,
                    SemanticNode(
                      'paragraph',
                      content: [SemanticNode('text', text: '旁段')],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        final session = SemanticEditorSession(source);
        addTearDown(session.dispose);
        final island = session.editor.blocks.whereType<IslandBlock>().single;
        expect(
          island.node,
          type == 'video' ? isA<VideoNode>() : isA<AudioNode>(),
        );
        expect(session.tree.toJson(), source.toJson());
        session.editor.updateIslandNode(island.id, island.node);
        expect(session.tree.toJson(), source.toJson());
        final text = session.editor.blocks.whereType<TextBlock>().single;
        session.editor.imeReplace(text.id, 0, 0, '新', caretOffset: 1);
        expect(
          session.tree.content.single.content.single.content[1],
          same(media),
        );
        session.editor.undo();
        expect(session.tree.toJson(), source.toJson());
        session.editor.updateIslandNode(
          island.id,
          type == 'video'
              ? VideoNode(
                  id: island.id,
                  src: '/old',
                  mime: raw ? 'video/mp4' : null,
                  poster: '/poster',
                )
              : AudioNode(
                  id: island.id,
                  src: '/old',
                  mime: raw ? 'audio/mp4' : null,
                  title: '新标题',
                ),
        );
        final changed = session.tree.content.single.content.single.content[1];
        expect(changed.type, media.type);
        if (raw) {
          expect(changed.attrs, media.attrs);
          expect(changed.content.single.attrs, media.content.single.attrs);
          expect(changed.textContent, contains('<track src="/sub">'));
          expect(changed.textContent, contains('<source src="/alternate">'));
          expect(changed.textContent, contains('data-extra="源"'));
          expect(changed.textContent, contains('controls'));
        } else {
          expect(changed.attrs, {
            ...media.attrs,
            if (type == 'video') 'poster': '/poster' else 'title': '新标题',
          });
        }
        session.editor.undo();
        expect(session.tree.toJson(), source.toJson());
      });
    }
  }
  for (final type in ['video', 'audio']) {
    for (final listType in ['bullet_list', 'ordered_list']) {
      test('$type 在 $listType 多段项中更新不拆父容器并保留未知来源', () {
        final media = SemanticNode(type, attrs: {'src': '/old', 'extra': 3});
        final unknown = SemanticNode('future_block', attrs: {'opaque': true});
        final paragraph = SemanticNode(
          'paragraph',
          attrs: {'origin': '旁段'},
          content: [SemanticNode('text', text: '旁段')],
        );
        final item = SemanticNode(
          'list_item',
          attrs: {'origin': '列表项'},
          content: [paragraph, media, unknown, paragraph],
        );
        final list = SemanticNode(
          listType,
          attrs: {
            'extra': 5,
            'tight': false,
            if (listType == 'ordered_list') 'order': 7,
          },
          content: [item],
        );
        final details = SemanticNode(
          'details',
          attrs: {'extra': 8},
          content: [
            SemanticNode(
              'summary',
              content: [SemanticNode('text', text: '摘要')],
            ),
            list,
          ],
        );
        final quote = SemanticNode(
          'quote',
          attrs: {'extra': 9},
          content: [details],
        );
        final source = SemanticNode('doc', content: [quote]);
        final session = SemanticEditorSession(source);
        addTearDown(session.dispose);
        final island = session.editor.blocks
            .whereType<IslandBlock>()
            .firstWhere(
              (block) => block.node is VideoNode || block.node is AudioNode,
            );
        final ids = session.editor.blocks.map((block) => block.id).toList();
        session.editor.updateIslandNode(
          island.id,
          type == 'video'
              ? VideoNode(id: island.id, src: '/new')
              : AudioNode(id: island.id, src: '/new'),
        );
        final expected = source.copy(
          content: [
            quote.copy(
              content: [
                details.copy(
                  content: [
                    details.content.first,
                    list.copy(
                      content: [
                        item.copy(
                          content: [
                            paragraph,
                            media.copy(attrs: {...media.attrs, 'src': '/new'}),
                            unknown,
                            paragraph,
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        expect(session.tree.toJson(), expected.toJson());
        final changedItem = session
            .tree
            .content
            .single
            .content
            .single
            .content[1]
            .content
            .single;
        expect(changedItem.content[0], same(paragraph));
        expect(changedItem.content[2], same(unknown));
        expect(changedItem.content[3], same(paragraph));
        expect(session.editor.blocks.map((block) => block.id), ids);
        session.editor.undo();
        expect(session.tree.toJson(), source.toJson());
        session.editor.redo();
        expect(session.tree.toJson(), expected.toJson());
      });
    }
  }
  testWidgets('媒体岛通过真实播放器构建而非代码块', (tester) async {
    final session = SemanticEditorSession(
      SemanticNode(
        'doc',
        content: [
          SemanticNode('video', attrs: {'src': '/v'}),
          SemanticNode('audio', attrs: {'src': '/a', 'title': '测试音频'}),
        ],
      ),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FluxdoEditor(state: session.editor)),
      ),
    );
    expect(find.textContaining('不透明语义节点'), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.audiotrack_rounded), findsOneWidget);
    expect(find.text('测试音频'), findsOneWidget);
  });
}
