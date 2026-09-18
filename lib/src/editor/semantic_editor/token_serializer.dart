import 'document.dart';
import '../../node/node.dart' show PollNode;
import '../model/poll_codec.dart' show serializePollNode;
import 'document_codec.dart';

/// 提取自 PM MarkdownSerializerState 的延迟闭块及 mark 核心。
/// 与探针隔离：无脚注、无 JS 怪值转换，只接受生产 schema。
/// 不修剪输出：扩展显式写入的尾换行属于序列化协议。
String serializeSemantic(SemanticNode doc) {
  final state = _SemanticSerializerState();
  state.renderContent(doc);
  return state.out;
}

// 所有已知字段先经 SemanticSchema 验证，不模拟 JS coercion。
bool _present(Object? value) =>
    value != null && value != '' && value != false && value != 0;
String _scalar(Object? value) {
  if (value is String || value is num || value is bool) return '$value';
  throw const SemanticCodecUnsupported('序列化属性不是标量');
}

String _repeat(String value, Object? count) => value * (count as int);
Iterable<MapEntry<String, Object?>> _htmlEntries(Object? attrs) =>
    attrs == null ? const [] : (attrs as Map<String, dynamic>).entries;

String _htmlValue(Object? value) {
  // 官方调用 v.replace，不对非字符串宽容地 String(v)。
  if (value is! String) {
    throw SemanticCodecUnsupported('HTML 属性值必须为字符串');
  }
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

bool _eq(SemanticMark a, SemanticMark b) => sameSemanticMarks([a], [b]);
bool _contains(List<SemanticMark> set, SemanticMark mark) =>
    set.any((m) => _eq(m, mark));

/// 对应 to_markdown.ts 的延迟闭块、行前缀和可交换 mark 状态机。
class _SemanticSerializerState {
  String delim = '', out = '';
  SemanticNode? closed;
  bool? inAutolink;
  Object? linkMarkup;
  bool atBlockStart = false, inTightList = false, inTable = false;

  bool get atBlank => out.isEmpty || out.endsWith('\n');
  void flushClose([int size = 2]) {
    if (closed == null) return;
    if (!atBlank) out += '\n';
    final min = delim.replaceFirst(RegExp(r'\s+$'), '');
    for (var i = 1; i < size; i++) {
      out += '$min\n';
    }
    closed = null;
  }

  void write([String content = '']) {
    flushClose();
    if (delim.isNotEmpty && atBlank) out += delim;
    out += content;
  }

  void closeBlock(SemanticNode node) {
    closed = node;
  }

  void wrapBlock(
    String extra,
    String? first,
    SemanticNode node,
    void Function() f,
  ) {
    final old = delim;
    write(first ?? extra);
    delim += extra;
    f();
    delim = old;
    closeBlock(node);
  }

  String esc(String str, [bool start = false]) {
    final original = str;
    str = str.replaceAllMapped(RegExp(r'[`*\\~\[\]_]'), (m) {
      if (m[0] == '_' &&
          m.start > 0 &&
          m.end < original.length &&
          RegExp(r'\w').hasMatch(original[m.start - 1]) &&
          RegExp(r'\w').hasMatch(original[m.end])) {
        return '_';
      }
      return '\\${m[0]}';
    });
    if (start) {
      str = str
          .replaceFirstMapped(RegExp(r'^(\+ |[\-*>])'), (m) => '\\${m[0]}')
          .replaceFirstMapped(
            RegExp(r'^(\s*)(#{1,6})(\s|$)'),
            (m) => '${m[1]}\\${m[2]}${m[3]}',
          )
          .replaceFirstMapped(RegExp(r'^(\s*\d+)\.\s'), (m) => '${m[1]}\\. ');
    }
    return str;
  }

  void text(String value, [bool escape = true]) {
    final lines = value.split('\n');
    for (var i = 0; i < lines.length; i++) {
      write();
      if (!escape &&
          lines[i].startsWith('[') &&
          RegExp(r'(^|[^\\])!$').hasMatch(out)) {
        out = '${out.substring(0, out.length - 1)}\\!';
      }
      out += escape ? esc(lines[i], atBlockStart) : lines[i];
      if (i != lines.length - 1) out += '\n';
    }
  }

  void renderContent(SemanticNode parent) {
    for (var i = 0; i < parent.content.length; i++) {
      render(parent.content[i], parent, i);
    }
  }

  void render(SemanticNode node, SemanticNode parent, int index) {
    final a = node.attrs;
    switch (node.type) {
      case 'math_inline':
        final delimiter = a['mathType'] == 'asciimath' ? '%' : '\$';
        write('$delimiter${a['content']}$delimiter');
      case 'check':
        write(
          a['permanent'] == true
              ? '[X]'
              : a['checked'] == true
              ? '[x]'
              : '[ ]',
        );
      case 'footnote_ref':
        write('[^${a['label'] ?? (a['id'] as int) + 1}]');
      case 'footnote_block':
        renderContent(node);
      case 'footnote':
        wrapBlock(
          '    ',
          '[^${a['label'] ?? (a['id'] as int) + 1}]: ',
          node,
          () => renderContent(node),
        );
      case 'poll':
        text(
          serializePollNode(
            PollNode(
              id: 'semantic_poll',
              pollName: a['pollName'] as String? ?? 'poll',
              title: a['title'] as String?,
              rawHtml: a['rawHtml'] as String,
            ),
          ),
          false,
        );
        closeBlock(node);
      case 'callout':
        wrapBlock('> ', null, node, () {
          write(
            '[!${a['typeRaw'] ?? 'note'}]${a['foldable'] == null
                ? ''
                : a['foldable'] == true
                ? '+'
                : '-'}${a['title'] == null ? '' : ' ${a['title']}'}\n',
          );
          renderContent(node);
        });
      case 'hashtag':
        write('#${a['ref']}');
      case 'wrap':
        final attributes = a.entries
            .where((e) => e.key.startsWith('data-'))
            .map((e) => ' ${e.key.substring(5)}="${e.value}"')
            .join();
        write('[wrap$attributes]\n');
        renderContent(node);
        write('[/wrap]');
        closeBlock(node);
      case 'spoiler':
        write('[spoiler]\n');
        renderContent(node);
        write('[/spoiler]');
        closeBlock(node);
      case 'image_grid':
        write(
          '[grid${a['data-mode'] == 'carousel' ? ' mode=carousel' : ''}]\n',
        );
        renderContent(node);
        write('[/grid]');
        closeBlock(node);
      case 'math_block':
        write('\$\$\n');
        text(node.textContent, false);
        write('\n\$\$');
        closeBlock(node);
      case 'table':
        final rows = <SemanticNode>[];
        for (final child in node.content) {
          if (child.type == 'table_row') {
            rows.add(child);
          } else {
            rows.addAll(child.content);
          }
        }
        if (rows.isEmpty) write('<table></table>');
        for (var r = 0; r < rows.length; r++) {
          write('|');
          for (final cell in rows[r].content) {
            final state = _SemanticSerializerState();
            state.renderInline(cell);
            write(
              ' ${state.out.replaceAll('|', r'\|').replaceAll('\n', '<br>')} |',
            );
          }
          write('\n');
          if (r == 0) {
            write(
              '|${rows[r].content.map((c) => switch (c.attrs['style']) {
                'text-align:center' || 'text-align:center;' => ' :---: |',
                'text-align:right' || 'text-align:right;' => ' ---: |',
                'text-align:left' || 'text-align:left;' => ' :--- |',
                _ => ' --- |',
              }).join()}\n',
            );
          }
        }
        closeBlock(node);
      case 'doc':
      case 'list_item':
        renderContent(node);
      case 'text':
        // 仅重放 tokenizer 已确认的整段字面文本，编辑后失效。
        // 禁止 HTML 字符，即使外部构造了来源属性也不能借此注入标签。
        if (a['literalSource'] == node.text &&
            !node.text!.contains(RegExp(r'[<>\r\n]'))) {
          text(node.text!, false);
          break;
        }
        // 紧邻裸链接的 ] 不能加反斜杠：linkify 会把反斜杠吞入
        // 前一个 URL。左方括号仍转义，避免意外组成显式链接。
        final followsBareLink =
            index > 0 &&
            parent.content[index - 1].marks.any(
              (mark) =>
                  mark.type == 'link' &&
                  {'linkify', 'bare'}.contains(mark.attrs['markup']),
            );
        if (inAutolink != true &&
            followsBareLink &&
            node.text!.startsWith(']')) {
          text(']', false);
          text(node.text!.substring(1));
        } else {
          text(node.text!, inAutolink != true);
        }
      case 'paragraph':
        renderInline(node);
        closeBlock(node);
      case 'heading':
        write('${_repeat('#', a['level'])} ');
        renderInline(node, false);
        closeBlock(node);
      case 'horizontal_rule':
        write(_present(a['markup']) ? _scalar(a['markup']) : '---');
        closeBlock(node);
      case 'hard_break':
        write(a['soft'] == true ? '\n' : '  \n');
      case 'blockquote':
        wrapBlock('> ', null, node, () => renderContent(node));
      case 'code_block':
        final ticks = RegExp(
          r'`{3,}',
          multiLine: true,
        ).allMatches(node.textContent).map((m) => m[0]!).toList()..sort();
        final fence = ticks.isEmpty ? '```' : '${ticks.last}`';
        write('$fence${_present(a['params']) ? _scalar(a['params']) : ''}\n');
        if (node.textContent.isNotEmpty) {
          text(node.textContent, false);
          write('\n');
        }
        write(fence);
        closeBlock(node);
      case 'bullet_list':
        renderList(
          node,
          '  ',
          (_) => '${_present(a['bullet']) ? _scalar(a['bullet']) : '*'} ',
        );
      case 'ordered_list':
        final start = a['order'] as int? ?? 1;
        final width = (start + node.content.length - 1).toString().length;
        renderList(node, ' ' * (width + 2), (i) {
          final label = (start + i).toString();
          return '${' ' * (width - label.length)}$label. ';
        });
      case 'quote':
        final name = _present(a['displayName'])
            ? a['displayName']
            : a['username'];
        final params = _present(name)
            ? '="${_scalar(name)}${_present(a['postNumber']) ? ', post:${_scalar(a['postNumber'])}' : ''}${_present(a['topicId']) ? ', topic:${_scalar(a['topicId'])}' : ''}${_present(a['displayName']) && _present(a['username']) ? ', username:${_scalar(a['username'])}' : ''}${a['full'] == true ? ', full:true' : ''}"'
            : '';
        write('[quote$params]\n');
        renderContent(node);
        write('[/quote]\n\n');
      case 'details':
        renderContent(node);
        write('[/details]\n\n');
      case 'summary':
        // 官方空引号参数产生字面两个引号，不应替换为弯引号。
        if (node.textContent == '""') {
          write('[details=""]\n');
          break;
        }
        write(node.content.isEmpty ? '[details' : '[details="');
        for (final child in node.content) {
          if (child.text != null && child.text!.isNotEmpty) {
            // JS 的 undefined 参数使用 text 默认 true，false 则禁用转义。
            text(child.text!.replaceAll('"', '“'), inAutolink ?? true);
          }
        }
        write(node.content.isEmpty ? ']\n' : '"]\n');
      case 'image':
        var label = a['alt'] as String? ?? '';
        final width = a['origWidth'] ?? a['width'];
        final height = a['origHeight'] ?? a['height'];
        if (width != null && height != null) {
          label += '|${_dimension(width)}x${_dimension(height)}';
          if (a['scale'] != null) label += ',${_dimension(a['scale'])}%';
        }
        final src = a['data-orig-src'] as String? ?? a['src'] as String;
        final title = a['title'] == null
            ? ''
            : ' "${_destination(a['title'] as String)}"';
        write('![${esc(label)}](${_destination(src)}$title)');
      case 'emoji':
        write(':${a['name']}:');
      case 'mention':
        write('@${a['username']}');
      case 'local_date':
        final params = <String, String>{};
        for (final key in ['timezone', 'format', 'recurring']) {
          if (a[key] != null) params[key] = a[key] as String;
        }
        if (a['timezones'] is List && (a['timezones'] as List).isNotEmpty) {
          params['timezones'] = (a['timezones'] as List).join('|');
        }
        if (a['displayedTimezone'] != null) {
          params['displayedTimezone'] = a['displayedTimezone'] as String;
        }
        if (a['countdownRaw'] != null || a['countdown'] == true) {
          params['countdown'] = a['countdownRaw'] as String? ?? 'true';
        }
        final String prefix;
        if (a['endDate'] == null) {
          prefix = '[date=${_bbValue(a['date'] as String)}';
          if (a['time'] != null) params['time'] = a['time'] as String;
        } else {
          final from =
              '${a['date']}${a['time'] == null ? '' : 'T${a['time']}'}';
          final to =
              '${a['endDate']}${a['endTime'] == null ? '' : 'T${a['endTime']}'}';
          prefix = '[date-range from=${_bbValue(from)} to=${_bbValue(to)}';
        }
        write(
          '$prefix${params.entries.map((e) => ' ${e.key}="${_bbValue(e.value)}"').join()}]',
        );
      case 'html_inline':
        final html = _htmlEntries(
          a['htmlAttrs'],
        ).map((e) => ' ${e.key}="${_htmlValue(e.value)}"').join();
        write('<${_scalar(a['tag'])}$html>');
        renderInline(node);
        write('</${_scalar(a['tag'])}>');
      case 'html_block':
        text(node.textContent, false);
        write('\n\n');
      default:
        throw SemanticCodecUnsupported('序列化不支持 node ${node.type}');
    }
  }

  void renderList(SemanticNode node, String extra, String Function(int) first) {
    if (closed?.type == node.type) {
      flushClose(3);
    } else if (inTightList) {
      flushClose(1);
    }
    final tight = _present(node.attrs['tight']);
    final old = inTightList;
    inTightList = tight;
    for (var i = 0; i < node.content.length; i++) {
      if (i > 0 && tight) flushClose(1);
      wrapBlock(extra, first(i), node, () => render(node.content[i], node, i));
    }
    inTightList = old;
  }

  bool mixable(SemanticMark m) {
    if (!{
      'em',
      'strong',
      'underline',
      'strikethrough',
      'spoiler',
      'link',
      'code',
    }.contains(m.type)) {
      throw SemanticCodecUnsupported('序列化不支持 mark ${m.type}');
    }
    return m.type != 'code';
  }

  bool expel(SemanticMark m) {
    mixable(m);
    return m.type == 'em' || m.type == 'strong';
  }

  bool isMarkAhead(SemanticNode parent, int index, SemanticMark mark) {
    for (; ; index++) {
      if (index >= parent.content.length) return false;
      final next = parent.content[index];
      if (next.type != 'hard_break') return _contains(next.marks, mark);
      // 检查每个后继换行，不跳过节点。
    }
  }

  String backticksFor(SemanticNode node, int side) {
    var len = 0;
    if (node.type == 'text') {
      for (final m in RegExp(r'`+').allMatches(node.text!)) {
        if (m[0]!.length > len) len = m[0]!.length;
      }
    }
    return '${len > 0 && side > 0 ? ' `' : '`'}${'`' * len}${len > 0 && side < 0 ? ' ' : ''}';
  }

  String markString(
    SemanticMark mark,
    bool open,
    SemanticNode parent,
    int index,
  ) {
    if (mark.attrs['htmlTag'] is String) {
      return open
          ? '<${mark.attrs['htmlTag']}>'
          : '</${mark.attrs['htmlTag']}>';
    }
    switch (mark.type) {
      case 'underline':
        return open ? '[u]' : '[/u]';
      case 'strikethrough':
        return mark.attrs['syntax'] == 's' ? (open ? '[s]' : '[/s]') : '~~';
      case 'spoiler':
        return open ? '[spoiler]' : '[/spoiler]';
      case 'em':
        return mark.attrs['syntax'] == 'i' ? (open ? '[i]' : '[/i]') : '*';
      case 'strong':
        return mark.attrs['syntax'] == 'b' ? (open ? '[b]' : '[/b]') : '**';
      case 'code':
        return backticksFor(
          parent.content[index - (open ? 0 : 1)],
          open ? -1 : 1,
        );
      case 'link':
        if (open) {
          linkMarkup = switch (mark.attrs['markup']) {
            '<>' => 'autolink',
            'bare' => 'linkify',
            final value => value,
          };
          if (linkMarkup == 'autolink' || linkMarkup == 'linkify') {
            inAutolink = true;
            return linkMarkup == 'autolink' ? '<' : '';
          }
          return '[';
        }
        inAutolink = null;
        final markup = linkMarkup;
        linkMarkup = null;
        if (markup == 'autolink') return '>';
        if (markup == 'linkify') return '';
        final href = mark.attrs['data-orig-href'] != null
            ? _scalar(mark.attrs['data-orig-href'])
            : (mark.attrs['href'] as String).replaceAllMapped(
                RegExp(r'[()"]'),
                (m) => '\\${m[0]}',
              );
        final title = _present(mark.attrs['title'])
            ? ' "${(mark.attrs['title'] as String).replaceAll('"', '\\"')}"'
            : '';
        return '${_present(mark.attrs['attachment']) ? '|attachment' : ''}]($href$title)';
      default:
        throw SemanticCodecUnsupported('序列化不支持 mark ${mark.type}');
    }
  }

  void renderInline(SemanticNode parent, [bool fromBlockStart = true]) {
    atBlockStart = fromBlockStart;
    final active = <SemanticMark>[];
    var trailing = '';
    for (var index = 0; index <= parent.content.length; index++) {
      SemanticNode? node = index < parent.content.length
          ? parent.content[index]
          : null;
      var marks = [...?node?.marks];
      if (node?.type == 'hard_break') {
        marks = marks.where((m) {
          if (index + 1 == parent.content.length) return false;
          final next = parent.content[index + 1];
          return _contains(next.marks, m) &&
              (next.type != 'text' || RegExp(r'\S').hasMatch(next.text!));
        }).toList();
      }
      var leading = trailing;
      trailing = '';
      if (node?.type == 'text' &&
          marks.any((m) => expel(m) && !_contains(active, m))) {
        final match = RegExp(
          r'^(\s*)(.*)$',
          multiLine: true,
        ).firstMatch(node!.text!)!;
        if (match[1]!.isNotEmpty) {
          leading += match[1]!;
          node = match[2]!.isEmpty ? null : node.copy(text: match[2]);
          if (node == null) marks = [...active];
        }
      }
      if (node?.type == 'text' &&
          marks.any((m) => expel(m) && !isMarkAhead(parent, index + 1, m))) {
        final match = RegExp(
          r'^(.*?)(\s*)$',
          multiLine: true,
        ).firstMatch(node!.text!)!;
        if (match[2]!.isNotEmpty) {
          trailing = match[2]!;
          node = match[1]!.isEmpty ? null : node.copy(text: match[1]);
          if (node == null) marks = [...active];
        }
      }
      final inner = marks.isEmpty ? null : marks.last;
      final noEsc = inner?.type == 'code';
      final len = marks.length - (noEsc ? 1 : 0);
      for (var i = 0; i < len; i++) {
        final mark = marks[i];
        if (!mixable(mark)) break;
        for (var j = 0; j < active.length; j++) {
          if (!mixable(active[j])) break;
          if (_eq(mark, active[j])) {
            if (i > j) {
              marks = [
                ...marks.take(j),
                mark,
                ...marks.sublist(j, i),
                ...marks.sublist(i + 1, len),
              ];
            } else if (j > i) {
              marks = [
                ...marks.take(i),
                ...marks.sublist(i + 1, j),
                mark,
                ...marks.sublist(j, len),
              ];
            }
            break;
          }
        }
      }
      var keep = 0;
      while (keep < active.length &&
          keep < len &&
          _eq(marks[keep], active[keep])) {
        keep++;
      }
      while (keep < active.length) {
        text(markString(active.removeLast(), false, parent, index), false);
      }
      if (leading.isNotEmpty) text(leading);
      if (node != null) {
        while (active.length < len) {
          final add = marks[active.length];
          active.add(add);
          text(markString(add, true, parent, index), false);
          atBlockStart = false;
        }
        if (noEsc && node.type == 'text') {
          text(
            '${markString(inner!, true, parent, index)}${node.text}${markString(inner, false, parent, index + 1)}',
            false,
          );
        } else {
          render(node, parent, index);
        }
        atBlockStart = false;
      }
    }
    atBlockStart = false;
  }
}

String _dimension(Object value) =>
    value is num && value == value.roundToDouble()
    ? value.toInt().toString()
    : '$value';
String _destination(String value) =>
    value.replaceAllMapped(RegExp(r'[\\()"]'), (m) => '\\${m[0]}');
String _bbValue(String value) {
  if (value.contains(RegExp(r'["\r\n\[\]]'))) {
    throw const SemanticCodecUnsupported('BBCode 属性包含控制语法');
  }
  return value;
}
