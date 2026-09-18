part of 'semantic_editor.dart';

/// 正式语义属性映射；未映射的字段继续保存在不可变来源节点中。
/// 图片尺寸对应 ImageRun；title 无独立接口，留在原树属性中保真。
/// 日期用 date/time/timezone/endDate/endTime。
// 只校验已知字段；扩展属性留在来源树，不做有损白名单过滤。
bool _validSemanticAttrs(
  Map<String, dynamic> attrs, {
  Set<String> strings = const {},
  Set<String> numbers = const {},
  Set<String> booleans = const {},
  Set<String> stringLists = const {},
}) {
  for (final entry in attrs.entries) {
    final value = entry.value;
    if (value == null) continue;
    if (strings.contains(entry.key) && value is! String) return false;
    if (numbers.contains(entry.key) && (value is! num || !value.isFinite)) {
      return false;
    }
    if (booleans.contains(entry.key) && value is! bool) return false;
    if (stringLists.contains(entry.key) &&
        (value is! List || value.any((v) => v is! String))) {
      return false;
    }
  }
  return true;
}

bool _validSemanticLinkAttrs(Map<String, dynamic> attrs) => _validSemanticAttrs(
  attrs,
  strings: {'href', 'filename', 'data-orig-href', 'title', 'markup'},
  booleans: {'attachment', 'isAtom', 'editorLinkSourcePresent', 'editorIsAutoLink'},
);

/// 正式 codec 将软硬换行统一为 hard_break；换行占一个文本坐标而非 atom。
bool _semanticInlineBreak(SemanticNode node) =>
    node.type == 'hard_break' &&
    node.text == null &&
    node.content.isEmpty &&
    _validSemanticAttrs(node.attrs, booleans: {'soft'});

int _semanticInlineLength(SemanticNode node) =>
    node.type == 'check'
    ? 3
    : node.type == 'html_inline'
    ? node.content.fold(0, (sum, child) => sum + _semanticInlineLength(child))
    : _semanticInlineBreak(node) || _semanticInlineAtom(node) != null
    ? 1
    : node.text!.length;

/// 同类重复 mark 无法投影到格式开关；特殊链接的 link 由 atom 自身承载。
bool _validSemanticInlineMarks(SemanticNode node) {
  final types = <String>{};
  for (final mark in node.marks) {
    if (!_kinds.containsKey(mark.type) || !types.add(mark.type)) return false;
    if (mark.type == 'link' &&
        (!_validSemanticLinkAttrs(mark.attrs) ||
            mark.attrs['href'] is! String ||
            (node.type != 'text' &&
                (mark.attrs['attachment'] == true ||
                    mark.attrs['markup'] != null ||
                    mark.attrs['filename'] != null)))) {
      return false;
    }
  }
  return true;
}

