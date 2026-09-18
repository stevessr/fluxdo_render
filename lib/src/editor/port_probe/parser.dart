import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'model.dart';

class _Frame {
  final String type;
  final Map<String, dynamic> attrs;
  final List<ProbeNode> content = [];
  final List<ProbeMark> marks = [];
  _Frame(this.type, this.attrs);
}

/// MarkdownParseState 栈与官方 handler 的受限移植；输入保持 tokenizer DTO。
class ProbeTokenParser {
  final schema = ProbeSchema();
  List<_Frame> _stack = [];
  _Frame get _top => _stack.last;
  void _open(String type, [Map<String, dynamic> attrs = const {}]) =>
      _stack.add(_Frame(type, attrs));
  void _push(ProbeNode node) {
    if (_stack.isNotEmpty) _top.content.add(node);
  }

  ProbeNode _close() {
    final frame = _stack.removeLast();
    final node = schema.create(
      frame.type,
      attrs: frame.attrs,
      content: frame.content,
      marks: _stack.isEmpty ? [] : _top.marks,
      fill: true,
    );
    _push(node);
    return node;
  }

  void _text(String text) {
    if (text.isEmpty) return;
    final nodes = _top.content;
    if (nodes.isNotEmpty &&
        nodes.last.type == 'text' &&
        sameMarks(nodes.last.marks, _top.marks)) {
      nodes[nodes.length - 1] = nodes.last.copy(text: nodes.last.text! + text);
    } else {
      nodes.add(schema.create('text', text: text, marks: _top.marks));
    }
  }

  void _mark(String type, bool open, [Map<String, dynamic> attrs = const {}]) {
    _top.marks.removeWhere((m) => m.type == type);
    if (open) {
      _top.marks.add(schema.mark(type, attrs));
      _top.marks.sort(
        (a, b) => ProbeSchema.markOrder
            .indexOf(a.type)
            .compareTo(ProbeSchema.markOrder.indexOf(b.type)),
      );
    }
  }

  ProbeNode parseTokens(List<dynamic> tokens) {
    _stack = [_Frame('doc', {})];
    // 上游 link/quote/footnote 修改 token；不改调用方 DTO。
    _parse(jsonDecode(jsonEncode(tokens)) as List);
    ProbeNode result;
    do {
      result = _close();
    } while (_stack.isNotEmpty);
    return result;
  }

  dynamic _attr(Map t, String name) {
    for (final pair in t['attrs'] as List? ?? []) {
      if (pair[0] == name) return pair[1];
    }
    return null;
  }

