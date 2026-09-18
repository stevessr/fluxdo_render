/// 正式语义 codec：只支持声明的生产子集，不能回退实验 codec 或扁平块导出。
library;

import 'document.dart';
import 'token_parser.dart';
import 'token_serializer.dart';

class SemanticCodecUnsupported implements Exception {
  const SemanticCodecUnsupported(this.message);
  final String message;
  @override
  String toString() => 'SemanticCodecUnsupported: $message';
}

class SemanticDocumentCodec {
  const SemanticDocumentCodec();
  SemanticNode parseTokens(List<dynamic> tokens) =>
      SemanticTokenParser().parseTokens(tokens);
  String serialize(SemanticNode document) {
    SemanticSchema().check(document);
    if (document.type != 'doc') {
      throw const SemanticCodecUnsupported('根必须是 doc');
    }
    return serializeSemantic(document);
  }
}

/// 不进行 JS 隐式转换，不填充虚构正文；未知 JSON 属性保留在原树。
/// 常用生产扩展使用显式节点；真正未知结构仍明确拒绝。
class SemanticSchema {
  static const markOrder = [
    'em',
    'strong',
    'underline',
    'strikethrough',
    'spoiler',
    'link',
    'code',
  ];
  static const blocks = {
    'footnote_block',
    'table',
    'image_grid',
    'wrap',
    'poll',
    'spoiler',
    'callout',
    'math_block',
    'paragraph',
    'heading',
    'blockquote',
    'quote',
    'details',
    'bullet_list',
    'ordered_list',
    'code_block',
    'html_block',
    'horizontal_rule',
  };
  static const inlines = {
    'math_inline',
    'check',
    'footnote_ref',
    'text',
    'hard_break',
    'html_inline',
    'image',
    'emoji',
    'mention',
    'hashtag',
    'local_date',
  };
  SemanticMark mark(String type, [Map<String, dynamic> attrs = const {}]) {
    final result = SemanticMark(type, attrs);
    _checkMark(result);
    return result;
  }

  SemanticNode create(
    String type, {
    Map<String, dynamic> attrs = const {},
    List<SemanticNode> content = const [],
    List<SemanticMark> marks = const [],
    String? text,
  }) => SemanticNode(
    type,
    attrs: attrs,
    content: content,
    marks: marks,
    text: text,
  );

  void _json(Object? value) {
    if (value == null ||
        value is String ||
        value is bool ||
        value is num && value.isFinite) {
      return;
    }
    if (value is List) {
      for (final item in value) {
        _json(item);
      }
      return;
    }
    if (value is Map && value.keys.every((k) => k is String)) {
      for (final item in value.values) {
        _json(item);
      }
      return;
    }
    throw const SemanticCodecUnsupported('属性必须为有限 JSON 值');
  }

  void _fields(
    Map<String, dynamic> attrs, {
    Set<String> strings = const {},
    Set<String> numbers = const {},
    Set<String> booleans = const {},
  }) {
    _json(attrs);
    for (final e in attrs.entries) {
      if (e.value == null) continue;
      if (strings.contains(e.key) && e.value is! String ||
          numbers.contains(e.key) &&
              (e.value is! num || !(e.value as num).isFinite) ||
          booleans.contains(e.key) && e.value is! bool) {
        throw SemanticCodecUnsupported('属性类型错误 ${e.key}');
      }
    }
  }

  void _required(Map<String, dynamic> attrs, String key) {
    if (attrs[key] is! String || (attrs[key] as String).isEmpty) {
      throw SemanticCodecUnsupported('缺少字符串属性 $key');
    }
  }

  void _checkMark(SemanticMark m) {
    if (!markOrder.contains(m.type)) {
      throw SemanticCodecUnsupported('不支持 mark ${m.type}');
    }
    _fields(
      m.attrs,
      strings: {'href', 'title', 'markup', 'data-orig-href', 'filename'},
      booleans: {'attachment'},
    );
    if (m.attrs['htmlTag'] != null &&
        !{
          'strong',
          'b',
          'em',
          'i',
          'code',
          's',
          'strike',
          'u',
        }.contains(m.attrs['htmlTag'])) {
      throw const SemanticCodecUnsupported('非法 HTML mark 标签');
    }
    if (m.type == 'link') {
      _required(m.attrs, 'href');
      for (final key in ['href', 'data-orig-href']) {
        final value = m.attrs[key];
        if (value is String &&
            (value.contains(RegExp(r'[\x00-\x1f]')) ||
                RegExp(
                  r'^(?:javascript|vbscript|data):',
                  caseSensitive: false,
                ).hasMatch(value.trimLeft()))) {
          throw const SemanticCodecUnsupported('不安全链接 URL');
        }
      }

      if (!{
        null,
        'autolink',
        'linkify',
        '<>',
        'bare',
      }.contains(m.attrs['markup'])) {
        throw const SemanticCodecUnsupported('不支持链接语法');
      }
    }
  }

