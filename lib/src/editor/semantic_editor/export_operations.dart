part of 'semantic_editor.dart';

Never _rejectExport(String message) =>
    throw EditorDocumentRejection(message, code: 'semantic_unsupported');

/// 按原树路径裁剪，容器属性与 summary 保留；临时来源永远不导出。
SemanticNode _exportSemanticTree(
  SemanticEditorProjection p,
  Map<String, SemanticNode>? selected,
) {
  final excluded = p._transients.values
      .map((ids) => _transientPath(p, ids))
      .toSet();
  SemanticNode? visit(SemanticNode node, String path) {
    if (excluded.contains(path)) return null;
    if (selected != null && selected.containsKey(path)) {
      return selected[path];
    }
    final children = <SemanticNode>[];
    for (var i = 0; i < node.content.length; i++) {
      if (selected != null && node.type == 'details' && i == 0) continue;
      final child = visit(node.content[i], '$path/$i');
      if (child != null) children.add(child);
    }
    if (selected != null && children.isEmpty && path.isNotEmpty) return null;
    if (selected != null && node.type == 'details' && children.isNotEmpty) {
      children.insert(0, node.content.first);
    }
    return node.copy(content: children);
  }

  return visit(p.source, '') ?? SemanticNode('doc');
}

void _selectExportBlock(
  SemanticEditorProjection p,
  Map<String, SemanticNode> selected,
  EditorBlock block,
  int start,
  int end,
) {
  final source = p._sources[block.id];
  final path = p._paths[block.id];
  if (source == null || path == null) {
    // 自动补位空段没有语义来源，也没有可导出内容。
    if (block is TextBlock && block.content.length == 0) return;
    _rejectExport('片段缺少稳定语义来源');
  }
  if (block is IslandBlock) {
    if (start < 1 && end > 0) selected[path] = source;
  } else {
    final text = block as TextBlock;
    selected[path] = start == 0 && end == text.content.length
        ? source
        : source.copy(content: _sliceSemanticInline(source, start, end));
  }
}

String _serializeExport(
  SemanticEditorProjection p,
  Map<String, SemanticNode>? selected,
) {
  try {
    return const SemanticDocumentCodec().serialize(
      _exportSemanticTree(p, selected),
    );
  } on SemanticEditorUnsupported catch (error) {
    _rejectExport(error.message);
  }
}

String _exportSemanticSelection(
  SemanticEditorProjection p,
  EditorSelection sel, {
  List<EditorBlock>? liveBlocks,
}) {
  if (sel.isCollapsed) return '';
  var from = sel.base;
  var to = sel.extent;
  var first = p._blocks.indexWhere((b) => b.id == from.blockId);
  var last = p._blocks.indexWhere((b) => b.id == to.blockId);
  if (first < 0 || last < 0) _rejectExport('选区来源不属于当前快照');
  if (first > last || first == last && from.offset > to.offset) {
    (first, last) = (last, first);
    (from, to) = (to, from);
  }
  final selected = <String, SemanticNode>{};
  for (var i = first; i <= last; i++) {
    final block = p._blocks[i];
    final live = liveBlocks?.where((b) => b.id == block.id).firstOrNull ?? block;
    final start = i == first ? from.offset.clamp(0, live.selectionLength) : 0;
    final end = i == last
        ? to.offset.clamp(0, live.selectionLength)
        : live.selectionLength;
    if (live is TextBlock && block is TextBlock && live.content != block.content) {
      final source = p._sources[block.id];
      final path = p._paths[block.id];
      if (source == null || path == null) _rejectExport('选区缺少语义来源');
      EditableTextContent fold(EditableTextContent content) => spinInlineMarks(
        content, caret: -1, guardInclusive: false,
        maxPasses: content.length + 1,
      ).content;
      final prefix = fold(live.content.slice(0, start));
      final piece = fold(live.content.slice(start, end));
      final suffix = fold(live.content.slice(end, live.content.length));
      // 完整定界符的切片可直接定位源树，保留 title 等不可见属性。
      final joined = prefix.concat(piece).concat(suffix);
      final normalized = fold(live.content);
      bool sameUnits(EditableTextContent a, EditableTextContent b) {
        if (a.length != b.length) return false;
        for (var j = 0; j < a.length; j++) {
          if (a.slice(j, j + 1) != b.slice(j, j + 1)) return false;
        }
        return true;
      }
      if (sameUnits(joined, normalized) && sameUnits(normalized, block.content)) {
        selected[path] = source.copy(content: _sliceSemanticInline(
          source, prefix.length, prefix.length + piece.length));
      } else {
        // 半个链接/定界符只复制选中的字面字符，不补出选区外 href。
        selected[path] = source.copy(content: SemanticEditorProjection._rewrite(
          SemanticNode('paragraph'), EditableTextContent.empty, piece,
          allowNewAtoms: true));
      }
    } else {
      _selectExportBlock(p, selected, block, start, end);
    }
  }
  return _serializeExport(p, selected);
}

String _exportSemanticDocument(
  SemanticEditorProjection p,
  List<EditorBlock>? fragment,
) {
  if (fragment == null) return _serializeExport(p, null);
  final selected = <String, SemanticNode>{};
  var previous = -1;
  for (final piece in fragment) {
    final index = p._blocks.indexWhere((b) => b.id == piece.id);
    if (index <= previous) _rejectExport('未知、重复或乱序语义片段');
    previous = index;
    final block = p._blocks[index];
    if (piece == block) {
      _selectExportBlock(p, selected, block, 0, block.selectionLength);
      continue;
    }
    if (piece is! TextBlock ||
        block is! TextBlock ||
        piece.copyWith(content: block.content) != block) {
      _rejectExport('片段结构不属于当前快照');
    }
    int? offset;
    for (var i = 0; i + piece.content.length <= block.content.length; i++) {
      if (block.content.slice(i, i + piece.content.length) != piece.content) {
        continue;
      }
      if (offset != null) _rejectExport('重复文本片段来源歧义，请使用选区导出');
      offset = i;
    }
    if (offset == null) _rejectExport('片段内容不是原文的严格切片');
    _selectExportBlock(
      p,
      selected,
      block,
      offset,
      offset + piece.content.length,
    );
  }
  return _serializeExport(p, selected);
}
