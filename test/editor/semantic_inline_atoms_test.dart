import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show NodeFactory;
import 'package:fluxdo_render/editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/node/node.dart';

void main() {
  test('显式插入链接保留原子身份、完整来源与撤销', () {
    for (final source in [null, (isAutoLink: null), (isAutoLink: false), (isAutoLink: true)]) {
      for (final angle in [false, true]) {
        for (final attachment in [false, true]) {
          final tree = SemanticNode('doc', content: [SemanticNode('paragraph')]);
          final session = SemanticEditorSession(tree);
          session.editor.updateSelection(EditorSelection.collapsed(
            EditorPosition(blockId: session.editor.blocks.single.id, offset: 0)));
          final atom = LinkRun(
            href: 'https://example.test/a', children: const [TextRun('链接')],
            editorLinkTitle: '标题', isAttachment: attachment,
            filename: attachment ? '文件' : '', origHref: 'upload://a',
            editorAngleLink: angle, editorLinkSource: source,
          );
          session.editor.insertAtom(atom);
          final node = session.tree.content.single.content.single;
          expect(node.type, 'text');
          expect(node.marks.single.attrs['isAtom'], true);
          expect(node.marks.single.attrs['title'], '标题');
          final projected = SemanticEditorProjection.project(session.tree);
          expect((projected.blocks.single as TextBlock).content.atoms[0], atom);
          session.editor.sealHistory();
          final block = session.editor.blocks.single as TextBlock;
          session.editor.editLinkAtomAt(block.id, 0, text: '修改', href: 'https://example.test/b');
          expect((session.editor.blocks.single as TextBlock).content.atoms[0], isA<LinkRun>());
          session.editor.undo();
          expect((session.editor.blocks.single as TextBlock).content.atoms[0], atom);
          session.editor.undo();
          expect(session.tree, same(tree));
          session.dispose();
        }
      }
    }
  });

  test('新增链接未知子节点及未映射属性明确拒绝且不污染树', () {
    for (final atom in [
      const LinkRun(href: '/a', children: [MathInlineRun('x')]),
      const LinkRun(href: '/a', children: [TextRun('链接')], hashtagRef: '标签'),
    ]) {
      final tree = SemanticNode('doc', content: [SemanticNode('paragraph')]);
      final session = SemanticEditorSession(tree);
      session.editor.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: session.editor.blocks.single.id, offset: 0)));
      expect(() => session.editor.insertAtom(atom), throwsA(isA<EditorDocumentRejection>()));
      expect(session.tree, same(tree));
      session.dispose();
    }
  });

  test('图片与 emoji URL 使用媒体安全边界，非法导入 opaque、编辑拒绝', () {
    for (final url in [
      'javascript:alert(1)',
      'data:image/png;base64,a',
      'blob:https://a/b',
      '',
    ]) {
      for (final node in [
        SemanticNode('image', attrs: {'src': url}),
        SemanticNode('image', attrs: {'src': '/a', 'data-orig-src': url}),
        SemanticNode('emoji', attrs: {'name': 'a', 'url': url}),
      ]) {
        final source = SemanticNode(
          'doc',
          content: [
            SemanticNode('paragraph', content: [node]),
          ],
        );
        expect(
          SemanticEditorProjection.project(source).blocks.first,
          isA<IslandBlock>(),
        );
      }
      final source = SemanticNode(
        'doc',
        content: [
          SemanticNode(
            'paragraph',
            content: [
              SemanticNode('image', attrs: {'src': '/a'}),
            ],
          ),
        ],
      );
      final session = SemanticEditorSession(source);
      final block = session.editor.blocks.first as TextBlock;
      expect(
        () => session.editor.replaceAtomAt(block.id, 0, ImageRun(src: url)),
        throwsA(isA<EditorDocumentRejection>()),
      );
      expect(session.tree, same(source));
      expect(
        (session.editor.blocks.first as TextBlock).content.atoms[0],
        const ImageRun(src: '/a'),
      );
      session.dispose();
    }
  });

  test('图片前后 split 保留原节点未知属性并可撤销', () {
    for (final offset in [1, 2]) {
      final image = SemanticNode(
        'image',
        attrs: {'src': '/a', 'title': '图片', '未知': 7},
      );
      final source = SemanticNode(
        'doc',
        content: [
          SemanticNode(
            'paragraph',
            content: [
              SemanticNode('text', text: '前'),
              image,
              SemanticNode('text', text: '后'),
            ],
          ),
        ],
      );
      final session = SemanticEditorSession(source);
      final block = session.editor.blocks.first as TextBlock;
      session.editor.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: block.id, offset: offset),
        ),
      );
      session.editor.splitBlock();
      expect(
        session.tree.content
            .expand((n) => n.content)
            .where((n) => n.type == 'image')
            .single,
        same(image),
      );
      session.editor.undo();
      expect(session.tree, same(source));
      session.dispose();
    }
  });

  test('删除相邻图片首项保留第二项来源及未知属性', () {
    for (final sameSrc in [false, true]) {
      final first = SemanticNode('image', attrs: {'src': '/a', '未知': 1});
      final second = SemanticNode(
        'image',
        attrs: {'src': sameSrc ? '/a' : '/b', '未知': 2},
      );
      final source = SemanticNode(
        'doc',
        content: [
          SemanticNode('paragraph', content: [first, second]),
        ],
      );
      final session = SemanticEditorSession(source);
      final block = session.editor.blocks.single as TextBlock;
      session.editor.imeReplace(block.id, 0, 1, '', caretOffset: 0);
      expect(session.tree.content.single.content.single, same(second));
      session.editor.undo();
      expect(session.tree, same(source));
      session.dispose();
    }
  });

  test('非法已知属性保守变为不透明节点，不抛类型异常', () {
    final cases = <SemanticNode>[
      for (final field in [
        'alt',
        'width',
        'height',
        'origWidth',
        'origHeight',
        'scale',
        'title',
        'filename',
        'naturalWidth',
      ])
        SemanticNode('image', attrs: {'src': '/a', field: <String>[]}),
      SemanticNode('image', attrs: {'src': '/a', 'width': double.nan}),
      SemanticNode(
        'emoji',
        attrs: {'name': 'a', 'url': '/a', 'isOnlyEmoji': 'true'},
      ),
      for (final field in [
        'fallbackText',
        'time',
        'timezone',
        'timezones',
        'countdown',
        'endDate',
      ])
        SemanticNode(
          'local_date',
          attrs: {
            'date': '2026-01-01',
            field: [1],
          },
        ),
      for (final field in [
        'title',
        'filename',
        'attachment',
        'markup',
        'data-orig-href',
      ])
        SemanticNode(
          'text',
          text: '附件',
          marks: [
            SemanticMark('link', {'href': '/a', field: 1}),
          ],
        ),
    ];
    for (final node in cases) {
      final tree = SemanticNode(
        'doc',
        content: [
          SemanticNode('paragraph', content: [node]),
        ],
      );
      final projection = SemanticEditorProjection.project(tree);
      expect(
        projection.blocks.first,
        isA<IslandBlock>(),
        reason: node.attrs.toString(),
      );
      expect(projection.synchronize(projection.blocks), same(tree));
    }
  });

  test('图片完整尺寸回写、重投影及未映射编辑校验不丢未知属性', () {
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode(
              'image',
              attrs: {
                'src': '/a',
                'title': '原始标题',
                'width': 100,
                'height': 80,
                'origWidth': 200,
                'origHeight': 160,
                'scale': 50,
                'naturalWidth': 400,
                'naturalHeight': 320,
                'filename': 'a.png',
                'fileSizeText': '1 KB',
                'lightboxUrl': '/original',
                '扩展': {
                  '嵌套': [1, true],
                },
              },
            ),
          ],
        ),
      ],
    );
    final projection = SemanticEditorProjection.project(source);
    final block = projection.blocks.single as TextBlock;
    final image = block.content.atoms[0] as ImageRun;
    expect(image.origWidth, 200);
    expect(image.naturalHeight, 320);
    expect(image.filename, 'a.png');
    final next = image.copyWith(scale: 75, width: 150, height: 120);
    final edited = block.copyWith(
      content: EditableTextContent(text: kAtomChar, atoms: {0: next}),
    );
    final snapshot = projection.synchronizeSnapshot([edited]);
    final tree = snapshot.synchronize(snapshot.blocks);
    final attrs = tree.content.single.content.single.attrs;
    expect(attrs['title'], '原始标题');
    expect(attrs['扩展'], source.content.single.content.single.attrs['扩展']);
    expect((snapshot.blocks.single as TextBlock).content.atoms[0], next);
    expect(
      () => projection.synchronize([
        block.copyWith(
          content: EditableTextContent(
            text: kAtomChar,
            atoms: {0: const ImageRun(src: '/a', indexInPost: 99)},
          ),
        ),
      ]),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
    expect(projection.synchronize(projection.blocks), same(source));
  });

  testWidgets('真实图片点选后宿主缩放工具回写语义树并通过工具撤销', (tester) async {
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode(
              'image',
              attrs: {
                'src': '/placeholder',
                'alt': '图片',
                'title': '图片标题',
                'width': 100,
                'height': 80,
                '未知': 7,
              },
            ),
          ],
        ),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    ImageAtomSelection? selected;
    const imageKey = ValueKey('语义图片');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: FluxdoEditor(
                  state: session.editor,
                  autofocus: true,
                  nodeFactory: NodeFactory(
                    imageContentBuilder: (_, image, total) => SizedBox(
                      key: imageKey,
                      width: image.width,
                      height: image.height,
                      child: const ColoredBox(color: Colors.blue),
                    ),
                  ),
                  onImageAtomSelectionChanged: (value) => selected = value,
                ),
              ),
              TextButton(
                onPressed: () {
                  final target = selected!;
                  session.editor.replaceAtomAt(
                    target.blockId,
                    target.offset,
                    target.image.copyWith(
                      scale: 50,
                      origWidth: 100,
                      origHeight: 80,
                      width: 50,
                      height: 40,
                    ),
                  );
                },
                child: const Text('缩放图片'),
              ),
              TextButton(
                onPressed: session.editor.undo,
                child: const Text('撤销'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.byKey(imageKey)));
    await tester.pump();
    await tester.pump();
    expect(selected, isNotNull);
    expect(selected!.globalRect.size, const Size(100, 80));
    await tester.tap(find.text('缩放图片'));
    await tester.pump();
    await tester.pump();
    final attrs = session.tree.content.single.content.single.attrs;
    expect(attrs['scale'], 50);
    expect(attrs['origWidth'], 100);
    expect(attrs['origHeight'], 80);
    expect(attrs['title'], '图片标题');
    expect(attrs['未知'], 7);
    expect(tester.getSize(find.byKey(imageKey)), const Size(50, 40));
    await tester.tap(find.text('撤销'));
    await tester.pump();
    expect(session.tree, same(source));
    expect(tester.getSize(find.byKey(imageKey)), const Size(100, 80));
  });

  for (final markup in ['attachment', 'autolink', 'linkify']) {
    testWidgets('真实 $markup 链接点选、工具编辑保留 title 与撤销', (tester) async {
      final source = SemanticNode(
        'doc',
        content: [
          SemanticNode(
            'paragraph',
            content: [
              SemanticNode(
                'text',
                text: '附件文字',
                attrs: {'文本扩展': 8},
                marks: [
                  SemanticMark('link', {
                    'href': 'https://old.test',
                    'title': '附件标题',
                    '未知': 9,
                    if (markup == 'attachment') ...{
                      'attachment': true,
                      'filename': '原始文件',
                      'data-orig-href': 'upload://old',
                    } else
                      'markup': markup,
                  }),
                ],
              ),
            ],
          ),
        ],
      );
      final session = SemanticEditorSession(source);
      addTearDown(session.dispose);
      LinkCaretInfo? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: FluxdoEditor(
                    state: session.editor,
                    autofocus: true,
                    onLinkCaret: (value) => selected = value,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    final target = selected!;
                    session.editor.editLinkAtomAt(
                      target.blockId,
                      target.start,
                      text: '新附件',
                      href: 'https://new.test',
                    );
                  },
                  child: const Text('编辑链接'),
                ),
                TextButton(
                  onPressed: session.editor.undo,
                  child: const Text('撤销'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final rendered = find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().contains('附件文字'),
      );
      final paragraph = tester.renderObject<RenderParagraph>(rendered.first);
      final start = paragraph.text.toPlainText().indexOf('附件文字');
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 4),
      );
      await tester.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
      await tester.pump();
      await tester.pump();
      expect(selected, isNotNull);
      expect(session.editor.selection!.isCollapsed, false);
      await tester.tap(find.text('编辑链接'));
      await tester.pump();
      final node = session.tree.content.single.content.single;
      expect(node.text, '新附件');
      expect(node.attrs['文本扩展'], 8);
      expect(node.marks.single.attrs['href'], 'https://new.test');
      expect(node.marks.single.attrs['title'], '附件标题');
      expect(node.marks.single.attrs['未知'], 9);
      if (markup == 'attachment') {
        expect(node.marks.single.attrs['attachment'], true);
      }
      expect(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('新附件'),
        ),
        findsWidgets,
      );
      await tester.tap(find.text('撤销'));
      await tester.pump();
      expect(session.tree, same(source));
      expect(rendered, findsWidgets);
    });
  }

  test('图片旁输入、删除和原子属性编辑与 undo 同步原树', () {
    final child = SemanticNode('插件元数据', attrs: {'未知': 1});
    final image = SemanticNode(
      'image',
      attrs: {'src': 'upload://a', 'alt': '原图', '未知': 9},
      content: [child],
    );
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode('text', text: '甲'),
            image,
            SemanticNode('text', text: '乙'),
          ],
        ),
      ],
    );
    final session = SemanticEditorSession(source);
    addTearDown(session.dispose);
    final editor = session.editor;
    final block = editor.blocks.first as TextBlock;
    expect(block.content.atoms[1], isA<ImageRun>());
    editor.imeReplace(block.id, 1, 1, '新', caretOffset: 2);
    expect(session.tree.content.single.content[1], same(image));
    editor.sealHistory();
    editor.replaceAtomAt(
      block.id,
      2,
      const ImageRun(src: 'upload://a', alt: '改图'),
    );
    final updated = session.tree.content.single.content[1];
    expect(updated.attrs['alt'], '改图');
    expect(updated.attrs['未知'], 9);
    expect(updated.content.single, same(child));
    editor.undo();
    expect(session.tree.content.single.content[1], same(image));
    editor.undo();
    expect(session.tree, same(source));
    editor.imeReplace(block.id, 0, 1, '', caretOffset: 0);
    expect(session.tree.content.single.content.first, same(image));
  });

  test('特殊链接 atom 使用现有 editLinkAtomAt 回写并保留未知 attrs', () {
    for (final markup in ['autolink', 'linkify']) {
      final link = SemanticNode(
        'text',
        text: 'https://old',
        attrs: {'元数据': 1},
        marks: [
          SemanticMark('link', {
            'href': 'https://old',
            'title': '标题',
            'markup': markup,
            '未知': 7,
          }),
        ],
      );
      final source = SemanticNode(
        'doc',
        content: [
          SemanticNode('paragraph', content: [link]),
        ],
      );
      final session = SemanticEditorSession(source);
      final block = session.editor.blocks.first as TextBlock;
      expect(block.content.atoms[0], isA<LinkRun>());
      session.editor.editLinkAtomAt(
        block.id,
        0,
        text: 'https://new',
        href: 'https://new',
      );
      final next = session.tree.content.single.content.single;
      expect(next.text, 'https://new');
      expect(next.marks.single.attrs['title'], '标题');
      expect(next.marks.single.attrs['未知'], 7);
      expect(next.attrs, link.attrs);
      session.editor.undo();
      expect(session.tree, same(source));
      session.dispose();
    }
  });

  test('日期范围、emoji 和 mention 投影可编辑并保未知子树', () {
    final nodes = [
      SemanticNode('emoji', attrs: {'name': 'smile', 'url': '/emoji', '未知': 1}),
      SemanticNode(
        'mention',
        attrs: {'username': 'alice', 'href': '/u/alice', '未知': 2},
      ),
      SemanticNode(
        'local_date',
        attrs: {
          'date': '2026-04-01',
          'endDate': '2026-04-02',
          'time': '12:00',
          'endTime': '13:00',
          'timezone': 'Asia/Shanghai',
          'timezones': ['UTC'],
          'countdownRaw': 'false',
          'recurring': '1.months',
          'range': 'from',
          '未知': 3,
        },
      ),
    ];
    final session = SemanticEditorSession(
      SemanticNode('doc', content: [SemanticNode('paragraph', content: nodes)]),
    );
    addTearDown(session.dispose);
    final block = session.editor.blocks.first as TextBlock;
    expect(block.content.atoms.length, 3);
    expect((block.content.atoms[2] as LocalDateRun).endDate, '2026-04-02');
    session.editor.replaceAtomAt(
      block.id,
      0,
      const EmojiRun(name: 'heart', url: '/heart'),
    );
    expect(session.tree.content.single.content[0].attrs['name'], 'heart');
    expect(session.tree.content.single.content[1], same(nodes[1]));
    expect(session.tree.content.single.content[2], same(nodes[2]));
  });

  test('跨类型 atom 替换严格拒绝且不污染树', () {
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode('image', attrs: {'src': '/a'}),
          ],
        ),
      ],
    );
    final projection = SemanticEditorProjection.project(source);
    final block = projection.blocks.single as TextBlock;
    expect(
      () => projection.synchronize([
        block.copyWith(
          content: EditableTextContent(
            text: kAtomChar,
            atoms: {0: const MentionRun(username: 'x', href: '/u/x')},
          ),
        ),
      ]),
      throwsA(isA<SemanticEditorUnsupported>()),
    );
  });
}