  void _parse(List tokens) {
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i] as Map;
      final type = t['type'] as String;
      final value = t['content'] as String? ?? '';
      if (type == 'text') {
        _text(value);
        continue;
      }
      if (type == 'inline') {
        _parse(t['children'] as List? ?? []);
        continue;
      }
      if (type == 'softbreak' || type == 'hardbreak') {
        _push(schema.create('hard_break', marks: _top.marks));
        continue;
      }
      if (type == 'hr') {
        _push(schema.create('horizontal_rule'));
        continue;
      }
      if (type == 'code_inline') {
        _mark('code', true);
        _text(_stripNewline(value));
        _mark('code', false);
        continue;
      }
      if (type == 'code_block' || type == 'fence' || type == 'html_block') {
        _open(
          type == 'html_block' ? type : 'code_block',
          type == 'fence' ? {'params': t['info'] ?? ''} : {},
        );
        _text(type == 'html_block' ? value.trim() : _stripNewline(value));
        _close();
        continue;
      }
      if (type == 'html_inline') {
        _html(value);
        continue;
      }
      if (type == 'quote_header_open') {
        (tokens[i + 3] as Map)['content'] = '';
        continue;
      }
      if ({
        'quote_header_close',
        'quote_controls_open',
        'quote_controls_close',
        'footnote_block_open',
        'footnote_block_close',
        'footnote_anchor',
      }.contains(type)) {
        continue;
      }
      if (type == 'footnote_ref') {
        _push(
          schema.create(
            'footnote',
            attrs: {'id': t['meta']['id']},
            marks: _top.marks,
          ),
        );
        continue;
      }
      if (type == 'footnote_open') {
        final end = tokens.indexWhere(
          (v) => v['type'] == 'footnote_close',
          i + 1,
        );
        if (end < 0) throw ProbeUnsupported('脚注未闭合');
        final inner = tokens.sublist(i + 1, end);
        final doc = _top;
        final id = t['meta']['id'];
        for (var root = 0; root < doc.content.length; root++) {
          final positions = <int>[];
          void scan(ProbeNode n, int start) {
            var pos = start;
            for (final child in n.content) {
              if (child.type == 'footnote' && child.attrs['id'] == id) {
                positions.add(pos);
              }
              scan(child, pos + 1);
              pos += child.nodeSize;
            }
          }

          scan(doc.content[root], 0);
          for (final pos in positions) {
            _stack = [];
            _open('footnote');
            _parse(inner);
            final note = _close();
            _stack = [doc];
            // 官方依次使用原位置 replace，故多 ref 保留其可观察的错位行为。
            doc.content[root] = _replace(doc.content[root], pos, pos + 2, note);
          }
        }
        tokens.removeRange(i + 1, end + 1);
        continue;
      }
      if (type == 'bbcode_open' || type == 'bbcode_close') {
        final tag = t['tag'];
        if (tag == 'blockquote') continue;
        if (!{'aside', 'details', 'summary'}.contains(tag)) {
          throw ProbeUnsupported('不支持 bbcode $tag');
        }
        if (type.endsWith('_close')) {
          _close();
          continue;
        }
        if (tag == 'aside') {
          _open('quote', {
            'username': _attr(t, 'data-username'),
            'displayName': _attr(t, 'data-display-name'),
            'postNumber': _attr(t, 'data-post'),
            'topicId': _attr(t, 'data-topic'),
            'full': _attr(t, 'data-full'),
          });
        } else {
          _open(tag as String);
        }
        continue;
      }
      final match = RegExp(r'^(.*)_(open|close)$').firstMatch(type);
      if (match != null) {
        var base = match[1]!;
        final open = match[2] == 'open';
        if (base == 'bbcode_b') base = 'strong';
        if (base == 'bbcode_i') base = 'em';
        if (ProbeSchema.markOrder.contains(base)) {
          final attrs = <String, dynamic>{};
          if (base == 'link' && open) {
            var attachment = false;
            for (
              var j = i + 1;
              j < tokens.length && tokens[j]['type'] != 'link_close';
              j++
            ) {
              if (tokens[j]['type'] == 'text' &&
                  (tokens[j]['content'] as String).endsWith('|attachment')) {
                final s = tokens[j]['content'] as String;
                tokens[j]['content'] = s.substring(0, s.length - 11);
                attachment = true;
                break;
              }
            }
            attrs.addAll({
              'href': _attr(t, 'href'),
              'title': _attr(t, 'title'),
              'markup': t['markup'] == '' ? null : t['markup'],
              'attachment': attachment,
              'data-orig-href': _attr(t, 'data-orig-href'),
            });
          }
          _mark(base, open, attrs);
          continue;
        }
        if ({
          'paragraph',
          'heading',
          'blockquote',
          'bullet_list',
          'ordered_list',
          'list_item',
        }.contains(base)) {
          if (!open) {
            _close();
            continue;
          }
          final attrs = <String, dynamic>{};
          if (base == 'heading') {
            attrs['level'] = int.parse((t['tag'] as String).substring(1));
          }
          if (base.endsWith('_list')) {
            var j = i + 1;
            while (j < tokens.length && tokens[j]['type'] == 'list_item_open') {
              j++;
            }
            attrs['tight'] = j < tokens.length
                ? tokens[j]['hidden'] == true
                : false;
            if (base == 'ordered_list') {
              attrs['order'] = int.tryParse('${_attr(t, 'start')}') ?? 1;
            }
          }
          _open(base, attrs);
          continue;
        }
      }
      throw ProbeUnsupported('不支持 token $type');
    }
  }

  String _stripNewline(String s) =>
      s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
  void _html(String value) {
    final opening = RegExp(
      r'^<([a-z]+)(\s[^>]*)?/?>$',
      caseSensitive: false,
    ).firstMatch(value);
    final closing = RegExp(
      r'^</([a-z]+)>$',
      caseSensitive: false,
    ).firstMatch(value);
    if (opening == null && closing == null) return;
    final tag = (opening ?? closing)![1]!.toLowerCase();
    final isOpen = opening != null;
    if (tag == 'br' && isOpen) {
      _push(schema.create('hard_break', marks: _top.marks));
      return;
    }
    const marks = {
      'strong': 'strong',
      'b': 'strong',
      'em': 'em',
      'i': 'em',
      'code': 'code',
      's': 'strikethrough',
      'strike': 'strikethrough',
    };
    if (marks.containsKey(tag)) {
      _mark(marks[tag]!, isOpen);
      return;
    }
    final element = isOpen
        ? html.parseFragment(value).children.firstOrNull
        : null;
    if (tag == 'a') {
      if (!isOpen) {
        _mark('link', false);
      } else if (element?.attributes['href'] != null) {
        _mark('link', true, {
          'href': element!.attributes['href'],
          'title': element.attributes['title'],
        });
      }
      return;
    }
    if (tag == 'img') throw ProbeUnsupported('本验证未移植 image');
    const allowed = {
      'kbd',
      'sup',
      'sub',
      'small',
      'big',
      'del',
      'ins',
      'mark',
      'ruby',
      'rb',
      'rt',
      'rp',
      'span',
    };
    if (!allowed.contains(tag)) return;
    if (!isOpen) {
      _close();
      return;
    }
    final lang = {'span', 'ruby', 'rb', 'rt'}.contains(tag)
        ? element?.attributes['lang']
        : null;
    _open('html_inline', {
      'tag': tag,
      'htmlAttrs': lang == null ? null : {'lang': lang},
    });
  }

  /// Slice(openStart=0,openEnd=0) 在单个父节点内的替换子集。
  ProbeNode _replace(
    ProbeNode parent,
    int from,
    int to,
    ProbeNode replacement,
  ) {
    var offset = 0;
    final result = <ProbeNode>[];
    var inserted = false;
    for (final child in parent.content) {
      final end = offset + child.nodeSize;
      if (from > offset && to < end && child.type != 'text') {
        result.add(
          _replace(child, from - offset - 1, to - offset - 1, replacement),
        );
        inserted = true;
      } else if (end <= from || offset >= to) {
        if (!inserted && offset >= to) {
          result.add(replacement);
          inserted = true;
        }
        result.add(child);
      } else {
        if (child.type != 'text' && (from > offset || to < end)) {
          throw ProbeUnsupported('脚注替换跨容器边界：需要完整 PM Slice/Replace');
        }
        if (child.type == 'text' && from > offset) {
          result.add(child.copy(text: child.text!.substring(0, from - offset)));
        }
        if (!inserted) {
          result.add(replacement);
          inserted = true;
        }
        if (child.type == 'text' && to < end) {
          result.add(child.copy(text: child.text!.substring(to - offset)));
        }
      }
      offset = end;
    }
    if (!inserted) result.add(replacement);
    return parent.copy(content: result);
  }
}
