/// 正式语义文档模型：保留未知属性，不执行实验 schema 默认填充或类型转换。
library;

Object? _freeze(Object? value) => value is Map
    ? Map<String, dynamic>.unmodifiable(
        value.map((key, item) => MapEntry(key as String, _freeze(item))),
      )
    : value is List
    ? List<dynamic>.unmodifiable(value.map(_freeze))
    : value;

const _unchanged = Object();

/// 不可变语义标记；属性保持输入的 JSON 类型。
class SemanticMark {
  final String type;
  final Map<String, dynamic> attrs;

  SemanticMark(this.type, [Map<String, dynamic> attrs = const {}])
    : attrs = _freeze(attrs) as Map<String, dynamic>;

  factory SemanticMark.fromJson(Map<String, dynamic> json) => SemanticMark(
    json['type'] as String,
    Map<String, dynamic>.from(json['attrs'] as Map? ?? {}),
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    if (attrs.isNotEmpty) 'attrs': attrs,
  };

  SemanticMark copy({String? type, Map<String, dynamic>? attrs}) =>
      SemanticMark(type ?? this.type, attrs ?? this.attrs);

  SemanticMark copyWith({String? type, Map<String, dynamic>? attrs}) =>
      copy(type: type, attrs: attrs);
}

/// 独立不可变语义树，JSON 契约兼容 PM Node.toJSON。
/// 不丢弃未知节点、属性或标记，也不补充 schema 默认属性。
class SemanticNode {
  final String type;
  final Map<String, dynamic> attrs;
  final List<SemanticNode> content;
  final List<SemanticMark> marks;
  final String? text;

  SemanticNode(
    this.type, {
    Map<String, dynamic> attrs = const {},
    List<SemanticNode> content = const [],
    List<SemanticMark> marks = const [],
    this.text,
  }) : attrs = _freeze(attrs) as Map<String, dynamic>,
       content = List.unmodifiable(content),
       marks = List.unmodifiable(marks);

  factory SemanticNode.fromJson(Map<String, dynamic> json) => SemanticNode(
    json['type'] as String,
    attrs: Map<String, dynamic>.from(json['attrs'] as Map? ?? {}),
    content: (json['content'] as List? ?? [])
        .map(
          (value) =>
              SemanticNode.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList(),
    marks: (json['marks'] as List? ?? [])
        .map(
          (value) =>
              SemanticMark.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList(),
    text: json['text'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    if (attrs.isNotEmpty) 'attrs': attrs,
    if (content.isNotEmpty)
      'content': content.map((node) => node.toJson()).toList(),
    if (marks.isNotEmpty) 'marks': marks.map((mark) => mark.toJson()).toList(),
    if (text != null) 'text': text,
  };

  String get textContent =>
      text ?? content.map((node) => node.textContent).join();

  /// 文本使用 UTF-16 长度；原子节点占一位，容器包含起止边界。
  /// 脚注引用是原子，不沿用实验 schema 将其当作容器的行为。
  int get nodeSize => type == 'text'
      ? (text?.length ?? 0)
      : content.isEmpty && !_containers.contains(type)
      ? 1
      : 2 + content.fold<int>(0, (size, node) => size + node.nodeSize);

  SemanticNode copy({
    String? type,
    Map<String, dynamic>? attrs,
    List<SemanticNode>? content,
    List<SemanticMark>? marks,
    Object? text = _unchanged,
  }) => SemanticNode(
    type ?? this.type,
    attrs: attrs ?? this.attrs,
    content: content ?? this.content,
    marks: marks ?? this.marks,
    text: identical(text, _unchanged) ? this.text : text as String?,
  );

  SemanticNode copyWith({
    String? type,
    Map<String, dynamic>? attrs,
    List<SemanticNode>? content,
    List<SemanticMark>? marks,
    Object? text = _unchanged,
  }) => copy(
    type: type,
    attrs: attrs,
    content: content,
    marks: marks,
    text: text,
  );
}

const _containers = {
  'footnote_block',
  'footnote',
  'table',
  'table_head',
  'table_body',
  'table_row',
  'table_cell',
  'image_grid',
  'spoiler',
  'callout',
  'math_block',
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
};

/// 标记顺序有意义；属性映射的键插入顺序不影响语义相等。
bool sameSemanticMarks(List<SemanticMark> a, List<SemanticMark> b) =>
    identical(a, b) ||
    (a.length == b.length &&
        List.generate(a.length, (index) => index).every(
          (index) =>
              a[index].type == b[index].type &&
              _sameValue(a[index].attrs, b[index].attrs),
        ));

bool _sameValue(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameValue(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (!_sameValue(a[index], b[index])) return false;
    }
    return true;
  }
  return a == b;
}
