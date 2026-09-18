import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'document.dart';
import '../model/raw_media_html.dart' show importRawMediaHtml;
import '../model/link_text.dart' show displayLinkText;
import '../model/poll_codec.dart' show importSemanticPollTokenNode;
import 'document_codec.dart';

class _Frame {
  final String type;
  final Map<String, dynamic> attrs;
  final List<SemanticNode> content = [];
  final List<SemanticMark> marks = [];
  _Frame(this.type, this.attrs);
}

/// 官方 tokenizer DTO 的生产子集；未知 token 明确拒绝，不自动补全结构。
class SemanticTokenParser {
  final schema = SemanticSchema();
  List<_Frame> _stack = [];
  _Frame get _top => _stack.last;
  void _open(String type, [Map<String, dynamic> attrs = const {}]) =>
      _stack.add(_Frame(type, attrs));
  void _push(SemanticNode node) {
    if (_stack.isNotEmpty) _top.content.add(node);
  }

  SemanticNode _close() {
    final frame = _stack.removeLast();
    if (frame.marks.isNotEmpty) throw SemanticCodecUnsupported('mark 未闭合');
    // 空引用的落点不序列化成虚构正文，仍可直接输入。
    if ({
          'quote',
          'blockquote',
          'list_item',
          'spoiler',
          'callout',
        }.contains(frame.type) &&
        frame.content.isEmpty) {
      frame.content.add(SemanticNode('paragraph'));
    }
    if (frame.type == 'details') {
      if (frame.content.isEmpty) frame.content.add(SemanticNode('summary'));
      if (frame.content.length == 1) {
        frame.content.add(SemanticNode('paragraph'));
      }
    }
    if (frame.type == 'blockquote' &&
        frame.content.isNotEmpty &&
        frame.content.first.type == 'paragraph') {
      final paragraph = frame.content.first;
      final runs = paragraph.content;
      final first = runs.firstOrNull;
      final callout = first?.type == 'text'
          ? RegExp(
              r'^\[!([a-zA-Z]+)\]([+-])?(?:\s+(.*))?$',
            ).firstMatch(first!.text!)
          : null;
      if (callout != null &&
          (runs.length == 1 ||
              runs[1].type == 'hard_break' && runs[1].attrs['soft'] == true)) {
        final node = schema.create(
          'callout',
          attrs: {
            ...frame.attrs,
            'typeRaw': callout[1]!,
            'title': callout[3],
            'foldable': callout[2] == null ? null : callout[2] == '+',
          },
          content: [
            if (runs.length <= 2 && frame.content.length == 1)
              SemanticNode('paragraph'),
            if (runs.length > 2) paragraph.copy(content: runs.sublist(2)),
            ...frame.content.skip(1),
          ],
        );
        _push(node);
        return node;
      }
    }
    final node = schema.create(
      frame.type,
      attrs: frame.attrs,
      content: frame.content,
      marks: _stack.isEmpty ? [] : _top.marks,
    );
    _push(node);
    return node;
  }

  void _text(String text, [Map<String, dynamic> attrs = const {}]) {
    if (text.isEmpty) return;
    final nodes = _top.content;
    if (nodes.isNotEmpty &&
        nodes.last.type == 'text' &&
        jsonEncode(nodes.last.attrs) == jsonEncode(attrs) &&
        sameSemanticMarks(nodes.last.marks, _top.marks)) {
      nodes[nodes.length - 1] = nodes.last.copy(text: nodes.last.text! + text);
    } else {
      nodes.add(
        schema.create('text', text: text, attrs: attrs, marks: _top.marks),
      );
    }
  }

  void _mark(String type, bool open, [Map<String, dynamic> attrs = const {}]) {
    final exists = _top.marks.any((m) => m.type == type);
    if (exists == open) throw SemanticCodecUnsupported('mark 开闭不匹配 $type');
    _top.marks.removeWhere((m) => m.type == type);
    if (open) {
      _top.marks.add(schema.mark(type, attrs));
      _top.marks.sort(
        (a, b) => SemanticSchema.markOrder
            .indexOf(a.type)
            .compareTo(SemanticSchema.markOrder.indexOf(b.type)),
      );
    }
  }

