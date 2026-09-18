part of 'semantic_editor.dart';

/// 可选语义媒体 schema：src 必填；其余字段与媒体模型同名。
/// 未知 attrs、缺省字段和原始 HTML 不参与规范化。
bool _validMediaFields(Map<String, dynamic> fields) {
  for (final key in ['src', 'origSrc', 'poster']) {
    final value = fields[key];
    if (value == null && key != 'src') continue;
    if (value is! String || value.trim().isEmpty) return false;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.hasScheme && !{'http', 'https', 'upload'}.contains(uri.scheme))) {
      return false;
    }
  }
  for (final key in ['width', 'height']) {
    final value = fields[key];
    if (value != null && (value is! num || !value.isFinite || value <= 0)) {
      return false;
    }
  }
  return true;
}

BlockNode? _projectMedia(SemanticNode source, String id) {
  if (source.type == 'html_block') {
    if (source.content.any((n) => n.type != 'text' || n.text == null)) {
      return null;
    }
    final media = importRawMediaHtml(source.textContent, id);
    return media != null && _validMediaFields(_mediaFields(media)!)
        ? media
        : null;
  }
  if (!{'video', 'audio'}.contains(source.type) ||
      source.attrs['src'] is! String) {
    return null;
  }
  final a = source.attrs;
  if (!_validMediaFields(a)) return null;
  for (final key in ['origSrc', 'mime', 'poster', 'title']) {
    if (a[key] != null && a[key] is! String) return null;
  }
  for (final key in ['width', 'height']) {
    if (a[key] != null && a[key] is! num) return null;
  }
  for (final key in ['loop', 'voice']) {
    if (a[key] != null && a[key] is! bool) return null;
  }
  return _mediaFromFields(source.type, id, a);
}

BlockNode _mediaFromFields(
  String type,
  String id,
  Map<String, dynamic> a, {
  String? rawHtml,
  String? signature,
}) => type == 'video'
    ? VideoNode(
        id: id,
        src: a['src'] as String,
        origSrc: a['origSrc'] as String?,
        mime: a['mime'] as String?,
        poster: a['poster'] as String?,
        width: (a['width'] as num?)?.toDouble(),
        height: (a['height'] as num?)?.toDouble(),
        loop: a['loop'] == true,
        rawHtml: rawHtml,
        rawHtmlSignature: signature,
      )
    : AudioNode(
        id: id,
        src: a['src'] as String,
        origSrc: a['origSrc'] as String?,
        mime: a['mime'] as String?,
        title: a['title'] as String?,
        voice: a['voice'] == true,
        rawHtml: rawHtml,
        rawHtmlSignature: signature,
      );

Map<String, dynamic>? _mediaFields(BlockNode node) => switch (node) {
  VideoNode() => {
    'src': node.src,
    'origSrc': node.origSrc,
    'mime': node.mime,
    'poster': node.poster,
    'width': node.width,
    'height': node.height,
    'loop': node.loop,
  },
  AudioNode() => {
    'src': node.src,
    'origSrc': node.origSrc,
    'mime': node.mime,
    'title': node.title,
    'voice': node.voice,
  },
  _ => null,
};

SemanticNode? _synchronizeMedia(
  SemanticNode source,
  BlockNode old,
  BlockNode next,
) {
  final before = _mediaFields(old), after = _mediaFields(next);
  if (before == null || after == null || old.runtimeType != next.runtimeType) {
    return null;
  }
  if (mapEquals(before, after)) return source;
  if (!_validMediaFields(after)) {
    throw const SemanticEditorUnsupported('媒体地址或尺寸无效');
  }
  if (source.type != 'html_block') {
    final attrs = {...source.attrs};
    for (final key in after.keys) {
      if (before[key] != after[key]) attrs[key] = after[key];
    }
    return source.copy(attrs: attrs);
  }
  // 以树中的 HTML 为基线；不信任 updateIslandNode 附带的旧 rawHtml。
  final baseline = importRawMediaHtml(source.textContent, old.id);
  if (baseline == null) return null;
  final media = _mediaFromFields(
    old is VideoNode ? 'video' : 'audio',
    old.id,
    after,
    rawHtml: source.textContent,
    signature: mediaHtmlSignature(baseline),
  );
  final html = serializeRawMediaHtml(media);
  // voice 包装不是 html_block 的同型变更，拒绝而非偷偷改变树类型。
  if (html == null) return null;
  final projected = importRawMediaHtml(html, old.id);
  if (projected == null || !mapEquals(_mediaFields(projected), after)) {
    throw const SemanticEditorUnsupported('媒体字段无法在原 HTML 中无损表达');
  }
  if (source.text != null) return source.copy(text: html);
  if (source.content.length == 1) {
    return source.copy(content: [source.content.single.copy(text: html)]);
  }
  // 多段来源无法安全分配 HTML 序列化后的字符，显式拒绝。
  throw const SemanticEditorUnsupported('多段媒体 HTML 的编辑来源不明确');
}
