import 'dart:convert';
import 'package:html/parser.dart' as html_parser;
import '../../node/node.dart';
import '../../parser/paragraph_parser.dart';
import 'island_inline_serializer.dart';

/// 仅解码 poll token 子树；不调用旧整篇编辑器导入器。
PollNode? importSemanticPollTokenNode(List<dynamic> input) {
  try {
    final ts = _tokens(input);
    if (ts.isEmpty ||
        ts.first['type'] != 'poll_open' ||
        ts.last['type'] != 'poll_close') {
      return null;
    }
    final fragment = _pollHtml(ts);
    final root = html_parser.parseFragment(fragment).querySelector('div.poll');
    if (root == null) return null;
    return PollNode(
      id: 'semantic_poll',
      pollName: root.attributes['data-poll-name'] ?? 'poll',
      title: root.querySelector('.poll-title')?.text,
      rawHtml: fragment,
    );
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  } on RangeError {
    return null;
  }
}

List<Map<String, dynamic>> _tokens(dynamic value) {
  if (value == null) return [];
  if (value is! List) throw const FormatException('poll_children');
  return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
}
String _str(Map<String, dynamic> token, String key) =>
    token[key] as String? ?? '';
Map<String, String> _attrs(Map<String, dynamic> token) {
  final value = token['attrs'];
  if (value == null) return {};
  bool scalar(Object? v) => v is String || v is bool || (v is num && v.isFinite);
  if (value is Map) {
    if (value.entries.any((e) => e.key is! String || !scalar(e.value))) {
      throw const FormatException('poll_attributes');
    }
    return value.map((k, v) => MapEntry(k as String, v.toString()));
  }
  if (value is! List) throw const FormatException('poll_attributes');
  final result = <String, String>{};
  for (final pair in value) {
    if (pair is! List || pair.length != 2 || pair[0] is! String || !scalar(pair[1])) {
      throw const FormatException('poll_attributes');
    }
    result[pair[0] as String] = pair[1].toString();
  }
  return result;
}

String _pollHtml(List<Map<String, dynamic>> ts) {
  const tags = {
    'poll': 'div',
    'poll_container': 'div',
    'poll_title': 'div',
    'poll_info': 'div',
    'poll_info_counts': 'div',
    'poll_info_counts_count': 'div',
    'poll_info_number': 'span',
    'poll_info_label': 'span',
    'bullet_list': 'ul',
    'ordered_list': 'ol',
    'list_item': 'li',
    'paragraph': 'p',
    'strong': 'strong',
    'em': 'em',
    's': 's',
    'link': 'a',
    'mention': 'a',
  };
  const escape = HtmlEscape();
  final out = StringBuffer();
  final stack = <String>[];
  for (final token in ts) {
    final type = _str(token, 'type');
    _attrs(token); // 闭合与叶 token 同样验证，不能靠 HTML 查询掩盖畸形输入。
    final children = token['children'];
    if (children != null && children is! List) throw const FormatException('poll_children');
    if (children is List && children.isNotEmpty && type != 'inline' && type != 'image') {
      throw const FormatException('poll_children');
    }
    if ({'inline', 'text', 'softbreak', 'hardbreak', 'code_inline'}.contains(type) && token['nesting'] != 0) {
      throw const FormatException('poll_nesting');
    }
    if (type == 'inline') {
      out.write(_pollHtml(_tokens(token['children'])));
    } else if (type == 'text') {
      out.write(escape.convert(_str(token, 'content')));
    } else if (type == 'softbreak' || type == 'hardbreak') {
      out.write(type == 'softbreak' ? '\n' : '<br>');
    } else if (type == 'code_inline') {
      out.write('<code>${escape.convert(_str(token, 'content'))}</code>');
    } else {
      final base = type.replaceFirst(RegExp(r'_(open|close)$'), '');
      final tag =
          tags[base] ?? ({'emoji', 'image'}.contains(type) ? 'img' : null);
      if (tag == null) throw FormatException('poll_$type');
      if (token['nesting'] == -1) {
        if (!type.endsWith('_close') ||
            stack.isEmpty ||
            stack.removeLast() != base) {
          throw const FormatException('poll_nesting');
        }
        out.write('</$tag>');
      } else {
        if (tag != 'img') {
          if (token['nesting'] != 1 || !type.endsWith('_open')) {
            throw const FormatException('poll_nesting');
          }
          stack.add(base);
        } else if (token['nesting'] != 0) {
          throw const FormatException('poll_nesting');
        }
        out.write('<$tag');
        final a = _attrs(token);
        if (type == 'image') a['alt'] = _str(token, 'content');
        for (final entry in a.entries) {
          if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(entry.key) ||
              !(entry.key.startsWith('data-') ||
                  {
                    'class',
                    'href',
                    'src',
                    'alt',
                    'title',
                    'start',
                    'rel',
                    'target',
                    'width',
                    'height',
                  }.contains(entry.key))) {
            throw const FormatException('poll_attributes');
          }
          out.write(' ${entry.key}="${escape.convert(entry.value)}"');
        }
        out.write('>');
      }
    }
  }
  if (stack.isNotEmpty) throw const FormatException('poll_nesting');
  return out.toString();
}

