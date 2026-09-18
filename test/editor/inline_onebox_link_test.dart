/// 行内 onebox 链接(裸 URL linkify)可编辑化:
/// 导入 = link mark 文本用 href;序列化 = text==attr 走裸 URL 规则
/// (不包 [text](url)、URL 内不转义);编辑后(text!=attr)回标准语法。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/model/inline_spin.dart'
    show isRefoldableMark;
import 'package:fluxdo_render/fluxdo_render.dart'
    show EditingDelimiterRun, LinkRun, ParagraphNode, ParagraphParser, TextRun;

void main() {
  test('加载中的自动链接按裸 href 导入，不把 URL 编码差异当自定义标题', () {
    final nodes = ParagraphParser().parse(
      '<p>[<a href="https://github.com/%5C" '
      'class="inline-onebox-loading">https://github.com/\\</a>]('
      '<a href="https://github.com">https://github.com</a>)</p>',
    );
    final paragraph = nodes.single as ParagraphNode;
    final link = paragraph.inlines.whereType<LinkRun>().first;
    expect(link.isOneboxLink, isTrue);
    var n = 0;
    final doc = blockNodesToDoc(nodes, () => 'e_${n++}');
    final content = (doc.single as TextBlock).content;
    expect(content.text, r'[https://github.com/\](https://github.com)');
    expect(docToMarkdown(doc),
        r'\[https://github.com/\]([https://github.com](https://github.com))');
    for (var caret = 0; caret <= content.marks.first.end; caret++) {
      expect(content.toInlines(forEditing: true, revealMarkdownAt: caret)
          .whereType<EditingDelimiterRun>(), isEmpty,
          reason: '裸链接任意光标位置均不能展开额外的链接包装');
    }
    expect(isRefoldableMark(content, content.marks.first), isFalse,
        reason: '有自动来源证据的链接不物化');
    expect(isRefoldableMark(content, content.marks.last), isTrue,
        reason: '第二条链接按显式保留，不能禁用 IR 展开');
    final state = EditorState(blocks: doc)..mode = EditorMode.ir;
    addTearDown(state.dispose);
    for (var caret = 0; caret <= content.marks.first.end; caret++) {
      state.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: doc.single.id, offset: caret),
      ));
      expect((state.blocks.single as TextBlock).content.text, content.text,
          reason: '真实 IR 选区切换不能物化出重复链接语法');
    }
    final restored = EditableTextContent.fromInlines(content.toInlines());
    expect(restored.text, content.text);
    expect(restored.marks.first.isAutoLink, isTrue);
    expect(restored.isBareLink(restored.marks.first), isTrue);
    final mark = content.marks.first;
    final edited = content.insert(mark.end - 1, 'path');
    expect(edited.marks.first.attr, 'https://github.com/path%5C');
  });

  test('链接外编辑不改 href，链接内编辑保留协议和编码', () {
    for (final (label, href, updated) in [
      ('example.com', 'http://example.com', 'http://exXample.com'),
      ('a@example.com', 'mailto:a@example.com', 'mailto:a@Xexample.com'),
      (r'https://github.com/\', 'https://github.com/%5C',
          'htXtps://github.com/%5C'),
    ]) {
      final content = EditableTextContent(
        text: '前 $label 后',
        marks: [MarkSpan(start: 2, end: 2 + label.length,
            kind: MarkKind.link, attr: href, isAutoLink: true)],
      );
      expect(content.insert(0, '新增').marks.single.attr, href);
      expect(content.delete(0, 1).marks.single.attr, href);
      expect(content.insert(4, 'X').marks.single.attr, updated);
      final replaced = content.replace(4, 5, 'XX');
      expect(replaced.marks, hasLength(1));
      expect(replaced.marks.single.attr,
          updated.replaceFirst('X${label[2]}', 'XX'));
    }
  });

  test('裸链旁边的粗体仍可物化，且不改链接目标', () {
    const url = r'https://github.com/\';
    final state = EditorState(blocks: [TextBlock(
      id: 'e_0',
      content: EditableTextContent(
        text: '$url bold',
        marks: [
          const MarkSpan(start: 0, end: url.length, kind: MarkKind.link,
              attr: 'https://github.com/%5C', isAutoLink: true),
          const MarkSpan(start: url.length + 1, end: url.length + 5,
              kind: MarkKind.strong),
        ],
      ),
    )])..mode = EditorMode.ir;
    addTearDown(state.dispose);
    state.updateSelection(const EditorSelection.collapsed(
      EditorPosition(blockId: 'e_0', offset: url.length + 3),
    ));
    final content = (state.blocks.single as TextBlock).content;
    expect(content.text, '$url **bold**');
    expect(content.marks.single.attr, 'https://github.com/%5C');
  });

  test('解码后的显式链接标题不能误判为自动链接', () {
    for (final label in ['https://example.com/中文', r'https://example.com/\']) {
      final href = label.endsWith('中文')
          ? 'https://example.com/%E4%B8%AD%E6%96%87'
          : 'https://example.com/%5C';
      final content = EditableTextContent.fromInlines([
        LinkRun(href: href, children: [TextRun(label)]),
      ]);
      expect(content.isBareLink(content.marks.single), isFalse);
      expect(content.toInlines(forEditing: true, revealMarkdownAt: 3)
          .whereType<EditingDelimiterRun>(), hasLength(2));
      expect(docToMarkdown([TextBlock(id: 'e_0', content: content)]),
          startsWith('['));
    }
  });

  test('自定义链接标题仍显形并允许物化', () {
    final content = EditableTextContent(
      text: 'GitHub',
      marks: const [MarkSpan(start: 0, end: 6, kind: MarkKind.link,
          attr: 'https://github.com')],
    );
    expect(content.toInlines(forEditing: true, revealMarkdownAt: 3)
        .whereType<EditingDelimiterRun>(), hasLength(2));
    expect(isRefoldableMark(content, content.marks.single), isTrue);
  });

  test('裸链接之后的闭括号不转义，避免反斜杠被吸入地址', () {
    const url = 'https://example.com/path';
    final block = TextBlock(
      id: 'e_0',
      content: EditableTextContent(
        text: '[$url]',
        marks: [
          MarkSpan(start: 1, end: 1 + url.length,
              kind: MarkKind.link, attr: url),
        ],
      ),
    );
    expect(docToMarkdown([block]), r'\[https://example.com/path]');
  });

  test('inline-onebox 链接导入为可编辑 mark(文本=href)', () {
    const url = 'https://linux.do/t/topic/2587100';
    final doc = blockNodesToDoc(
      [
        ParagraphNode(id: 'b_0', inlines: const [
          TextRun('看这个 '),
          LinkRun(
            href: url,
            children: [TextRun('动态取回的页面标题')],
            isOneboxLink: true,
          ),
          TextRun(' 不错'),
        ]),
      ],
      () => 'e_0',
    );
    expect(doc, hasLength(1));
    final tb = doc.first as TextBlock;
    expect(tb.content.text, '看这个 $url 不错', reason: '显示 URL 非标题');
    final range = tb.content.linkRangeAt(5);
    expect(range, isNotNull);
    expect(range!.$3, url);
  });

  test('裸 URL 序列化:不包装不转义;编辑过的回 [text](url)', () {
    const url = 'https://x.test/a_b_c';
    final bare = TextBlock(
      id: 'e_0',
      content: EditableTextContent(
        text: '前 $url 后',
        marks: [
          MarkSpan(start: 2, end: 2 + url.length, kind: MarkKind.link, attr: url),
        ],
      ),
    );
    expect(docToMarkdown([bare]), '前 $url 后',
        reason: '裸 URL 原样(下划线不转义,无 [] 包装)');

    final edited = TextBlock(
      id: 'e_1',
      content: EditableTextContent(
        text: '前 说明文字 后',
        marks: const [
          MarkSpan(start: 2, end: 6, kind: MarkKind.link, attr: url),
        ],
      ),
    );
    expect(docToMarkdown([edited]), '前 [说明文字]($url) 后',
        reason: 'text!=href 走标准链接语法');
  });

  test('往返:含行内 onebox 链接的段落 doc→md→(结构自证)', () {
    const url = 'https://linux.do/t/topic/123';
    final doc = blockNodesToDoc(
      [
        ParagraphNode(id: 'b_0', inlines: const [
          TextRun('a '),
          LinkRun(href: url, children: [TextRun('标题')], isOneboxLink: true),
          TextRun(' b'),
        ]),
      ],
      () => 'e_0',
    );
    expect(docToMarkdown(doc), 'a $url b', reason: 'raw 保持裸 URL');
  });
}