  void check(SemanticNode n) {
    final a = n.attrs;
    if (n.type == 'doc') {
      final refs = <int, String?>{};
      final definitions = <int, String?>{};
      void collect(SemanticNode node) {
        if ({'footnote_ref', 'footnote'}.contains(node.type)) {
          final id = node.attrs['id'];
          if (id is! int) throw const SemanticCodecUnsupported('脚注 id 非法');
          final target = node.type == 'footnote' ? definitions : refs;
          final label = node.attrs['label'] as String?;
          if (target.containsKey(id) &&
              (node.type == 'footnote' || target[id] != label)) {
            throw const SemanticCodecUnsupported('脚注重复或标签冲突');
          }
          target[id] = label;
        }
        node.content.forEach(collect);
      }

      collect(n);
      if (refs.length != definitions.length ||
          refs.entries.any(
            (e) =>
                !definitions.containsKey(e.key) ||
                definitions[e.key] != e.value,
          )) {
        throw const SemanticCodecUnsupported('脚注引用与定义不匹配');
      }
    }
    if (!{
      'doc',
      'list_item',
      'footnote',
      'summary',
      'table_head',
      'table_body',
      'table_row',
      'table_cell',
      ...blocks,
      ...inlines,
    }.contains(n.type)) {
      throw SemanticCodecUnsupported('不支持 node ${n.type}');
    }
    _json(a);
    for (final key in [
      'src',
      'url',
      'href',
      'data-orig-src',
      'data-orig-href',
      'lightboxUrl',
    ]) {
      final value = a[key];
      if (value == null) continue;
      if (value is! String ||
          value.contains(RegExp(r'[\x00-\x20]')) ||
          RegExp(
            r'^(?:javascript|vbscript|data):',
            caseSensitive: false,
          ).hasMatch(value)) {
        throw SemanticCodecUnsupported('不安全 URL 属性 $key');
      }
    }
    if (n.type == 'text'
        ? n.text == null || n.text!.isEmpty || n.content.isNotEmpty
        : n.text != null) {
      throw const SemanticCodecUnsupported('非法文本结构');
    }
    Set<String> allowed = const {};
    if ({'doc', 'quote', 'blockquote', 'list_item'}.contains(n.type)) {
      allowed = blocks;
    }
    if ({'paragraph', 'heading', 'summary', 'html_inline'}.contains(n.type)) {
      allowed = inlines;
    }
    if ({'code_block', 'html_block'}.contains(n.type)) allowed = {'text'};
    if ({'ordered_list', 'bullet_list'}.contains(n.type)) {
      allowed = {'list_item'};
    }
    if ({'spoiler', 'callout', 'image_grid', 'wrap'}.contains(n.type)) allowed = blocks;
    if (n.type == 'wrap') {
      for (final entry in a.entries.where((e) => e.key.startsWith('data-'))) {
        if (!RegExp(r'^data-[a-zA-Z0-9_-]+$').hasMatch(entry.key) ||
            entry.value is! String ||
            (entry.value as String).contains(RegExp(r'["\r\n\[\]]'))) {
          throw const SemanticCodecUnsupported('非法 wrap 属性');
        }
      }
    }
    if (n.type == 'hashtag') {
      _required(a, 'ref');
      _fields(a, strings: {'ref', 'href'});
      if ((a['ref'] as String).contains(RegExp(r'[\s#]'))) {
        throw const SemanticCodecUnsupported('非法 hashtag 引用');
      }
    }
    if (n.type == 'table') allowed = {'table_head', 'table_body', 'table_row'};
    if ({'table_head', 'table_body'}.contains(n.type)) allowed = {'table_row'};
    if (n.type == 'table_row') allowed = {'table_cell'};
    if (n.type == 'table_cell') allowed = inlines;
    if (n.type == 'math_block') allowed = {'text'};
    if (n.type == 'footnote_block') allowed = {'footnote'};
    if (n.type == 'footnote') allowed = blocks;
    if (n.type == 'math_inline') {
      _fields(a, strings: {'content', 'mathType'});
      if (a['content'] is! String ||
          !{null, 'tex', 'asciimath'}.contains(a['mathType'])) {
        throw const SemanticCodecUnsupported('非法行内数学');
      }
    }
    if (n.type == 'check') _fields(a, booleans: {'checked', 'permanent'});
    if ({'footnote_ref', 'footnote'}.contains(n.type)) {
      if (a['id'] is! int || a['id'] < 0) {
        throw const SemanticCodecUnsupported('脚注 id 非法');
      }
      if (a['label'] != null &&
          (a['label'] is! String ||
              (a['label'] as String).contains(RegExp(r'[\[\]\r\n]')))) {
        throw const SemanticCodecUnsupported('脚注 label 非法');
      }
    }
    if (n.type == 'poll') {
      _required(a, 'rawHtml');
      _fields(a, strings: {'pollName', 'title'});
    }
    if (n.type == 'callout') {
      _fields(a, strings: {'typeRaw', 'title'}, booleans: {'foldable'});
      if (a['typeRaw'] != null &&
          !RegExp(r'^[a-zA-Z]+$').hasMatch(a['typeRaw'] as String)) {
        throw const SemanticCodecUnsupported('callout 类型非法');
      }
      if (a['title'] is String &&
          (a['title'] as String).contains(RegExp(r'[\r\n]'))) {
        throw const SemanticCodecUnsupported('callout 标题包含换行');
      }
    }
    if (n.type == 'summary' &&
        n.content.any((c) => c.type != 'text' || c.marks.isNotEmpty)) {
      throw const SemanticCodecUnsupported('summary 仅支持纯文本');
    }
    if ({'code_block', 'html_block'}.contains(n.type) &&
        n.content.any((c) => c.marks.isNotEmpty)) {
      throw const SemanticCodecUnsupported('代码或 HTML 块不能携带 marks');
    }
    if (n.type == 'details') {
      if (n.content.isEmpty ||
          n.content.first.type != 'summary' ||
          n.content.skip(1).any((c) => !blocks.contains(c.type))) {
        throw const SemanticCodecUnsupported('details 结构错误');
      }
      allowed = {...blocks, 'summary'};
    }
    if (n.content.any((c) => !allowed.contains(c.type))) {
      throw SemanticCodecUnsupported('非法 ${n.type} 子节点');
    }
    if (n.type == 'heading' &&
        (a['level'] is! int || a['level'] < 1 || a['level'] > 6)) {
      throw const SemanticCodecUnsupported('heading level 必须为 1..6 整数');
    }
    if ({'bullet_list', 'ordered_list'}.contains(n.type)) {
      _fields(a, booleans: {'tight'}, strings: {'bullet'});
      if (a['order'] != null && (a['order'] is! int || a['order'] < 1)) {
        throw const SemanticCodecUnsupported('列表起始必须为正整数');
      }
      if (a['bullet'] != null && !{'*', '-', '+'}.contains(a['bullet'])) {
        throw const SemanticCodecUnsupported('非法列表符号');
      }
    }
    if (n.type == 'quote') {
      _fields(a, strings: {'username', 'displayName'}, booleans: {'full'});
      for (final key in ['postNumber', 'topicId']) {
        if (a[key] != null && a[key] is! int) {
          throw SemanticCodecUnsupported('引用 $key 必须为整数');
        }
      }
      for (final key in ['username', 'displayName']) {
        if (a[key] is String &&
            (a[key] as String).contains(RegExp(r'[\r\n"\[\]]'))) {
          throw const SemanticCodecUnsupported('引用属性包含控制语法');
        }
      }
    }
    if (n.type == 'html_inline') {
      if (a['tag'] is! String ||
          !{
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
          }.contains(a['tag'])) {
        throw const SemanticCodecUnsupported('不支持 HTML tag');
      }
      if (a['htmlAttrs'] != null) {
        if (a['htmlAttrs'] is! Map) {
          throw const SemanticCodecUnsupported('HTML attrs 必须为 map');
        }
        for (final e in (a['htmlAttrs'] as Map).entries) {
          if (e.value is! String ||
              !RegExp(r'^[a-zA-Z][a-zA-Z0-9:-]*$').hasMatch(e.key as String) ||
              (e.key as String).toLowerCase().startsWith('on')) {
            throw const SemanticCodecUnsupported('不安全 HTML attrs');
          }
        }
      }
    }
    if (n.type == 'image') {
      _fields(
        a,
        strings: {'src', 'alt', 'title', 'data-orig-src'},
        numbers: {
          'width',
          'height',
          'scale',
          'origWidth',
          'origHeight',
          'naturalWidth',
          'naturalHeight',
        },
      );
      _required(a, 'src');
    }
    if (n.type == 'emoji') {
      _required(a, 'name');
      _required(a, 'url');
    }
    if (n.type == 'mention') {
      _required(a, 'username');
      _required(a, 'href');
    }
    if (n.type == 'local_date') {
      _required(a, 'date');
      _fields(
        a,
        strings: {
          'date',
          'time',
          'timezone',
          'format',
          'endDate',
          'endTime',
          'displayedTimezone',
          'recurring',
          'countdownRaw',
          'fallbackText',
        },
        booleans: {'countdown'},
      );
      if (a['timezones'] != null &&
          (a['timezones'] is! List ||
              (a['timezones'] as List).any((v) => v is! String))) {
        throw const SemanticCodecUnsupported('timezones 必须为字符串数组');
      }
    }
    if (n.type == 'code_block') _fields(a, strings: {'params'});
    if (n.type == 'hard_break') _fields(a, booleans: {'soft'});
    if (n.type == 'details') _fields(a, booleans: {'open'});
    var rank = -1;
    for (final m in n.marks) {
      _checkMark(m);
      final next = markOrder.indexOf(m.type);
      if (next <= rank || !inlines.contains(n.type)) {
        throw const SemanticCodecUnsupported('非法 mark 顺序或位置');
      }
      rank = next;
    }
    for (final child in n.content) {
      check(child);
    }
  }
}