/// `[poll ...]` BBCode 从 [PollNode.rawHtml](cooked div.poll)重建。
///
/// 属性形态经 cook 探针实测(见 tools/discourse-cook-bundle):
/// - cooked 属性名恒小写:`chartType=pie` cook 后是 data-poll-charttype;
///   BBCode 属性键大小写不敏感(`charttype=` 与 `chartType=` cook 等价),
///   这里写回官方 builder 形态 `chartType=`。
/// - `status=open` 是 cook 默认值(不写也产 data-poll-status="open"),
///   为最小化 raw 仅在非 open 时写回。
/// - name="poll" 是默认值,同样仅非默认时写回。
/// - number 型:选项 li 由 min/max/step 派生,**不写选项行**(写了 cook
///   会报错);标题行照写。
/// - 属性顺序无关等价(cooked 输出按字母序重排),这里按官方
///   poll-ui-builder 的输出顺序写,便于人读。
///
/// rawHtml 为空(手工构造节点)→ 返回空串,与 独立编辑器的可序列化门禁
/// 同口径,导入门禁拦整帖。
String serializePollNode(PollNode node) {
  if (node.rawMarkdown != null &&
      node.rawMarkdownSignature == node.sourceSignature) {
    return node.rawMarkdown!;
  }
  if (node.rawHtml.isEmpty) return '';
  final root = html_parser
      .parseFragment(node.rawHtml)
      .querySelector('div.poll');
  if (root == null) return '';
  final attrs = root.attributes;
  String? attr(String key) {
    final v = attrs[key]?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  final type = attr('data-poll-type');
  final isNumber = type == 'number';

  // 属性串:对齐官方 poll-ui-builder 的输出顺序(name/type/results/
  // min/max/step/public/chartType/groups/close/status)。值不含空格时
  // 裸写(与官方一致),含空格加引号(cook 两种形态等价)。
  String fmt(String key, String value) =>
      value.contains(' ') ? ' $key="$value"' : ' $key=$value';

  final sb = StringBuffer('[poll');
  final name = node.pollName;
  if (name != 'poll') sb.write(fmt('name', name));
  if (type != null) sb.write(fmt('type', type));
  final results = attr('data-poll-results');
  if (results != null) sb.write(fmt('results', results));
  final min = attr('data-poll-min');
  if (min != null) sb.write(fmt('min', min));
  final max = attr('data-poll-max');
  if (max != null) sb.write(fmt('max', max));
  final step = attr('data-poll-step');
  if (step != null) sb.write(fmt('step', step));
  final public = attr('data-poll-public');
  if (public != null) sb.write(fmt('public', public));
  final chartType = attr('data-poll-charttype');
  if (chartType != null) sb.write(fmt('chartType', chartType));
  final groups = attr('data-poll-groups');
  if (groups != null) sb.write(fmt('groups', groups));
  for (final key in ['dynamic', 'order']) {
    final value = attr('data-poll-$key');
    if (value != null) sb.write(fmt(key, value));
  }
  final close = attr('data-poll-close');
  if (close != null) sb.write(fmt('close', close));
  final status = attr('data-poll-status');
  if (status != null && status != 'open') sb.write(fmt('status', status));
  sb.write(']');

  // 标题行:.poll-title 内是富文本 HTML(粗体/emoji/链接),走
  // parse + 岛 inline 序列化还原 markdown(纯 text 取文本会丢格式;
  // typographer 弯引号等原样保留 —— cook 幂等,再 cook 不二次转换)。
  final titleEl = root.querySelector('.poll-title');
  if (titleEl != null) {
    final title = _pollInnerMarkdown(titleEl.innerHtml);
    if (title.isNotEmpty) sb.write('\n# $title');
  }

  // 选项行:number 型的 li 是 min/max/step 派生物,不写回。
  if (!isNumber) {
    for (final li in root.querySelectorAll('li[data-poll-option-id]')) {
      final opt = _pollInnerMarkdown(li.innerHtml);
      if (opt.isNotEmpty) {
        // 选项内换行(cooked <br>)写回缩进续行,与 cook 输出等价
        sb.write('\n* ${opt.replaceAll('\n', '\n  ')}');
      }
    }
  }

  sb.write('\n[/poll]');
  return sb.toString();
}

/// poll 标题/选项的 inner HTML → 行内 markdown。
///
/// 包一层 `<p>` 走 [ParagraphParser.parse] 复用完整 inline 解析链
/// (emoji/链接/mention/粗斜体…),再用岛 inline 序列化器写回。多段
/// (含 <br> 的选项)由 LineBreakRun 序列化为 `  \n`,调用方再转续行缩进。
String _pollInnerMarkdown(String innerHtml) {
  final nodes = ParagraphParser().parse('<p>$innerHtml</p>');
  final buf = StringBuffer();
  for (final n in nodes) {
    if (n is ParagraphNode) {
      buf.write(serializeIslandInlines(n.inlines));
    }
  }
  // LineBreakRun 的两空格硬换行对 poll 选项无意义,规整成裸换行
  return buf.toString().replaceAll('  \n', '\n').trim();
}