InlineNode? _semanticInlineAtom(SemanticNode node) {
  final a = node.attrs;
  if (!_validSemanticInlineMarks(node)) return null;
  switch (node.type) {
    case 'math_inline':
      if (a['content'] is! String ||
          !{null, 'tex', 'asciimath'}.contains(a['mathType'])) {
        return null;
      }
      return MathInlineRun(a['content']);
    case 'footnote_ref':
      if (a['id'] is! int || a['id'] < 0 ||
          !_validSemanticAttrs(a, strings: {'label', 'contentHtml'})) {
        return null;
      }
      return FootnoteRefRun(number: '${(a['id'] as int) + 1}',
        fnId: 'fn:${(a['id'] as int) + 1}',
        markdownLabel: a['label'] as String?, contentHtml: a['contentHtml'] as String?);
    case 'image':
      if (!_validMediaFields({
            'src': a['src'],
            'origSrc': a['data-orig-src'],
            'poster': a['lightboxUrl'],
            'width': a['width'],
            'height': a['height'],
          }) ||
          a['src'] is! String ||
          !_validSemanticAttrs(
            a,
            strings: {
              'src',
              'alt',
              'data-orig-src',
              'title',
              'filename',
              'lightboxUrl',
              'fileSizeText',
            },
            numbers: {
              'width',
              'height',
              'origWidth',
              'origHeight',
              'naturalWidth',
              'naturalHeight',
              'scale',
            },
          )) {
        return null;
      }
      return ImageRun(
        src: a['src'],
        alt: a['alt'] as String? ?? '',
        width: (a['width'] as num?)?.toDouble(),
        height: (a['height'] as num?)?.toDouble(),
        origWidth: (a['origWidth'] as num?)?.toDouble(),
        origHeight: (a['origHeight'] as num?)?.toDouble(),
        naturalWidth: (a['naturalWidth'] as num?)?.toDouble(),
        naturalHeight: (a['naturalHeight'] as num?)?.toDouble(),
        filename: a['filename'] as String?,
        lightboxUrl: a['lightboxUrl'] as String?,
        fileSizeText: a['fileSizeText'] as String?,
        origSrc: a['data-orig-src'] as String?,
        scale: (a['scale'] as num?)?.toDouble(),
      );
    case 'emoji':
      if (!_validMediaFields({'src': a['url']}) ||
          a['name'] is! String ||
          a['url'] is! String ||
          !_validSemanticAttrs(a, booleans: {'isOnlyEmoji'})) {
        return null;
      }
      return EmojiRun(
        name: a['name'],
        url: a['url'],
        isOnlyEmoji: a['isOnlyEmoji'] == true,
      );
    case 'hashtag':
      if (a['ref'] is! String ||
          !_validSemanticAttrs(a, strings: {'ref', 'href'})) {
        return null;
      }
      return LinkRun(href: a['href'] as String? ?? '',
        hashtagRef: a['ref'], children: [TextRun('#${a['ref']}')]);
    case 'mention':
      if (a['username'] is! String || a['href'] is! String) return null;
      return MentionRun(username: a['username'], href: a['href']);
    case 'local_date':
      if (a['date'] is! String ||
          !_validSemanticAttrs(
            a,
            strings: {
              'fallbackText',
              'time',
              'timezone',
              'format',
              'displayedTimezone',
              'countdownRaw',
              'recurring',
              'endDate',
              'endTime',
              'range',
            },
            booleans: {'countdown'},
            stringLists: {'timezones'},
          )) {
        return null;
      }
      return LocalDateRun(
        date: a['date'],
        fallbackText: a['fallbackText'] as String? ?? node.textContent,
        time: a['time'] as String?,
        timezone: a['timezone'] as String?,
        timezones: (a['timezones'] as List?)?.cast<String>() ?? const [],
        format: a['format'] as String?,
        displayedTimezone: a['displayedTimezone'] as String?,
        countdown: a['countdown'] == true,
        countdownRaw: a['countdownRaw'] as String?,
        recurring: a['recurring'] as String?,
        endDate: a['endDate'] as String?,
        endTime: a['endTime'] as String?,
        range: a['range'] as String?,
      );
    case 'text':
      final link = node.marks.where((m) => m.type == 'link').firstOrNull;
      if (link == null || node.text == null || node.content.isNotEmpty) {
        return null;
      }
      final l = link.attrs;
      if (!_validSemanticLinkAttrs(l) ||
          l['href'] is! String ||
          !(l['isAtom'] == true || l['attachment'] == true ||
              l['markup'] != null ||
              l['filename'] != null)) {
        return null;
      }
      if (!{null, 'autolink', 'linkify', '<>', 'bare'}.contains(l['markup'])) {
        return null;
      }
      return LinkRun(
        href: l['href'],
        children: [TextRun(node.text!)],
        isAttachment: l['attachment'] == true,
        filename: l['filename'] as String? ?? node.text!,
        origHref: l['data-orig-href'] as String?,
        editorLinkTitle: l['title'] as String?,
        editorAngleLink: {'autolink', '<>'}.contains(l['markup']),
        editorLinkSource: l.containsKey('editorLinkSourcePresent')
            ? (l['editorLinkSourcePresent'] == true
                ? (isAutoLink: l['editorIsAutoLink'] as bool?)
                : null)
            : (isAutoLink: {'linkify', 'bare'}.contains(l['markup'])),
      );
  }
  return null;
}

