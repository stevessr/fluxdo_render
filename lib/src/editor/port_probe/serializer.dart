import 'model.dart';

/// 独立移植 PM MarkdownSerializerState 与固定 Discourse 八扩展。
/// 不修剪输出：扩展显式写入的尾换行属于序列化协议。
String serializeProbe(ProbeNode doc) {
  final state = _ProbeSerializerState();
  state.renderContent(doc);
  state.afterSerialize();
  return state.out;
}

// 仅实现 JSON attrs 在官方分支中使用的 JS 转换，不执行用户代码。
bool _truth(Object? v) =>
    v != null && v != false && v != '' && v != 0 && !(v is num && v.isNaN);

String _jsString(Object? v) {
  if (v is List) {
    return v.map((e) => e == null ? '' : _jsString(e)).join(',');
  }
  if (v is Map) return '[object Object]';
  if (v is num && v.isFinite && v == v.truncateToDouble()) {
    return v.toInt().toString();
  }
  return '$v';
}

num _jsNumber(Object? v) {
  if (v == null || v == false) return 0;
  if (v == true) return 1;
  if (v is num) return v;
  final s = _jsString(v).trim();
  if (s.isEmpty) return 0;
  if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(s)) {
    return int.parse(s.substring(2), radix: 16);
  }
  if (RegExp(r'^0[bB][01]+$').hasMatch(s)) {
    return int.parse(s.substring(2), radix: 2);
  }
  if (RegExp(r'^0[oO][0-7]+$').hasMatch(s)) {
    return int.parse(s.substring(2), radix: 8);
  }
  if (s == 'Infinity' || s == '+Infinity') return double.infinity;
  if (s == '-Infinity') return double.negativeInfinity;
  if (!RegExp(r'^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$').hasMatch(s)) {
    return double.nan;
  }
  return num.tryParse(s) ?? double.nan;
}

Object _jsAdd(Object? a, int b) => a is String || a is List || a is Map
    ? '${_jsString(a)}$b'
    : _jsNumber(a) + b;

String _repeat(String s, Object? count) {
  final n = _jsNumber(count);
  if (n.isNaN || n <= 0) return '';
  // 上游是 i < n 循环而非 String.repeat，因此正小数向上取整。
  // 正无穷在官方会永不终止，本探针明确拒绝，不能默默归零。
  if (!n.isFinite) throw ProbeUnsupported('序列化 repeat 次数必须有限');
  return s * n.ceil();
}

Iterable<MapEntry<String, Object?>> _htmlEntries(Object? attrs) {
  if (!_truth(attrs)) return const [];
  if (attrs is Map) {
    return attrs.entries.map((e) => MapEntry(_jsString(e.key), e.value));
  }
  if (attrs is List) {
    return attrs.asMap().entries.map((e) => MapEntry('${e.key}', e.value));
  }
  if (attrs is String) {
    return List.generate(attrs.length, (i) => MapEntry('$i', attrs[i]));
  }
  return const [];
}