  SemanticNode parseTokens(List<dynamic> tokens) {
    _stack = [_Frame('doc', {})];
    // 附件标签局部归一化；不修改调用方 DTO。
    _parse(jsonDecode(jsonEncode(tokens)) as List);
    if (_stack.length != 1) throw SemanticCodecUnsupported('token 未闭合');
    final result = _close();
    schema.check(result);
    return result;
  }

  dynamic _attr(Map t, String name) {
    for (final pair in t['attrs'] as List? ?? []) {
      if (pair[0] == name) return pair[1];
    }
    return null;
  }

  Map<String, dynamic> _sourceAttrs(Map t) {
    final result = <String, dynamic>{};
    final attrs = t['attrs'];
    if (attrs != null && attrs is! List) {
      throw SemanticCodecUnsupported('attrs 必须为键值对');
    }
    for (final pair in attrs as List? ?? []) {
      if (pair is! List || pair.length != 2 || pair[0] is! String) {
        throw SemanticCodecUnsupported('非法 token attrs');
      }
      result[pair[0] as String] = pair[1];
    }
    if (t['meta'] != null) result['_tokenMeta'] = t['meta'];
    return result;
  }

  void _parse(List tokens) {
    for (var i = 0; i < tokens.length; i++) {
      final t = tokens[i] as Map;
      final type = t['type'] as String;
      final value = t['content'] as String? ?? '';
      if (type == 'math_inline') {
        _push(
          schema.create(
            'math_inline',
            attrs: {
              ..._sourceAttrs(t),
              'content': value,
              'mathType': (t['meta'] as Map?)?['mathType'] ?? 'tex',
            },
            marks: _top.marks,
          ),
        );
        continue;
      }
      if (type == 'footnote_ref') {
        _push(
          schema.create(
            'footnote_ref',
            attrs: {
              ..._sourceAttrs(t),
              ...Map<String, dynamic>.from(t['meta'] as Map? ?? {}),
            },
            marks: _top.marks,
          ),
        );
        continue;
      }
      if (type == 'footnote_anchor') {
        final footnote = _stack.where((f) => f.type == 'footnote').lastOrNull;
        if (footnote == null ||
            (t['meta'] as Map?)?['id'] != footnote.attrs['id'] ||
            value.isNotEmpty ||
            (t['children'] as List? ?? []).isNotEmpty) {
          throw SemanticCodecUnsupported('非法脚注回链');
        }
        continue;
      }
      if (type == 'check_open') {
        final classes = (_attr(t, 'class') as String? ?? '').split(' ');
        if (!classes.contains('chcklst-box') ||
            i + 1 >= tokens.length ||
            tokens[i + 1]['type'] != 'check_close') {
          throw SemanticCodecUnsupported('非法 check');
        }
        _push(
          schema.create(
            'check',
            attrs: {
              ..._sourceAttrs(t),
              'checked': classes.contains('checked'),
              'permanent': classes.contains('permanent'),
            },
            marks: _top.marks,
          ),
        );
        i++;
        continue;
      }
      if (type == 'poll_open') {
        var depth = 1;
        var end = i + 1;
        for (; end < tokens.length; end++) {
          if (tokens[end]['type'] == 'poll_open') depth++;
          if (tokens[end]['type'] == 'poll_close') {
            depth--;
            if (depth == 0) break;
          }
        }
        if (end == tokens.length) throw SemanticCodecUnsupported('投票未闭合');
        final poll = importSemanticPollTokenNode(tokens.sublist(i, end + 1));
        if (poll == null) throw SemanticCodecUnsupported('投票结构不支持');
        _push(
          schema.create(
            'poll',
            attrs: {
              ..._sourceAttrs(t),
              'rawHtml': poll.rawHtml,
              'pollName': poll.pollName,
              'title': poll.title,
            },
          ),
        );
        i = end;
        continue;
      }
      if (type == 'wrap_open' ||
          type == 'wrap_close' ||
          type == 'bbcode_open' &&
              t['tag'] == 'div' &&
              (_attr(t, 'class') as String? ?? '')
                  .split(' ')
                  .contains('d-wrap') ||
          type == 'bbcode_close' && t['tag'] == 'div' && _top.type == 'wrap') {
        if (type.endsWith('_open')) {
          _open('wrap', _sourceAttrs(t));
        } else {
          if (_top.type != 'wrap') {
            throw SemanticCodecUnsupported('wrap 开闭不匹配');
          }
          _close();
        }
        continue;
      }
      if (type == 'wrap_bbcode') {
        if (t['nesting'] == 1 && _attr(t, 'class') != 'spoiler') {
          throw SemanticCodecUnsupported('未知 wrap_bbcode');
        }
        if (t['nesting'] == 1) {
          _open('spoiler', _sourceAttrs(t));
        } else if (t['nesting'] == -1 && _top.type == 'spoiler') {
          _close();
        } else {
          throw SemanticCodecUnsupported('spoiler 开闭不匹配');
        }
        continue;
      }
      if (type == 'text') {
        _text(value, _sourceAttrs(t));
        continue;
      }
      if (type == 'image' || type == 'emoji') {
        final a = _sourceAttrs(t);
        if (type == 'emoji') {
          a['name'] = (a['alt'] as String? ?? '').replaceAll(':', '');
          a['url'] = a['src'];
          a['isOnlyEmoji'] = (a['class'] as String? ?? '').contains(
            'only-emoji',
          );
        } else {
          final match = RegExp(
            r'^(.*)\|(\d+)x(\d+)(?:,\s*(\d+)%)?$',
          ).firstMatch(value);
          a['alt'] = match?[1] ?? value;
          if (match != null) {
            a['origWidth'] = int.parse(match[2]!);
            a['origHeight'] = int.parse(match[3]!);
            if (match[4] != null) a['scale'] = int.parse(match[4]!);
            final scale = match[4] == null ? 100 : int.parse(match[4]!);
            a['width'] = (a['origWidth'] * scale / 100).floor();
            a['height'] = (a['origHeight'] * scale / 100).floor();
          }
          for (final key in ['width', 'height', 'scale']) {
            if (a[key] is String) {
              final parsed = num.tryParse(a[key]);
              if (parsed == null) throw SemanticCodecUnsupported('非法图片数值 $key');
              a[key] = parsed;
            }
          }
          if (a['data-orig-src'] != null) a['src'] = a['data-orig-src'];
        }
        _push(schema.create(type, attrs: a, marks: _top.marks));
        continue;
      }
      if (type == 'mention_open' || type == 'span_open') {
        var end = tokens.indexWhere(
          (v) => v['type'] == type.replaceFirst('_open', '_close'),
          i + 1,
        );
        if (end < 0 ||
            tokens.sublist(i + 1, end).any((v) => v['type'] != 'text')) {
          throw SemanticCodecUnsupported('原子内容不受支持');
        }
        final label = tokens
            .sublist(i + 1, end)
            .map((v) => v['content'])
            .join();
        final a = _sourceAttrs(t);
        if (type == 'span_open' &&
            (a['class'] as String? ?? '').split(' ').contains('hashtag-raw')) {
          if (!label.startsWith('#') || label.length == 1) {
            throw SemanticCodecUnsupported('非法 hashtag 引用');
          }
          _push(
            schema.create(
              'hashtag',
              attrs: {...a, 'ref': label.substring(1), 'href': a['href'] ?? ''},
              marks: _top.marks,
            ),
          );
          i = end;
          continue;
        }
        if (type == 'mention_open') {
          a['username'] = label.replaceFirst(RegExp(r'^@'), '');
          a['href'] ??= '/u/${a['username']}';
          _push(schema.create('mention', attrs: a, marks: _top.marks));
        } else {
          if (a['class'] != 'discourse-local-date') {
            throw SemanticCodecUnsupported('不支持 span');
          }
          if (a['data-range'] == 'from') {
            final next = end + 2;
            if (next >= tokens.length ||
                tokens[end + 1]['type'] != 'text' ||
                tokens[end + 1]['content'] != '→' ||
                tokens[next]['type'] != 'span_open') {
              throw SemanticCodecUnsupported('日期范围未闭合');
            }
            final to = _sourceAttrs(tokens[next] as Map);
            final stop = tokens.indexWhere(
              (v) => v['type'] == 'span_close',
              next + 1,
            );
            if (to['class'] != 'discourse-local-date' ||
                to['data-range'] != 'to' ||
                stop < 0 ||
                tokens
                    .sublist(next + 1, stop)
                    .any((v) => v['type'] != 'text')) {
              throw SemanticCodecUnsupported('日期范围终点非法');
            }
            for (final key in {...a.keys, ...to.keys}) {
              if (!{
                    'data-date',
                    'data-time',
                    'data-email-preview',
                    'data-range',
                    '_tokenMeta',
                  }.contains(key) &&
                  a[key] != to[key]) {
                throw SemanticCodecUnsupported('日期范围属性不一致');
              }
            }
            a['endDate'] = to['data-date'];
            a['endTime'] = to['data-time'];
            a['_rangeEndAttrs'] = to;
            end = stop;
          } else if (a['data-range'] != null) {
            throw SemanticCodecUnsupported('孤立日期范围终点');
          }
          for (final key in [
            'date',
            'time',
            'timezone',
            'format',
            'recurring',
          ]) {
            if (a['data-$key'] != null) a[key] = a['data-$key'];
          }
          a['displayedTimezone'] = a['data-displayed-timezone'];
          a['timezones'] =
              (a['data-timezones'] as String?)?.split('|') ?? <String>[];
          a['countdownRaw'] = a['data-countdown'];
          a['countdown'] =
              a['data-countdown'] != null && a['data-countdown'] != 'false';
          a['fallbackText'] = label;
          _push(schema.create('local_date', attrs: a, marks: _top.marks));
        }
        i = end;
        continue;
      }
      if (type == 'inline') {
        if (_top.type == 'paragraph' &&
            _top.content.isEmpty &&
            (t['children'] as List? ?? []).any(
              (c) => c['type'] == 'html_inline',
            ) &&
            (importRawMediaHtml(value.trim(), 'semantic_media') != null ||
                RegExp(
                  r'^\s*<(?:video|audio)(?=\s|>)',
                  caseSensitive: false,
                ).hasMatch(value))) {
          // bundle 会把完整媒体及其尾部解析成 inline；这里只保留整段源。
          // 是否可播放由媒体投影的安全校验决定，不能在这里丢弃不安全源。
          final frame = _stack.removeLast();
          _stack.add(_Frame('html_block', frame.attrs));
          _text(value.trim());
          continue;
        }
        final children = t['children'] as List? ?? [];
        if (children.length == 1 &&
            children.single['type'] == 'text' &&
            children.single['content'] == value &&
            !value.contains(RegExp(r'[<>\r\n]'))) {
          // tokenizer 确认整段为字面文本。保留 BBCode 等 cook 后处理源，
          // 不把普通 HTML 放行；文本编辑后由 serializer 恢复常规转义。
          _text(value, {
            ..._sourceAttrs(children.single as Map),
            'literalSource': value,
          });
        } else {
          _parse(children);
        }
        continue;
      }
      if (type == 'softbreak' || type == 'hardbreak') {
        _push(
          schema.create(
            'hard_break',
            attrs: {'soft': type == 'softbreak'},
            marks: _top.marks,
          ),
        );
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
      if (type == 'code_block' ||
          type == 'fence' ||
          type == 'html_block' ||
          type == 'math_block') {
        _open(
          {'html_block', 'math_block'}.contains(type) ? type : 'code_block',
          {..._sourceAttrs(t), if (type == 'fence') 'params': t['info'] ?? ''},
        );
        _text(_stripNewline(value));
        _close();
        continue;
      }
      if (type == 'html_inline') {
        _html(value);
        continue;
      }
      if (type == 'quote_header_open' || type == 'quote_controls_open') {
        final close = type.replaceFirst('_open', '_close');
        final end = tokens.indexWhere((v) => v['type'] == close, i + 1);
        if (end < 0) throw SemanticCodecUnsupported('引用标题未闭合');
        const generatedHeader = {
          'quote_header_open',
          'quote_header_close',
          'quote_controls_open',
          'quote_controls_close',
          'text',
          'link_open',
          'link_close',
          'image',
          'html_inline',
        };
        if (tokens
            .sublist(i + 1, end)
            .any((token) => !generatedHeader.contains(token['type']))) {
          throw SemanticCodecUnsupported('引用标题存在未知 token');
        }
        i = end;
        continue;
      }
      if (type == 'bbcode_open' || type == 'bbcode_close') {
        final tag = t['tag'];
        if (tag == 'blockquote') {
          if (_top.type != 'quote') {
            throw SemanticCodecUnsupported('引用正文包裹位置非法');
          }
          continue;
        }
        if (tag == 'div' &&
            _attr(t, 'class') == 'd-image-grid' &&
            type.endsWith('_open')) {
          _open('image_grid', _sourceAttrs(t));
          continue;
        }
        if (tag == 'div' &&
            type.endsWith('_close') &&
            _top.type == 'image_grid') {
          _close();
          continue;
        }
        if (!{'aside', 'details', 'summary'}.contains(tag)) {
          throw SemanticCodecUnsupported('不支持 bbcode $tag');
        }
        if (type.endsWith('_close')) {
          if (_top.type != (tag == 'aside' ? 'quote' : tag)) {
            throw SemanticCodecUnsupported('bbcode 闭合类型不匹配');
          }
          _close();
          continue;
        }
        if (tag == 'aside') {
          _open('quote', {
            ..._sourceAttrs(t),
            'username': _attr(t, 'data-username'),
            'displayName': _attr(t, 'data-display-name'),
            'postNumber': _quoteInteger(_attr(t, 'data-post')),
            'topicId': _quoteInteger(_attr(t, 'data-topic')),
            'full': _quoteBoolean(_attr(t, 'data-full')),
          });
        } else {
          _open(tag as String, _sourceAttrs(t));
        }
        continue;
      }
      final match = RegExp(r'^(.*)_(open|close)$').firstMatch(type);
      if (match != null) {
        var base = match[1]!;
        final open = match[2] == 'open';
        if (base == 'bbcode_b') base = 'strong';
        if (base == 'bbcode_i') base = 'em';
        base =
            const {
              'bbcode_u': 'underline',
              'bbcode_s': 'strikethrough',
              'u': 'underline',
              's': 'strikethrough',
              'bbcode_spoiler': 'spoiler',
              'thead': 'table_head',
              'tbody': 'table_body',
              'tr': 'table_row',
              'th': 'table_cell',
              'td': 'table_cell',
            }[base] ??
            base;
        if (SemanticSchema.markOrder.contains(base)) {
          final attrs = _sourceAttrs(t);
          if (open && type.startsWith('bbcode_')) {
            attrs['syntax'] = type.substring(7, type.length - 5);
          }
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
            // 官方 normalizeLinkText 会把非法 UTF-8 换成替代字符，也会
            // 解码空白。编辑文本必须可再次 linkify，不能从有损标签重建 URL。
            if ((t['markup'] == 'linkify' || t['markup'] == 'autolink') &&
                i + 2 < tokens.length &&
                tokens[i + 1]['type'] == 'text' &&
                tokens[i + 2]['type'] == 'link_close') {
              final href = _attr(t, 'href') as String;
              final label = tokens[i + 1]['content'] as String;
              var source = href;
              for (final scheme in ['http://', 'mailto:']) {
                if (href.startsWith(scheme) && !label.startsWith(scheme)) {
                  source = href.substring(scheme.length);
                  break;
                }
              }
              tokens[i + 1]['content'] = displayLinkText(source);
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
          'footnote_block',
          'footnote',
          'table',
          'table_head',
          'table_body',
          'table_row',
          'table_cell',
          'paragraph',
          'heading',
          'blockquote',
          'bullet_list',
          'ordered_list',
          'list_item',
        }.contains(base)) {
          if (!open) {
            if (_top.type != base &&
                !(base == 'paragraph' && _top.type == 'html_block')) {
              throw SemanticCodecUnsupported('token 闭合类型不匹配');
            }
            _close();
            continue;
          }
          final attrs = _sourceAttrs(t);
          if (base == 'footnote') {
            attrs.addAll(Map<String, dynamic>.from(t['meta'] as Map? ?? {}));
          }
          if (base == 'table_cell') attrs['header'] = t['tag'] == 'th';
          if (base == 'heading') {
            attrs['level'] = int.parse((t['tag'] as String).substring(1));
          }
          if (base.endsWith('_list')) {
            var depth = 0;
            var tight = true;
            for (var j = i + 1; j < tokens.length; j++) {
              final kind = tokens[j]['type'];
              if (kind == '${base}_close' && depth == 0) break;
              if (kind == 'paragraph_open' &&
                  depth == 1 &&
                  tokens[j]['hidden'] != true) {
                tight = false;
              }
              if (kind.endsWith('_open')) depth++;
              if (kind.endsWith('_close')) depth--;
            }
            attrs['tight'] = tight;
            if (base == 'ordered_list') {
              attrs['order'] = int.tryParse('${_attr(t, 'start')}') ?? 1;
            }
          }
          _open(base, attrs);
          continue;
        }
      }
      throw SemanticCodecUnsupported('不支持 token $type');
    }
  }

  int? _quoteInteger(Object? value) {
    if (value == null || value is int) return value as int?;
    if (value is String && RegExp(r'^\d+$').hasMatch(value)) {
      return int.parse(value);
    }
    throw SemanticCodecUnsupported('引用数字格式非法');
  }

  bool? _quoteBoolean(Object? value) {
    if (value == null || value is bool) return value as bool?;
    if (value == 'true') return true;
    if (value == 'false') return false;
    throw SemanticCodecUnsupported('引用布尔格式非法');
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
    if (opening == null && closing == null) {
      throw SemanticCodecUnsupported('不支持 HTML inline');
    }
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
      'u': 'underline',
      's': 'strikethrough',
      'strike': 'strikethrough',
    };
    if (marks.containsKey(tag)) {
      _mark(marks[tag]!, isOpen, {'htmlTag': tag});
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
          ...Map<String, dynamic>.from(element!.attributes),
          'href': element.attributes['href'],
          'title': element.attributes['title'],
        });
      } else {
        throw SemanticCodecUnsupported('HTML a 缺少 href');
      }
      return;
    }
    if (tag == 'img') {
      final attrs = Map<String, dynamic>.from(element!.attributes);
      for (final key in ['width', 'height']) {
        if (attrs[key] is String) {
          attrs[key] = num.tryParse(attrs[key]) ?? attrs[key];
        }
      }
      _push(schema.create('image', attrs: attrs, marks: _top.marks));
      return;
    }
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
    if (!allowed.contains(tag)) {
      throw SemanticCodecUnsupported('不支持 HTML tag $tag');
    }
    if (!isOpen) {
      if (_top.type != 'html_inline' || _top.attrs['tag'] != tag) {
        throw SemanticCodecUnsupported('HTML 闭合类型不匹配');
      }
      _close();
      return;
    }
    final htmlAttrs = element == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(element.attributes);
    _open('html_inline', {'tag': tag, 'htmlAttrs': htmlAttrs});
  }
}