Map<String, dynamic> _semanticAtomAttrs(InlineNode atom) => switch (atom) {
  MathInlineRun a => {'content': a.latex},
  FootnoteRefRun a => {'id': int.tryParse(a.number) == null ? null : int.parse(a.number) - 1,
    'label': a.markdownLabel, 'contentHtml': a.contentHtml},
  ImageRun a => {
    'src': a.src,
    'alt': a.alt,
    'width': a.width,
    'height': a.height,
    'data-orig-src': a.origSrc,
    'scale': a.scale,
    'origWidth': a.origWidth,
    'origHeight': a.origHeight,
    'naturalWidth': a.naturalWidth,
    'naturalHeight': a.naturalHeight,
    'filename': a.filename,
    'lightboxUrl': a.lightboxUrl,
    'fileSizeText': a.fileSizeText,
  },
  EmojiRun a => {'name': a.name, 'url': a.url, 'isOnlyEmoji': a.isOnlyEmoji},
  MentionRun a => {'username': a.username, 'href': a.href},
  LocalDateRun a => {
    'date': a.date,
    'fallbackText': a.fallbackText,
    'time': a.time,
    'timezone': a.timezone,
    'timezones': a.timezones,
    'format': a.format,
    'displayedTimezone': a.displayedTimezone,
    'countdown': a.countdown,
    'countdownRaw': a.countdownRaw,
    'recurring': a.recurring,
    'endDate': a.endDate,
    'endTime': a.endTime,
    'range': a.range,
  },
  LinkRun a => {
    'ref': a.hashtagRef,
    'href': a.href,
    'attachment': a.isAttachment,
    'filename': a.filename,
    'data-orig-href': a.origHref,
    'title': a.editorLinkTitle,
    'markup': a.editorAngleLink ? 'autolink'
        : a.editorLinkSource?.isAutoLink == true ? 'linkify' : null,
    'editorLinkSourcePresent': a.editorLinkSource != null,
    'editorIsAutoLink': a.editorLinkSource?.isAutoLink,
  },
  _ => throw const SemanticEditorUnsupported('未知 atom 类型'),
};

SemanticNode _rewriteSemanticAtom(SemanticNode source, InlineNode next) {
  final old = _semanticInlineAtom(source)!;
  if (old == next) return source;
  if (old.runtimeType != next.runtimeType) {
    throw const SemanticEditorUnsupported('不能跨类型替换 atom');
  }
  final before = _semanticAtomAttrs(old), after = _semanticAtomAttrs(next);
  final attrs = {
    ...(old is LinkRun && source.type != 'hashtag'
        ? source.marks.firstWhere((m) => m.type == 'link').attrs
        : source.attrs),
  };
  for (final key in after.keys) {
    if (before[key] != after[key] &&
        !(before[key] is List &&
            after[key] is List &&
            listEquals(before[key] as List, after[key] as List))) {
      attrs[key] = after[key];
    }
  }
  SemanticNode result;
  if (source.type == 'hashtag' && next is LinkRun) {
    // 仅更新映射字段，来源 token 扩展属性保持不变。
    result = source.copy(attrs: attrs);
  } else if (next is LinkRun && old is LinkRun) {
    if (next.children.any((c) => c is! TextRun)) {
      throw const SemanticEditorUnsupported('链接子树编辑有歧义');
    }
    // markup 与来源三态由属性差量共同维护，避免切换尖括号时丢失裸链来源。
    result = SemanticNode(
      source.type,
      attrs: source.attrs,
      content: source.content,
      text: next.children.cast<TextRun>().map((c) => c.text).join(),
      marks: [
        for (final mark in source.marks)
          mark.type == 'link' ? SemanticMark('link', attrs) : mark,
      ],
    );
  } else {
    result = source.copy(attrs: attrs);
  }
  if (_semanticInlineAtom(result) != next) {
    throw const SemanticEditorUnsupported('atom 包含未映射编辑属性');
  }
  return result;
}