String _htmlValue(Object? value) {
  // 官方调用 v.replace，不对非字符串宽容地 String(v)。
  if (value is! String) {
    throw ProbeUnsupported('htmlAttrs 值没有 JS String.replace 方法');
  }
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('"', '&quot;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

bool _eq(ProbeMark a, ProbeMark b) => sameMarks([a], [b]);
bool _contains(List<ProbeMark> set, ProbeMark mark) =>
    set.any((m) => _eq(m, mark));

/// 对应 to_markdown.ts 的延迟闭块、行前缀和可交换 mark 状态机。
class _ProbeSerializerState {
  String delim = '', out = '';
  ProbeNode? closed;
  bool? inAutolink;
  Object? linkMarkup;
  bool atBlockStart = false, inTightList = false, inTable = false;
  final footnoteContents = <ProbeNode>[];

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

  void closeBlock(ProbeNode node) {
    closed = node;
  }

  void wrapBlock(
    String extra,
    String? first,
    ProbeNode node,
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

  void renderContent(ProbeNode parent) {
    for (var i = 0; i < parent.content.length; i++) {
      render(parent.content[i], parent, i);
    }
  }

  void render(ProbeNode node, ProbeNode parent, int index) {
    final a = node.attrs;
    switch (node.type) {
      case 'doc':
      case 'list_item':
        renderContent(node);
      case 'text':
        text(node.text!, inAutolink != true);
      case 'paragraph':
        renderInline(node);
        closeBlock(node);
      case 'heading':
        write('${_repeat('#', a['level'])} ');
        renderInline(node, false);
        closeBlock(node);
      case 'horizontal_rule':
        write(_truth(a['markup']) ? _jsString(a['markup']) : '---');
        closeBlock(node);
      case 'hard_break':
        write(inTable ? '<br>' : '\n');
      case 'blockquote':
        wrapBlock('> ', null, node, () => renderContent(node));
      case 'code_block':
        final ticks = RegExp(
          r'`{3,}',
          multiLine: true,
        ).allMatches(node.textContent).map((m) => m[0]!).toList()..sort();
        final fence = ticks.isEmpty ? '```' : '${ticks.last}`';
        write('$fence${_truth(a['params']) ? _jsString(a['params']) : ''}\n');
        text(node.textContent, false);
        write('\n');
        write(fence);
        closeBlock(node);
      case 'bullet_list':
        renderList(
          node,
          '  ',
          (_) => '${_truth(a['bullet']) ? _jsString(a['bullet']) : '*'} ',
        );
      case 'ordered_list':
        final start = _truth(a['order']) ? a['order'] : 1;
        final width = _jsString(
          _jsNumber(_jsAdd(start, node.content.length)) - 1,
        ).length;
        renderList(node, ' ' * (width + 2), (i) {
          final label = _jsString(_jsAdd(start, i));
          return '${_repeat(' ', width - label.length)}$label. ';
        });
      case 'quote':
        final name = _truth(a['displayName'])
            ? a['displayName']
            : a['username'];
        final params = _truth(name)
            ? '="${_jsString(name)}${_truth(a['postNumber']) ? ', post:${_jsString(a['postNumber'])}' : ''}${_truth(a['topicId']) ? ', topic:${_jsString(a['topicId'])}' : ''}${_truth(a['displayName']) && _truth(a['username']) ? ', username:${_jsString(a['username'])}' : ''}"'
            : '';
        write('[quote$params]\n');
        renderContent(node);
        write('[/quote]\n\n');
      case 'details':
        renderContent(node);
        write('[/details]\n\n');
      case 'summary':
        write(node.content.isEmpty ? '[details' : '[details="');
        for (final child in node.content) {
          if (child.text != null && child.text!.isNotEmpty) {
            // JS 的 undefined 参数使用 text 默认 true，false 则禁用转义。
            text(child.text!.replaceAll('"', '“'), inAutolink ?? true);
          }
        }
        write(node.content.isEmpty ? ']\n' : '"]\n');
      case 'html_inline':
        final html = _htmlEntries(
          a['htmlAttrs'],
        ).map((e) => ' ${e.key}="${_htmlValue(e.value)}"').join();
        write('<${_jsString(a['tag'])}$html>');
        renderInline(node);
        write('</${_jsString(a['tag'])}>');
      case 'html_block':
        text(node.textContent, false);
        write('\n\n');
      case 'footnote':
        if (node.content.length == 1 &&
            node.content.first.type == 'paragraph') {
          write('^[');
          renderContent(node.content.first);
          write(']');
        } else {
          footnoteContents.add(node);
          write('[^${footnoteContents.length}]');
        }
      default:
        throw ProbeUnsupported('序列化不支持 node ${node.type}');
    }
  }

  void renderList(ProbeNode node, String extra, String Function(int) first) {
    if (closed?.type == node.type) {
      flushClose(3);
    } else if (inTightList) {
      flushClose(1);
    }
    final tight = _truth(node.attrs['tight']);
    final old = inTightList;
    inTightList = tight;
    for (var i = 0; i < node.content.length; i++) {
      if (i > 0 && tight) flushClose(1);
      wrapBlock(extra, first(i), node, () => render(node.content[i], node, i));
    }
    inTightList = old;
  }

  void afterSerialize() {
    // 动态长度与官方一致：脚注内容可能继续登记块脚注。
    for (var i = 0; i < footnoteContents.length; i++) {
      final old = delim;
      write('[^${i + 1}]: ');
      delim += '    ';
      renderContent(footnoteContents[i]);
      delim = old;
    }
  }

  bool mixable(ProbeMark m) {
    if (!{'em', 'strong', 'link', 'code'}.contains(m.type)) {
      throw ProbeUnsupported('序列化不支持 mark ${m.type}');
    }
    return m.type != 'code';
  }

  bool expel(ProbeMark m) {
    mixable(m);
    return m.type == 'em' || m.type == 'strong';
  }

  bool isMarkAhead(ProbeNode parent, int index, ProbeMark mark) {
    for (; ; index++) {
      if (index >= parent.content.length) return false;
      final next = parent.content[index];
      if (next.type != 'hard_break') return _contains(next.marks, mark);
      // 保留上游的双重递增语义，不能自行“修正”。
      index++;
    }
  }

  String backticksFor(ProbeNode node, int side) {
    var len = 0;
    if (node.type == 'text') {
      for (final m in RegExp(r'`+').allMatches(node.text!)) {
        if (m[0]!.length > len) len = m[0]!.length;
      }
    }
    return '${len > 0 && side > 0 ? ' `' : '`'}${'`' * len}${len > 0 && side < 0 ? ' ' : ''}';
  }

  String markString(ProbeMark mark, bool open, ProbeNode parent, int index) {
    switch (mark.type) {
      case 'em':
        return '*';
      case 'strong':
        return '**';
      case 'code':
        return backticksFor(
          parent.content[index - (open ? 0 : 1)],
          open ? -1 : 1,
        );
      case 'link':
        if (open) {
          linkMarkup = mark.attrs['markup'];
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
            ? _jsString(mark.attrs['data-orig-href'])
            : (mark.attrs['href'] as String).replaceAllMapped(
                RegExp(r'[()"]'),
                (m) => '\\${m[0]}',
              );
        final title = _truth(mark.attrs['title'])
            ? ' "${(mark.attrs['title'] as String).replaceAll('"', '\\"')}"'
            : '';
        return '${_truth(mark.attrs['attachment']) ? '|attachment' : ''}]($href$title)';
      default:
        throw ProbeUnsupported('序列化不支持 mark ${mark.type}');
    }
  }

  void renderInline(ProbeNode parent, [bool fromBlockStart = true]) {
    atBlockStart = fromBlockStart;
    final active = <ProbeMark>[];
    var trailing = '';
    for (var index = 0; index <= parent.content.length; index++) {
      ProbeNode? node = index < parent.content.length
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
