import 'dart:convert';

/// 验证专用异常：不回退到生产转换器。
class ProbeUnsupported implements Exception {
  final String message;
  ProbeUnsupported(this.message);
  @override
  String toString() => 'ProbeUnsupported: $message';
}

Object? _freeze(Object? value) => value is Map
    ? Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k as String, _freeze(v))),
      )
    : value is List
    ? List<dynamic>.unmodifiable(value.map(_freeze))
    : value;

class ProbeMark {
  final String type;
  final Map<String, dynamic> attrs;
  ProbeMark(this.type, [Map<String, dynamic> attrs = const {}])
    : attrs = _freeze(attrs) as Map<String, dynamic>;
  factory ProbeMark.fromJson(Map<String, dynamic> json) => ProbeMark(
    json['type'] as String,
    Map<String, dynamic>.from(json['attrs'] as Map? ?? {}),
  );
  Map<String, dynamic> toJson() => {
    'type': type,
    if (attrs.isNotEmpty) 'attrs': attrs,
  };
}

/// 独立不可变树；JSON 形状与 PM Node.toJSON 对齐，不依赖生产文档模型。
class ProbeNode {
  final String type;
  final Map<String, dynamic> attrs;
  final List<ProbeNode> content;
  final List<ProbeMark> marks;
  final String? text;
  ProbeNode(
    this.type, {
    Map<String, dynamic> attrs = const {},
    List<ProbeNode> content = const [],
    List<ProbeMark> marks = const [],
    this.text,
  }) : attrs = _freeze(attrs) as Map<String, dynamic>,
       content = List.unmodifiable(content),
       marks = List.unmodifiable(marks);

