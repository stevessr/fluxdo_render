/// 原始媒体 HTML 仅做 token 局部解析，不参与阅读端 cook。
library;

import 'dart:convert';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import '../../node/node.dart';

String mediaHtmlSignature(BlockNode node) => jsonEncode(switch (node) {
  VideoNode() => [
    node.src,
    node.origSrc,
    node.mime,
    node.poster,
    node.width,
    node.height,
    node.loop,
  ],
  AudioNode() => [node.src, node.origSrc, node.mime, node.title, node.voice],
  _ => throw ArgumentError('仅支持媒体节点'),
});

/// 只接受一个显式闭合的媒体根。尾随文本、外壳或畸形结构由调用方保源。
BlockNode? importRawMediaHtml(String source, String id) {
  final opening = RegExp(
    r'^\s*<(video|audio)(?=[\s>])',
    caseSensitive: false,
  ).firstMatch(source);
  if (opening == null) return null;
  final tag = opening[1]!.toLowerCase();
  if (!RegExp('</$tag\\s*>\\s*\$', caseSensitive: false).hasMatch(source)) {
    return null;
  }
  final fragment = html.parseFragment(source);
  final meaningful = fragment.nodes
      .where((n) => n is! dom.Text || n.text.trim().isNotEmpty)
      .toList();
  if (meaningful.length != 1 || meaningful.single is! dom.Element) return null;
  final root = meaningful.single as dom.Element;
  if (root.localName != tag || root.querySelector('video,audio') != null) {
    return null;
  }
  // 脚本、嵌套容器等不投影为播放器，避免 DOM 修复后误吞结构。
  if (root
      .querySelectorAll('*')
      .any((e) => !{'source', 'track', 'a'}.contains(e.localName))) {
    return null;
  }
  final sources = root.children.where((e) => e.localName == 'source');
  final primary = root.attributes.containsKey('src')
      ? root
      : sources.where((e) => e.attributes.containsKey('src')).firstOrNull;
  if (primary == null) return null;
  final src = primary.attributes['src']!;
  final uri = Uri.tryParse(src.trim());
  if (src.trim().isEmpty ||
      uri == null ||
      (uri.hasScheme && !{'http', 'https', 'upload'}.contains(uri.scheme))) {
    return null;
  }
  final orig = primary.attributes['data-orig-src'];
  final mime = primary.attributes['type'];
  if (tag == 'video') {
    final node = VideoNode(
      id: id,
      src: src,
      origSrc: orig,
      mime: mime,
      poster: root.attributes['poster'],
      width: double.tryParse(root.attributes['width'] ?? ''),
      height: double.tryParse(root.attributes['height'] ?? ''),
      loop: root.attributes.containsKey('loop'),
    );
    return VideoNode(
      id: id,
      src: src,
      origSrc: orig,
      mime: mime,
      poster: node.poster,
      width: node.width,
      height: node.height,
      loop: node.loop,
      rawHtml: source,
      rawHtmlSignature: mediaHtmlSignature(node),
    );
  }
  final title = root.querySelector('a')?.text;
  final node = AudioNode(
    id: id,
    src: src,
    origSrc: orig,
    mime: mime,
    title: title,
  );
  return AudioNode(
    id: id,
    src: src,
    origSrc: orig,
    mime: mime,
    title: title,
    rawHtml: source,
    rawHtmlSignature: mediaHtmlSignature(node),
  );
}

/// 未改动逐字保源；编辑后仅修改模型覆盖的属性，保留 controls/source/track 等。
String? serializeRawMediaHtml(BlockNode node) {
  final (raw, signature) = switch (node) {
    VideoNode() => (node.rawHtml, node.rawHtmlSignature),
    AudioNode() => (node.rawHtml, node.rawHtmlSignature),
    _ => (null, null),
  };
  if (raw == null) return null;
  if (signature == mediaHtmlSignature(node)) return raw;
  final original = importRawMediaHtml(raw, node.id);
  if (original == null) return null;
  final root = html.parseFragment(raw).children.single;
  final primary = root.attributes.containsKey('src')
      ? root
      : root.children.firstWhere(
          (e) => e.localName == 'source' && e.attributes.containsKey('src'),
        );
  void attr(dom.Element e, String key, Object? value) {
    if (value == null) {
      e.attributes.remove(key);
    } else {
      e.attributes[key] = value.toString();
    }
  }

  void source(String src, String? orig, String? mime, String oldSrc) {
    attr(primary, 'src', src);
    attr(primary, 'data-orig-src', src != oldSrc ? null : orig);
    attr(primary, 'type', mime);
    if (src != oldSrc) {
      // 替换媒体时旧备选源/下载链接不能继续指向被替换的文件。
      for (final e in root.querySelectorAll('source')) {
        if (!identical(e, primary)) e.remove();
      }
      for (final e in root.querySelectorAll('a')) {
        if (e.attributes['href'] == oldSrc) attr(e, 'href', src);
        if (e.text == oldSrc) e.text = src;
      }
    }
  }

  if (node is VideoNode && original is VideoNode) {
    source(node.src, node.origSrc, node.mime, original.src);
    if (node.poster != original.poster) attr(root, 'poster', node.poster);
    if (node.width != original.width) attr(root, 'width', node.width);
    if (node.height != original.height) attr(root, 'height', node.height);
    if (node.loop != original.loop) attr(root, 'loop', node.loop ? '' : null);
  } else if (node is AudioNode && original is AudioNode) {
    source(node.src, node.origSrc, node.mime, original.src);
    if (node.title != original.title) {
      final link = root.querySelector('a');
      if (link != null) link.text = node.title ?? '';
    }
    if (node.voice) return '[wrap=voice]\n${root.outerHtml}\n[/wrap]';
  }
  return root.outerHtml;
}
