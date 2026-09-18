part of 'semantic_editor.dart';

/// 仅按稳定 id 和可证明的连续文本归属改写，不经 Markdown 重建。
SemanticNode _synchronizeStructure(
  SemanticEditorProjection p,
  List<EditorBlock> current,
) {
  Never reject(String message) => throw SemanticEditorUnsupported(message);
  if (current.map((b) => b.id).toSet().length != current.length) {
    reject('重复块 id 无法建立唯一来源');
  }
  final old = {for (final b in p._blocks) b.id: b};
  final replacements = <String, List<SemanticNode>>{};
  final consumed = <String>{};
  final order = <String>[];
  String parent(String path) => path.substring(0, path.lastIndexOf('/'));
  bool simple(TextBlock b) => !b.isListItem && b.depth == 0;
  bool compatible(TextBlock a, TextBlock b) =>
      a.kind == b.kind &&
      a.headingLevel == b.headingLevel &&
      a.ordered == b.ordered &&
      a.listStart == b.listStart &&
      a.listLoose == b.listLoose &&
      a.depth == b.depth &&
      listEquals(a.containers, b.containers);

  for (var i = 0; i < current.length; i++) {
    final next = current[i];
    final before = old[next.id];
    final path = p._paths[next.id];
    if (before == null || path == null || consumed.contains(next.id)) {
      reject('新增块缺少明确的邻接来源，或来源重复使用');
    }
    order.add(path);
    consumed.add(next.id);
    if (before is! TextBlock || next is! TextBlock) {
      if (before != next) reject('不透明节点不能修改');
      replacements[path] = [p._sources[next.id]!];
      continue;
    }
    final node = p._sources[next.id]!;
    final parts = <TextBlock>[next];
    while (i + 1 < current.length && !old.containsKey(current[i + 1].id)) {
      final added = current[++i];
      if (added is! TextBlock) reject('新增不透明节点尚不支持');
      parts.add(added);
    }
    if (parts.length > 1) {
      if (!simple(before) || (parent(path).isNotEmpty && !before.isParagraph)) {
        reject('列表或容器内标题分裂尚不支持');
      }
      var splitOffset = 0;
      for (var k = 0; k < parts.length; k++) {
        final part = parts[k];
        final headingTail =
            before.isHeading &&
            k == parts.length - 1 &&
            part.isParagraph &&
            part.content.length == 0 &&
            listEquals(part.containers, before.containers) &&
            part ==
                TextBlock(
                  id: part.id,
                  content: part.content,
                  containers: before.containers,
                );
        if (!compatible(before, part) && !headingTail) {
          reject('分裂不能改变列表或容器归属');
        }
        final end = splitOffset + part.content.length;
        if (end > before.content.length) reject('分裂文本超出原来源');
        // concat 只排序、不合并 MarkSpan；跨链接分裂会把一个 span 变成
        // 两个相邻 span，不能以拼接后的列表相等判断语义。逐段投影原树
        // 切片，仍精确校验全部 marks（含 href/isAutoLink），不只比较文本。
        final expected = SemanticEditorProjection._inline(
          node.copy(content: _sliceSemanticInline(node, splitOffset, end)),
        );
        if (part.content != expected) reject('分裂文本或 marks 与原来源不一致');
        splitOffset = end;
      }
      if (splitOffset != before.content.length) reject('分裂未覆盖完整原来源');
      var offset = 0;
      replacements[path] = [
        for (final part in parts)
          () {
            final start = offset;
            offset += part.content.length;
            final attrs = {...node.attrs};
            if (part.isParagraph && before.isHeading) attrs.remove('level');
            return SemanticNode(
              part.isHeading ? 'heading' : 'paragraph',
              attrs: attrs,
              marks: node.marks,
              content: _sliceSemanticInline(node, start, offset),
            );
          }(),
      ];
      continue;
    }
    if (!compatible(before, next)) reject('结构编辑不能同时改变块属性');
    // 只有完整相邻来源的精确拼接才作为 merge；不能猜测未知 attrs。
    var joined = before.content;
    final merged = <SemanticNode>[node];
    var oldIndex = p._blocks.indexOf(before) + 1;
    while (joined != next.content && oldIndex < p._blocks.length) {
      final candidate = p._blocks[oldIndex++];
      if (current.any((b) => b.id == candidate.id) ||
          candidate is! TextBlock ||
          parent(p._paths[candidate.id]!) != parent(path)) {
        break;
      }
      if (!simple(before) || parent(path).isNotEmpty || !simple(candidate)) {
        reject('列表及跨容器合并尚不支持');
      }
      final other = p._sources[candidate.id]!;
      final a = {...node.attrs};
      final b = {...other.attrs};
      if (node.type == 'heading') a.remove('level');
      if (other.type == 'heading') b.remove('level');
      if (!mapEquals(a, b) || !sameSemanticMarks(node.marks, other.marks)) {
        reject('合并的块未知 attrs 或 marks 归属有歧义');
      }
      joined = joined.concat(candidate.content);
      merged.add(other);
      consumed.add(candidate.id);
    }
    if (merged.length > 1) {
      if (joined != next.content) reject('合并必须是完整相邻文本的精确拼接');
      replacements[path] = [
        node.copy(content: [for (final n in merged) ...n.content]),
      ];
    } else {
      replacements[path] = [
        before == next
            ? node
            : node.copy(
                content: SemanticEditorProjection._rewrite(
                  node,
                  before.content,
                  next.content,
                ),
              ),
      ];
    }
  }
  // 容器内部仅允许同父简单段落分裂，不能删除、重排或迁出。
  final nestedOld = p._blocks
      .where((b) => parent(p._paths[b.id] ?? '/').isNotEmpty)
      .map((b) => p._paths[b.id])
      .toList();
  final nestedNext = order.where((path) => parent(path).isNotEmpty).toList();
  if (!listEquals(nestedOld, nestedNext)) reject('容器内删除、重排或跨容器操作尚不支持');
  for (final b in p._blocks) {
    if (!consumed.contains(b.id)) {
      if (b is! TextBlock || !simple(b)) {
        reject('不能删除不透明节点或列表节点');
      }
      final deleted = p._sources[b.id]!;
      // 空尾段的 merge 与显式 delete 在块快照中不可区分。不能把未被
      // merge 校验消费的带属性空段当成普通删除，否则其未知属性会消失。
      if (b.content.length == 0 &&
          (deleted.attrs.isNotEmpty ||
              deleted.marks.isNotEmpty ||
              deleted.content.isNotEmpty)) {
        reject('带属性空段删除或合并的来源归属不明确');
      }
    }
  }
  // 非文本根子节点是边界锚点，不允许文本跨越它们移动。
  int region(String path) {
    final index = int.parse(path.split('/')[1]);
    final preceding = p.source.content
        .take(index)
        .where((n) => !{'paragraph', 'heading'}.contains(n.type))
        .length;
    return preceding * 2 +
        ({'paragraph', 'heading'}.contains(p.source.content[index].type)
            ? 0
            : 1);
  }

  var previousRegion = -1;
  for (final path in order) {
    final r = region(path);
    if (r < previousRegion) reject('不能跨不透明节点或容器重排');
    previousRegion = r;
  }
  SemanticNode visit(SemanticNode n, String path) {
    final children = <SemanticNode>[];
    for (var i = 0; i < n.content.length; i++) {
      final childPath = '$path/$i';
      if (replacements.containsKey(childPath)) {
        children.addAll(replacements[childPath]!);
      } else if (!p._paths.values.contains(childPath)) {
        children.add(visit(n.content[i], childPath));
      }
    }
    return listEquals(children, n.content) ? n : n.copy(content: children);
  }

  final rootChildren = <SemanticNode>[];
  final emitted = <String>{};
  for (final path in order) {
    final rootPath = '/${path.split('/')[1]}';
    if (!emitted.add(rootPath)) continue;
    final n = p.source.content[int.parse(rootPath.substring(1))];
    if (path == rootPath) {
      rootChildren.addAll(replacements[path]!);
    } else {
      rootChildren.add(visit(n, rootPath));
    }
  }
  return listEquals(rootChildren, p.source.content)
      ? p.source
      : p.source.copy(content: rootChildren);
}

/// 精确切片保留原始 text attrs、marks；未切开的节点保留对象身份。
List<SemanticNode> _sliceSemanticInline(SemanticNode node, int start, int end) {
  final result = <SemanticNode>[];
  var offset = 0;
  for (final child in node.content) {
    final atom = _semanticInlineAtom(child);
    if (atom == null && !_semanticInlineBreak(child) && child.text == null) {
      throw const SemanticEditorUnsupported('无法切分未知行内节点');
    }
    final length = _semanticInlineLength(child);
    final left = start > offset ? start - offset : 0;
    final right = end < offset + length ? end - offset : length;
    if (left < right) {
      result.add(
        left == 0 && right == length
            ? child
            : child.copy(text: child.text!.substring(left, right)),
      );
    }
    offset += length;
  }
  return result;
}