void _validateSemanticAtomEdit(
  EditableTextContent old,
  EditableTextContent next,
) {
  for (var i = 0; i < next.length; i++) {
    if ((next.text[i] == kAtomChar) != next.atoms.containsKey(i)) {
      throw const SemanticEditorUnsupported('atom 哨兵与来源不一致');
    }
    if (next.atoms.containsKey(i)) {
      final spans = next.marks.where((m) => m.start <= i && i < m.end);
      final kinds = <MarkKind>{};
      for (final span in spans) {
        if (!_kinds.containsValue(span.kind) ||
            !kinds.add(span.kind) ||
            (span.kind == MarkKind.link &&
                (span.attr == null ||
                    span.isAutoLink == true ||
                    next.atoms[i] is LinkRun))) {
          throw const SemanticEditorUnsupported('atom 外层 mark 无法无损表达');
        }
      }
    }
  }
  if (next.atoms.keys.any((i) => i < 0 || i >= next.length)) {
    throw const SemanticEditorUnsupported('atom 坐标越界');
  }
}

// HTML 样式只参与显示；嵌套关系和未知属性始终由来源树承担。
const _semanticHtmlStyles = <String, MarkKind>{
  'small': MarkKind.smallStyle,
  'big': MarkKind.bigStyle,
  'mark': MarkKind.markStyle,
  'sup': MarkKind.superscript,
  'sub': MarkKind.subscript,
  'kbd': MarkKind.monospaceStyle,
  'u': MarkKind.underline,
  's': MarkKind.lineThrough,
  'strike': MarkKind.lineThrough,
};

EditableTextContent? _projectSemanticHtml(SemanticNode node) {
  if (node.attrs['tag'] is! String || !_validSemanticInlineMarks(node)) {
    return null;
  }
  final content = SemanticEditorProjection._inline(node);
  if (content == null) return null;
  final style = _semanticHtmlStyles[node.attrs['tag']];
  final inherited = <MarkSpan>[
    if (style != null && content.length > 0)
      MarkSpan(start: 0, end: content.length, kind: style),
    for (final mark in node.marks)
      MarkSpan(start: 0, end: content.length, kind: _kinds[mark.type]!,
        attr: mark.type == 'link' ? mark.attrs['href'] as String : null,
        isAutoLink: mark.type == 'link' ? false : null),
  ];
  return EditableTextContent(text: content.text,
    marks: [...inherited, ...content.marks], atoms: content.atoms,
    softBreaks: content.softBreaks);
}

