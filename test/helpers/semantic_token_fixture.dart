import 'package:fluxdo_render/semantic_editor.dart';

/// 夹具只适配 DTO 外壳；解析及导出全部使用正式语义 codec。
SemanticNode parseSemanticFixture(Map<String, dynamic> dto) {
  if (dto['version'] != 1) {
    throw const SemanticCodecUnsupported('dto_version');
  }
  return const SemanticDocumentCodec().parseTokens(dto['tokens'] as List);
}

String serializeSemanticFixture(SemanticNode document) =>
    const SemanticDocumentCodec().serialize(document);

/// 在首个文本叶子追加文本，保留所有祖先及标记，用于编辑回归。
SemanticNode appendFixtureText(SemanticNode document, String suffix) {
  var changed = false;
  SemanticNode visit(SemanticNode node) {
    if (!changed && node.type == 'text') {
      changed = true;
      return node.copyWith(text: '${node.text}$suffix');
    }
    return node.copyWith(content: node.content.map(visit).toList());
  }

  return visit(document);
}
