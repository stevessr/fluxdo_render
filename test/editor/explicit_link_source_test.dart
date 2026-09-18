import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ParagraphParser;
import 'package:fluxdo_render/src/editor/model/inline_markdown_parser.dart';
import 'package:fluxdo_render/src/editor/model/inline_spin.dart';

void main() {
  const url = 'https://github.com';
  const raw = '[$url]($url)';

  test('同名显式链接导入、编辑、复制均保留包装和目标', () {
    var n = 0;
    final doc = blockNodesToDoc(
      ParagraphParser().parse('<p><a href="$url">$url</a></p>'),
      () => 'e_${n++}',
    );
    final content = (doc.single as TextBlock).content;
    expect(content.marks.single.isAutoLink, isFalse);
    expect(docToMarkdown(doc), raw);
    for (final edited in [
      content.insert(8, 'X'),
      content.replace(8, 9, 'XX'),
    ]) {
      expect(edited.marks.single.attr, url);
      expect(edited.marks.single.isAutoLink, isFalse);
    }
    final restored = EditableTextContent.fromInlines(content.toInlines());
    expect(restored.marks.single.isAutoLink, isFalse);
    expect(docToMarkdown([TextBlock(id: 'copy', content: restored)]), raw);
  });

  test('源码粘贴及 IR 折叠显式链接不能重新变回启发式', () {
    final parsed = parseInlineMarkdown(raw);
    final folded = spinInlineMarks(
      EditableTextContent(text: raw),
      caret: raw.length,
      guardAtCaret: false,
    ).content;
    for (final content in [parsed, folded]) {
      expect(content.text, url);
      expect(content.marks.single.isAutoLink, isFalse);
      expect(docToMarkdown([TextBlock(id: 'e', content: content)]), raw);
    }
  });

  test('链接来源经过样式分片往返不会重复整条网址', () {
    for (final source in <bool?>[null, false, true]) {
      final content = EditableTextContent(
        text: url,
        marks: [
          MarkSpan(
            start: 0,
            end: url.length,
            kind: MarkKind.link,
            attr: url,
            isAutoLink: source,
          ),
          const MarkSpan(start: 8, end: 14, kind: MarkKind.strong),
        ],
      );
      final restored = EditableTextContent.fromInlines(content.toInlines());
      expect(restored.text, url);
      final link = restored.marks.singleWhere((m) => m.kind == MarkKind.link);
      expect(link.isAutoLink, source);
      expect(link.start, 0);
      expect(link.end, url.length);
    }
  });

  test('链接工具与输入规则创建的同名链接仍为显式', () {
    final state = EditorState.fromTexts([url]);
    addTearDown(state.dispose);
    final id = state.blocks.single.id;
    state.updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: id, offset: 0),
        extent: EditorPosition(blockId: id, offset: url.length),
      ),
    );
    state.applyLink(url);
    expect(docToMarkdown(state.blocks), raw);
    final typed = EditorState.fromTexts([raw]);
    addTearDown(typed.dispose);
    typed.applyLinkInputRule(
      typed.blocks.single.id,
      start: 0,
      end: raw.length,
      label: url,
      href: url,
    );
    expect(docToMarkdown(typed.blocks), raw);
  });
}