  /// 无损读取完整 PM JSON；不隐式填默认值。需默认化时使用 schema.fromJson。
  factory ProbeNode.fromJson(Map<String, dynamic> json) => ProbeNode(
    json['type'] as String,
    attrs: Map<String, dynamic>.from(json['attrs'] as Map? ?? {}),
    content: (json['content'] as List? ?? [])
        .map((v) => ProbeNode.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
    marks: (json['marks'] as List? ?? [])
        .map((v) => ProbeMark.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
    text: json['text'] as String?,
  );
  Map<String, dynamic> toJson() => {
    'type': type,
    if (attrs.isNotEmpty) 'attrs': attrs,
    if (content.isNotEmpty) 'content': content.map((n) => n.toJson()).toList(),
    if (marks.isNotEmpty) 'marks': marks.map((m) => m.toJson()).toList(),
    if (text != null) 'text': text,
  };
  String get textContent => text ?? content.map((n) => n.textContent).join();
  int get nodeSize => type == 'text'
      ? text!.length
      : content.isEmpty && !ProbeSchema.containers.contains(type)
      ? 1
      : 2 + content.fold<int>(0, (a, b) => a + b.nodeSize);
  ProbeNode copy({
    Map<String, dynamic>? attrs,
    List<ProbeNode>? content,
    String? text,
  }) => ProbeNode(
    type,
    attrs: attrs ?? this.attrs,
    content: content ?? this.content,
    marks: marks,
    text: text ?? this.text,
  );
}

bool sameMarks(List<ProbeMark> a, List<ProbeMark> b) =>
    jsonEncode(a.map((m) => m.toJson()).toList()) ==
    jsonEncode(b.map((m) => m.toJson()).toList());

/// 来自默认 Markdown schema 与选定扩展；不是完整 ContentMatch 实现。
class ProbeSchema {
  static const markOrder = ['em', 'strong', 'link', 'code'];
  static const blocks = {
    'paragraph',
    'blockquote',
    'quote',
    'heading',
    'code_block',
    'html_block',
    'ordered_list',
    'bullet_list',
    'horizontal_rule',
    'details',
  };
  static const inlines = {'text', 'hard_break', 'html_inline', 'footnote'};
  static const containers = {
    'doc',
    'paragraph',
    'blockquote',
    'quote',
    'heading',
    'code_block',
    'html_block',
    'ordered_list',
    'bullet_list',
    'list_item',
    'details',
    'summary',
    'html_inline',
    'footnote',
  };
  static const defaults = <String, Map<String, dynamic>>{
    'heading': {'level': 1},
    'code_block': {'params': ''},
    'html_block': {'params': 'html'},
    'ordered_list': {'order': 1, 'tight': true},
    'bullet_list': {'tight': true},
    'quote': {
      'username': null,
      'displayName': null,
      'postNumber': null,
      'topicId': null,
      'full': null,
    },
    'details': {'open': true},
    'html_inline': {'htmlAttrs': null},
    'footnote': {'id': null},
  };

  /// 默认属性归一化并校验受限 schema；已有未知属性有意保留。
  ProbeNode fromJson(Map<String, dynamic> json) {
    final input = ProbeNode.fromJson(json);
    ProbeNode normalize(ProbeNode n) => create(
      n.type,
      attrs: n.attrs,
      content: n.content.map(normalize).toList(),
      marks: n.marks.map((m) => mark(m.type, m.attrs)).toList(),
      text: n.text,
    );
    return normalize(input);
  }

  static Set<String> declaredAttrs(String type) => {
    ...?defaults[type]?.keys,
    if (type == 'html_inline') 'tag',
  };

  ProbeMark mark(String type, [Map<String, dynamic> attrs = const {}]) {
    if (!markOrder.contains(type)) throw ProbeUnsupported('不支持 mark $type');
    if (type == 'link' && !attrs.containsKey('href')) {
      throw ProbeUnsupported('link 缺少 href');
    }
    return ProbeMark(type, {
      if (type == 'link') ...{
        'title': null,
        'markup': null,
        'attachment': false,
        'data-orig-href': null,
      },
      ...attrs,
    });
  }

  ProbeNode create(
    String type, {
    Map<String, dynamic> attrs = const {},
    List<ProbeNode> content = const [],
    List<ProbeMark> marks = const [],
    String? text,
    bool fill = false,
  }) {
    var children = [...content];
    if (fill) {
      if ({'doc', 'blockquote', 'quote', 'list_item'}.contains(type) &&
          children.isEmpty) {
        children.add(ProbeNode('paragraph'));
      }
      if ({'bullet_list', 'ordered_list'}.contains(type) && children.isEmpty) {
        children.add(create('list_item', fill: true));
      }
      if (type == 'details') {
        if (children.isEmpty || children.first.type != 'summary') {
          children.insert(0, ProbeNode('summary'));
        }
        if (children.length == 1) children.add(ProbeNode('paragraph'));
      }
    }
    final node = ProbeNode(
      type,
      attrs: {...?defaults[type], ...attrs},
      content: children,
      marks: marks,
      text: text,
    );
    check(node);
    return node;
  }

  void check(ProbeNode n) {
    if (!containers.contains(n.type) &&
        !{'text', 'hard_break', 'horizontal_rule'}.contains(n.type)) {
      throw ProbeUnsupported('不支持 node ${n.type}');
    }
    if (n.type == 'text' &&
        (n.text == null || n.text!.isEmpty || n.content.isNotEmpty)) {
      throw ProbeUnsupported('空或非法 text');
    }
    if (n.type != 'text' && n.text != null) {
      throw ProbeUnsupported('非 text 携带 text');
    }
    bool valid = true;
    if ({
      'doc',
      'blockquote',
      'quote',
      'list_item',
      'footnote',
    }.contains(n.type)) {
      valid =
          (n.type == 'footnote' || n.content.isNotEmpty) &&
          n.content.every((c) => blocks.contains(c.type));
    }
    if ({'paragraph', 'summary', 'html_inline'}.contains(n.type)) {
      valid = n.content.every((c) => inlines.contains(c.type));
    }
    if (n.type == 'heading') valid = n.content.every((c) => c.type == 'text');
    if ({'code_block', 'html_block'}.contains(n.type)) {
      valid = n.content.every((c) => c.type == 'text' && c.marks.isEmpty);
    }
    if ({'ordered_list', 'bullet_list'}.contains(n.type)) {
      valid =
          n.content.isNotEmpty && n.content.every((c) => c.type == 'list_item');
    }
    if (n.type == 'details') {
      valid =
          n.content.length >= 2 &&
          n.content.first.type == 'summary' &&
          n.content.skip(1).every((c) => blocks.contains(c.type));
    }
    if ({'hard_break', 'horizontal_rule'}.contains(n.type)) {
      valid = n.content.isEmpty;
    }
    // 官方 NodeSpec 只要求 tag 存在，不验证类型；序列化按 JS 转换规则处理。
    if (n.type == 'html_inline' && !n.attrs.containsKey('tag')) valid = false;
    if (!valid) throw ProbeUnsupported('非法 ${n.type} content/attrs');
    var rank = -1;
    for (final m in n.marks) {
      final next = markOrder.indexOf(m.type);
      if (next <= rank || next < 0) throw ProbeUnsupported('非法 mark 顺序/类型');
      rank = next;
      if (m.type == 'link' && !m.attrs.containsKey('href')) {
        throw ProbeUnsupported('link 缺少 href');
      }
    }
    for (final child in n.content) {
      check(child);
    }
  }
}

/// UTF-16 范围与 JS 一致；仅复制编辑路径，兄弟节点保持对象身份。
ProbeNode applyProbeEdit(ProbeNode doc, Map<String, dynamic> edit) {
  final path = (edit['path'] as List).cast<int>();
  ProbeNode visit(ProbeNode node, int depth) {
    if (depth < path.length) {
      final index = path[depth];
      if (index < 0 || index >= node.content.length) {
        throw ProbeUnsupported('无效编辑 path');
      }
      final children = [...node.content];
      children[index] = visit(children[index], depth + 1);
      return node.copy(content: children);
    }
    if (edit['op'] == 'insertText') {
      final text = edit['text'];
      if (node.type != 'paragraph' || node.content.isNotEmpty ||
          text is! String || text.isEmpty) {
        throw ProbeUnsupported('insertText 仅支持空段落');
      }
      return node.copy(content: [ProbeNode('text', text: text)]);
    }
    if (edit['op'] == 'setAttrs') {
      final patch = Map<String, dynamic>.from(edit['attrs'] as Map);
      if (patch.keys.any(
        (key) => !ProbeSchema.declaredAttrs(node.type).contains(key),
      )) {
        throw ProbeUnsupported('不能 patch 未声明节点属性');
      }
      return node.copy(attrs: {...node.attrs, ...patch});
    }
    if (edit['op'] != 'replaceText' || node.type != 'text') {
      throw ProbeUnsupported('无效编辑操作');
    }
    final from = edit['from'] as int, to = edit['to'] as int;
    if (from < 0 || to < from || to > node.text!.length) {
      throw ProbeUnsupported('无效 UTF-16 范围');
    }
    return node.copy(
      text: node.text!.replaceRange(from, to, edit['text'] as String),
    );
  }

  final result = visit(doc, 0);
  ProbeSchema().check(result);
  return result;
}
