import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/document_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = SemanticDocumentCodec();
  SemanticNode paragraph(String text, {List<SemanticMark> marks = const []}) =>
      SemanticNode(
        'paragraph',
        content: [SemanticNode('text', text: text, marks: marks)],
      );
  void select(SemanticEditorSession s, int from, int to, {int? last}) {
    s.editor.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: s.editor.blocks.first.id, offset: from),
        extent: EditorPosition(
          blockId: s.editor.blocks[last ?? 0].id,
          offset: to,
        ),
      ),
    );
  }

  test('全文及 mock 剪贴板保留链接 title、HTML 属性，不走扁平 serializer', () async {
    final source = SemanticNode(
      'doc',
      content: [
        paragraph(
          '重复重复',
          marks: [
            SemanticMark('link', {
              'href': '/a',
              'title': '标题',
              'data-orig-href': '/源',
            }),
          ],
        ),
        SemanticNode(
          'html_block',
          content: [
            SemanticNode('text', text: '<section data-x="值">原文</section>'),
          ],
        ),
      ],
    );
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    expect(s.editor.exportMarkdown(), codec.serialize(source));
    select(s, 2, 4);
    final expected = codec.serialize(
      SemanticNode(
        'doc',
        content: [
          source.content.first.copy(
            content: [source.content.first.content.first.copy(text: '重复')],
          ),
        ],
      ),
    );
    expect(expected, contains('标题'));
    expect(s.editor.copySelectionAsMarkdown(), expected);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? clipboard;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    select(s, 0, 1, last: 1);
    await Clipboard.setData(
      ClipboardData(text: s.editor.copySelectionAsMarkdown()),
    );
    expect(
      (await Clipboard.getData(Clipboard.kTextPlain))!.text,
      codec.serialize(source),
    );
    expect(clipboard, contains('data-x="值"'));
  });

  test('重复文字无坐标片段拒绝；原始反向选区准确', () {
    final s = SemanticEditorSession(
      SemanticNode('doc', content: [paragraph('甲乙甲乙')]),
    );
    addTearDown(s.dispose);
    select(s, 4, 2);
    expect(s.editor.copySelectionAsMarkdown(), '甲乙');
    expect(
      () => s.editor.exportMarkdown(fragment: s.editor.copySelectionAsBlocks()),
      throwsA(isA<EditorDocumentRejection>()),
    );
    expect(s.editor.exportMarkdown(fragment: []), '');
    final unknown = TextBlock(
      id: 'unknown',
      content: EditableTextContent(text: '坏'),
    );
    expect(
      () => s.editor.exportMarkdown(fragment: [unknown]),
      throwsA(isA<EditorDocumentRejection>()),
    );
  });

  test('唯一文本切片保留祖先详情属性和 summary，不泄露兄弟正文', () {
    final detail = SemanticNode(
      'details',
      attrs: {'open': true},
      content: [
        SemanticNode('summary', content: [SemanticNode('text', text: '摘要')]),
        paragraph('前正文后'),
        paragraph('不能复制'),
      ],
    );
    final s = SemanticEditorSession(SemanticNode('doc', content: [detail]));
    addTearDown(s.dispose);
    select(s, 1, 3);
    final expected = codec.serialize(
      SemanticNode(
        'doc',
        content: [
          detail.copy(content: [detail.content.first, paragraph('正文')]),
        ],
      ),
    );
    expect(s.editor.copySelectionAsMarkdown(), expected);
    expect(
      s.editor.exportMarkdown(fragment: s.editor.copySelectionAsBlocks()),
      expected,
    );
    expect(expected, isNot(contains('不能复制')));
  });

  test('全文、片段与选区都过滤活动 transient，历史恢复仍读取绑定快照', () {
    final s = SemanticEditorSession(
      SemanticNode('doc', content: [paragraph('左'), paragraph('右')]),
    );
    addTearDown(s.dispose);
    s.insertTransientNodeAtBlock(
      1,
      'upload',
      SemanticNode('mock_upload', attrs: {'raw': '不得泄露'}),
    );
    select(s, 0, 1, last: 2);
    final expected = codec.serialize(s.exportTree());
    expect(s.editor.exportMarkdown(), expected);
    expect(s.editor.copySelectionAsMarkdown(), expected);
    expect(
      s.editor.exportMarkdown(fragment: s.editor.copySelectionAsBlocks()),
      expected,
    );
    s.editor.imeReplace(s.editor.blocks.last.id, 0, 1, '新', caretOffset: 1);
    expect(s.editor.exportMarkdown(), contains('新'));
    s.editor.undo();
    expect(s.editor.exportMarkdown(), expected);
    s.editor.redo();
    expect(s.editor.exportMarkdown(), contains('新'));
  });

  test('IR 物化选区按字面坐标截取，不补回选区外的链接', () {
    final source = SemanticNode(
      'doc',
      content: [
        paragraph(
          '链接',
          marks: [
            SemanticMark('link', {'href': '/x', 'title': '标题'}),
          ],
        ),
      ],
    );
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    s.editor.mode = EditorMode.ir;
    select(s, 1, 1);
    select(s, 1, 2);
    expect(s.editor.exportMarkdown(), codec.serialize(source));
    expect(s.editor.copySelectionAsMarkdown(), '链');
    final raw = (s.editor.blocks.first as TextBlock).content.text;
    final href = raw.indexOf('/x');
    expect(href, greaterThanOrEqualTo(0));
    select(s, href, href + 2);
    expect(s.editor.copySelectionAsMarkdown(), '/x');
    select(s, raw.length, 0);
    expect(s.editor.copySelectionAsMarkdown(), codec.serialize(source));
  });

  test('IR 完整链接保留来源属性，系统剪贴板与反向多块选区一致', () async {
    final link = paragraph(
      '链接',
      marks: [
        SemanticMark('link', {
          'href': '/x',
          'title': '原始标题',
          'data-orig-href': '/原始',
        }),
      ],
    );
    final quote = SemanticNode('blockquote', content: [link, paragraph('尾段')]);
    final source = SemanticNode('doc', content: [quote]);
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    s.editor.mode = EditorMode.ir;
    select(s, 1, 1);
    final raw = (s.editor.blocks.first as TextBlock).content.text;
    expect(raw, contains('[链接]'));
    final before = s.editor.blocks.toList();
    select(s, 0, raw.length);
    final selectedLink = codec.serialize(
      SemanticNode(
        'doc',
        content: [
          quote.copy(content: [link]),
        ],
      ),
    );
    expect(s.editor.copySelectionAsMarkdown(), selectedLink);
    expect(selectedLink, contains('原始标题'));
    select(s, 1, 3);
    expect(
      s.editor.copySelectionAsMarkdown(),
      codec.serialize(
        SemanticNode(
          'doc',
          content: [
            quote.copy(content: [paragraph('链接')]),
          ],
        ),
      ),
    );
    s.editor.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: s.editor.blocks.last.id, offset: 2),
        extent: EditorPosition(blockId: s.editor.blocks.first.id, offset: 0),
      ),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? clipboard;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await Clipboard.setData(
      ClipboardData(text: s.editor.copySelectionAsMarkdown()),
    );
    expect(
      (await Clipboard.getData(Clipboard.kTextPlain))!.text,
      codec.serialize(source),
    );
    expect(s.editor.blocks, before);
    expect(s.editor.canUndo, isFalse);
  });

  test('IR 同 href 的完整链接按原 span 保留各自 title', () {
    final first = SemanticNode(
      'text',
      text: '甲',
      marks: [
        SemanticMark('link', {'href': '/same', 'title': '第一'}),
      ],
    );
    final second = SemanticNode(
      'text',
      text: '乙',
      marks: [
        SemanticMark('link', {'href': '/same', 'title': '第二'}),
      ],
    );
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            first,
            SemanticNode('text', text: ' '),
            second,
          ],
        ),
      ],
    );
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    s.editor.mode = EditorMode.ir;
    select(s, 0, 0);
    final raw = (s.editor.blocks.first as TextBlock).content.text;
    expect(raw, startsWith('[甲]'));
    final end = raw.indexOf(')') + 1;
    select(s, 0, end);
    expect(
      s.editor.copySelectionAsMarkdown(),
      codec.serialize(
        SemanticNode(
          'doc',
          content: [
            SemanticNode('paragraph', content: [first]),
          ],
        ),
      ),
    );
    select(s, raw.length, 0);
    expect(s.editor.copySelectionAsMarkdown(), codec.serialize(source));
  });

  test('岛端点 0 排除 HTML；端点 1 包含 HTML', () {
    final source = SemanticNode(
      'doc',
      content: [
        paragraph('甲'),
        SemanticNode(
          'html_block',
          content: [SemanticNode('text', text: '<div data-x="1">乙</div>')],
        ),
      ],
    );
    final s = SemanticEditorSession(source);
    addTearDown(s.dispose);
    select(s, 0, 0, last: 1);
    expect(s.editor.copySelectionAsMarkdown(), '甲');
    select(s, 0, 1, last: 1);
    expect(s.editor.copySelectionAsMarkdown(), codec.serialize(source));
  });
}