/// 逐层按原始路径分配编辑，不以扁平 mark 重建 HTML 树。
/// 跨 HTML 边界的替换没有唯一父节点，必须在提交前拒绝。
List<SemanticNode> _rewriteSemanticNested(SemanticNode parent,
    EditableTextContent old, EditableTextContent next, {bool allowNewAtoms = false}) {
  var prefix = 0;
  while (prefix < old.length && prefix < next.length &&
      old.text[prefix] == next.text[prefix]) { prefix++; }
  var suffix = 0;
  while (suffix < old.length - prefix && suffix < next.length - prefix &&
      old.text[old.length - suffix - 1] == next.text[next.length - suffix - 1]) {
    suffix++;
  }
  final delta = next.length - old.length;
  final result = <SemanticNode>[];
  var offset = 0;
  var assigned = false;
  for (final child in parent.content) {
    final projected = SemanticEditorProjection._inline(
      SemanticNode('paragraph', content: [child]))!;
    final end = offset + projected.length;
    final owns = !assigned && delta != 0 && prefix >= offset && prefix <= end &&
        old.length - suffix <= end;
    if (delta != 0 && prefix < end && old.length - suffix > end) {
      throw const SemanticEditorUnsupported('跨 HTML 子树的替换来源不明确');
    }
    final startNext = offset + (assigned ? delta : 0);
    final endNext = end + ((assigned || owns) ? delta : 0);
    if (startNext < 0 || endNext > next.length || endNext < startNext) {
      throw const SemanticEditorUnsupported('HTML 来源坐标不一致');
    }
    final piece = next.slice(startNext, endNext);
    if (piece == projected) {
      result.add(child);
    } else if (child.type == 'check') {
      if (const ['[ ]', '[x]', '[X]'].contains(piece.text)) {
        result.add(child.copy(attrs: {...child.attrs,
          'checked': piece.text != '[ ]', 'permanent': piece.text == '[X]'}));
      } else {
        // 用户将 checklist 标记改为普通文字时，仍保留来源扩展属性。
        result.add(SemanticNode('text', text: piece.text,
          attrs: child.attrs, marks: child.marks));
      }
    } else if (child.type == 'html_inline') {
      final inner = SemanticEditorProjection._inline(child)!;
      // 去除此层施加的显示样式，子层保留；禁止静默丢弃样式编辑。
      final wrapper = _projectSemanticHtml(child)!;
      final wrapperMarks = wrapper.marks.take(wrapper.marks.length - inner.marks.length);
      final remaining = [...piece.marks];
      for (final mark in wrapperMarks) {
        final index = remaining.indexWhere((m) => m.kind == mark.kind &&
          m.attr == mark.attr && m.start == 0 && m.end == piece.length);
        if (index < 0 && piece.length > 0) {
          throw const SemanticEditorUnsupported('HTML 外层样式必须保留');
        }
        if (index >= 0) {
          remaining.removeWhere((m) => m.kind == mark.kind &&
            m.attr == mark.attr && m.start == 0 && m.end == piece.length);
          // 编辑模型会合并同类重叠 marks；嵌套同标签仍由原树区分。
          if (inner.marks.any((m) => m.kind == mark.kind &&
              m.attr == mark.attr && m.start == 0 && m.end == inner.length)) {
            remaining.add(MarkSpan(start: 0, end: piece.length,
              kind: mark.kind, attr: mark.attr, isAutoLink: mark.isAutoLink));
          }
        }
      }
      final updated = EditableTextContent(text: piece.text, marks: remaining,
        atoms: piece.atoms, softBreaks: piece.softBreaks);
      result.add(child.copy(content: SemanticEditorProjection._rewrite(child, inner, updated, allowNewAtoms: allowNewAtoms)));
    } else {
      result.addAll(SemanticEditorProjection._rewrite(
        SemanticNode('paragraph', content: [child]), projected, piece, allowNewAtoms: allowNewAtoms));
    }
    assigned = assigned || owns;
    offset = end;
  }
  if (delta != 0 && !assigned) {
    throw const SemanticEditorUnsupported('HTML 插入没有唯一来源');
  }
  return result;
}

/// 仅显式 insertAtom 命令可以创建没有旧来源的原子。
SemanticNode _newSemanticAtom(InlineNode atom) {
  if (atom is LinkRun && atom.hashtagRef != null) {
    final node = SemanticNode('hashtag', attrs: _semanticAtomAttrs(atom));
    if (_semanticInlineAtom(node) != atom) {
      throw const SemanticEditorUnsupported('新增 hashtag 属性无法完整表达');
    }
    return node;
  }
  if (atom is LinkRun) {
    // 原子链接仅接受单个纯文本子节点；不能悄悄展平样式或未知 inline。
    if (atom.children.length != 1 || atom.children.single is! TextRun) {
      throw const SemanticEditorUnsupported('新增链接子树无法无损表达');
    }
    final node = SemanticNode('text',
      text: (atom.children.single as TextRun).text,
      marks: [SemanticMark('link', {
        ..._semanticAtomAttrs(atom),
        'isAtom': true,
      })]);
    if (_semanticInlineAtom(node) != atom) {
      throw const SemanticEditorUnsupported('新增链接属性无法完整表达');
    }
    return node;
  }
  final type = switch (atom) {
    ImageRun() => 'image', EmojiRun() => 'emoji', MentionRun() => 'mention',
    LocalDateRun() => 'local_date', MathInlineRun() => 'math_inline',
    FootnoteRefRun() => 'footnote_ref',
    _ => throw const SemanticEditorUnsupported('新增 atom 类型尚未声明'),
  };
  final node = SemanticNode(type, attrs: _semanticAtomAttrs(atom));
  if (_semanticInlineAtom(node) != atom) {
    throw const SemanticEditorUnsupported('新增 atom 属性无法完整表达');
  }
  return node;
}
