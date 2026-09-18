part of 'semantic_editor.dart';

/// 显式操作只认整根节点边界；不猜测容器拆分或跨节点文本拼接。
int _rootBoundary(SemanticEditorProjection p, int boundary) {
  if (boundary < 0 || boundary > p._blocks.length) {
    throw RangeError.range(boundary, 0, p._blocks.length, 'boundary');
  }
  final paths = p._blocks.map((b) => p._paths[b.id]).toList();
  int root(String path) => int.parse(path.split('/')[1]);
  if (boundary == 0) return 0;
  if (boundary == paths.length || paths[boundary] == null) {
    return p.source.content.length;
  }
  final right = root(paths[boundary]!);
  if (paths[boundary - 1] != null && root(paths[boundary - 1]!) == right) {
    throw const SemanticEditorUnsupported('片段操作仅支持整根节点边界，不支持容器内拆分或跨节点文本拼接');
  }
  return right;
}

EditorBlock _fragmentBlockId(
  EditorBlock block,
  String id,
  List<ContainerFrame>? frames,
) => switch (block) {
  TextBlock b => TextBlock(
    id: id,
    content: b.content,
    kind: b.kind,
    headingLevel: b.headingLevel,
    ordered: b.ordered,
    depth: b.depth,
    listStart: b.listStart,
    listLoose: b.listLoose,
    containers: frames ?? b.containers,
  ),
  IslandBlock b => IslandBlock(id: id, node: b.node),
};

ContainerFrame _fragmentFrameId(ContainerFrame frame, String id) =>
    switch (frame) {
      QuoteFrame() => QuoteFrame(groupId: id),
      QuoteCardFrame f => QuoteCardFrame(
        groupId: id,
        username: f.username,
        displayName: f.displayName,
        postNumber: f.postNumber,
        topicId: f.topicId,
        full: f.full,
      ),
      DetailsFrame f => DetailsFrame(
        groupId: id,
        summary: f.summary,
        open: f.open,
      ),
      SpoilerFrame() => SpoilerFrame(groupId: id),
      CalloutFrame f => CalloutFrame(
        groupId: id,
        kind: f.kind,
        typeRaw: f.typeRaw,
        title: f.title,
        foldable: f.foldable,
      ),
    };

int _fragmentId = 0;

/// 由明确的节点替换范围产生来源映射，而不是从任意新扁平块推测来源。
SemanticEditorProjection _fragmentPlan(
  SemanticEditorProjection previous,
  int start,
  int end,
  List<SemanticNode> inserted,
) {
  final tree = previous.source.copy(
    content: [
      ...previous.source.content.take(start),
      ...inserted,
      ...previous.source.content.skip(end),
    ],
  );
  final projected = SemanticEditorProjection.project(tree);
  final result = SemanticEditorProjection._(tree);
  final oldByPath = {
    for (final b in previous._blocks)
      if (previous._paths[b.id] != null) previous._paths[b.id]!: b,
  };
  final frames = <String, ContainerFrame>{};
  for (final generated in projected._blocks) {
    final path = projected._paths[generated.id];
    String? oldPath;
    if (path != null) {
      final pieces = path.split('/');
      final root = int.parse(pieces[1]);
      if (root < start || root >= start + inserted.length) {
        pieces[1] =
            '${root < start ? root : root - inserted.length + end - start}';
        oldPath = pieces.join('/');
      }
    }
    final old = path == null
        ? previous._blocks
              .where((b) => !previous._paths.containsKey(b.id))
              .firstOrNull
        : oldByPath[oldPath];
    final id = old?.id ?? 'semantic_fragment_${_fragmentId++}';
    List<ContainerFrame>? mappedFrames;
    if (generated is TextBlock) {
      mappedFrames = [
        for (var i = 0; i < generated.containers.length; i++)
          frames.putIfAbsent(
            generated.containers[i].groupId,
            () => old is TextBlock
                ? old.containers[i]
                : _fragmentFrameId(generated.containers[i], nextFrameGroupId()),
          ),
      ];
    }
    // 未改来源复用原块，尤其不能因路径变化重建不透明岛的内部 node id。
    result._blocks.add(old ?? _fragmentBlockId(generated, id, mappedFrames));
    if (path != null) {
      result._paths[id] = path;
      result._sources[id] = projected._sources[generated.id]!;
    }
  }
  result._transients.addAll(previous._transients);
  _validateTransients(previous, result.blocks);
  return result;
}

/// 此扩展提供节点级片段操作；不接受 Markdown 或扁平块作为新节点来源。
extension SemanticFragmentOperations on SemanticEditorSession {
  SemanticEditorProjection get _currentProjection =>
      editor.documentBindingState as SemanticEditorProjection;

  /// 光标处插入可信树片段；保留原始 inline attrs 和容器，不经 Markdown。
  void insertFragmentAtSelection(
    SemanticNode fragmentDoc, {
    EditorSelection? selection,
  }) {
    if (fragmentDoc.type != 'doc') {
      throw const SemanticEditorUnsupported('片段根节点必须是 doc');
    }
    if (fragmentDoc.content.isEmpty) return;
    editor.runAtomicEdit(() {
      if (selection != null) editor.updateSelection(selection);
      if (editor.selection == null) return;
      if (!editor.selection!.isCollapsed) editor.deleteSelection();
      final (plan, target) = _selectionFragmentPlan(fragmentDoc);
      _applyFragmentPlan(plan);
      if (target != null) {
        editor.updateSelection(EditorSelection.collapsed(target));
      }
    });
  }

  /// 只构造计划，调用者可在发布前添加 transient 授权。
  /// 调用前须在 atomic edit 内处理非折叠选区。
  (SemanticEditorProjection, EditorPosition?) _selectionFragmentPlan(
    SemanticNode fragmentDoc, {
    bool mergeParagraphs = true,
  }) {
    final p = _currentProjection;
    final caret = editor.selection!.extent;
    final block = editor.blockById(caret.blockId);
    final original = p._sources[caret.blockId];
    final path = p._paths[caret.blockId];
    final inserted = [...fragmentDoc.content];
    var caretNode = inserted.last;
    var caretOffset = 0;
    if (block is TextBlock) {
      final base = original ?? SemanticNode('paragraph');
      final offset = caret.offset.clamp(0, block.content.length);
      final head = base.copy(content: _sliceSemanticInline(base, 0, offset));
      final tail = base.copy(
        content: _sliceSemanticInline(base, offset, block.content.length),
      );
      final first = inserted.first;
      final last = inserted.last;
      final mergeFirst =
          mergeParagraphs &&
          first.type == 'paragraph' &&
          first.attrs.isEmpty &&
          first.marks.isEmpty;
      final mergeLast =
          mergeParagraphs &&
          last.type == 'paragraph' &&
          last.attrs.isEmpty &&
          last.marks.isEmpty;
      if (inserted.length == 1 && mergeFirst) {
        caretOffset =
            offset + (SemanticEditorProjection._inline(first)?.length ?? 0);
        caretNode = base.copy(
          content: [...head.content, ...first.content, ...tail.content],
        );
        inserted[0] = caretNode;
      } else {
        if (mergeFirst) {
          inserted[0] = head.copy(content: [...head.content, ...first.content]);
        } else if (head.content.isNotEmpty) {
          inserted.insert(0, head);
        }
        if (mergeLast) {
          caretOffset = SemanticEditorProjection._inline(last)?.length ?? 0;
          caretNode = tail.copy(content: [...last.content, ...tail.content]);
          inserted[inserted.length - 1] = caretNode;
        } else {
          caretNode = tail;
          inserted.add(tail);
        }
      }
    } else {
      caretNode = SemanticNode('paragraph');
      inserted.add(caretNode);
      if (original != null) inserted.insert(0, original);
    }
    SemanticNode replace(SemanticNode node, String currentPath) {
      final children = <SemanticNode>[];
      for (var i = 0; i < node.content.length; i++) {
        final childPath = '$currentPath/$i';
        if (childPath == path) {
          children.addAll(inserted);
        } else {
          children.add(replace(node.content[i], childPath));
        }
      }
      if (currentPath.isEmpty && path == null) children.addAll(inserted);
      return listEquals(children, node.content)
          ? node
          : node.copy(content: children);
    }

    final tree = replace(p.source, '');
    final projected = SemanticEditorProjection.project(tree);
    final plan = SemanticEditorProjection._(tree);
    plan._transients.addAll(p._transients);
    final used = <String>{};
    EditorPosition? target;
    final frames = <String, ContainerFrame>{};
    for (final generated in projected._blocks) {
      final source = projected._sources[generated.id];
      final prior = p._blocks
          .where(
            (b) => !used.contains(b.id) && identical(p._sources[b.id], source),
          )
          .firstOrNull;
      final id = prior?.id ?? 'semantic_fragment_${_fragmentId++}';
      used.add(id);
      final mapped = generated is TextBlock
          ? [
              for (var i = 0; i < generated.containers.length; i++)
                frames.putIfAbsent(
                  generated.containers[i].groupId,
                  () => prior is TextBlock && i < prior.containers.length
                      ? prior.containers[i]
                      : _fragmentFrameId(
                          generated.containers[i],
                          nextFrameGroupId(),
                        ),
                ),
            ]
          : null;
      plan._blocks.add(prior ?? _fragmentBlockId(generated, id, mapped));
      if (source != null) {
        plan._sources[id] = source;
        plan._paths[id] = projected._paths[generated.id]!;
      }
      if (identical(source, caretNode)) {
        target = EditorPosition(blockId: id, offset: caretOffset);
      }
    }
    _validateTransients(p, plan.blocks);
    return (plan, target);
  }

  void insertFragmentAtBlock(int boundaryIndex, SemanticNode fragmentDoc) {
    if (fragmentDoc.type != 'doc') {
      throw const SemanticEditorUnsupported('片段根节点必须是 doc');
    }
    if (fragmentDoc.content.any((n) => n.type == 'text' || n.type == 'doc')) {
      throw const SemanticEditorUnsupported('片段必须包含块节点，不支持裸 text 拼接或嵌套 doc');
    }
    final current = _currentProjection;
    final boundary = _rootBoundary(current, boundaryIndex);
    if (fragmentDoc.content.isEmpty) return;
    _applyFragmentPlan(
      _fragmentPlan(current, boundary, boundary, fragmentDoc.content),
    );
  }

  void insertNodeAtBlock(int boundaryIndex, SemanticNode node) {
    if (node.type == 'doc' || node.type == 'text') {
      throw const SemanticEditorUnsupported('整节点插入不接受 doc 或裸 text');
    }
    insertFragmentAtBlock(boundaryIndex, SemanticNode('doc', content: [node]));
  }

  /// 返回原始节点，保留未知 attrs、marks 及不透明子树。
  SemanticNode copyFragmentAtBlockRange(int start, int end) {
    final p = _currentProjection;
    final first = _rootBoundary(p, start), last = _rootBoundary(p, end);
    if (start > end) throw ArgumentError('片段范围起点不能大于终点');
    if (p._transients.values.any((ids) {
      final root = int.parse(p._paths[ids.first]!.split('/')[1]);
      return root >= first && root < last;
    })) {
      throw const SemanticEditorUnsupported('临时节点不可复制，请先 resolveTransient');
    }
    return SemanticNode('doc', content: p.source.content.sublist(first, last));
  }

  void deleteNodesAtBlockRange(int start, int end) {
    final p = _currentProjection;
    final first = _rootBoundary(p, start), last = _rootBoundary(p, end);
    if (start > end) throw ArgumentError('片段范围起点不能大于终点');
    if (first == last) return;
    _applyFragmentPlan(_fragmentPlan(p, first, last, const []));
  }

  void _applyFragmentPlan(SemanticEditorProjection plan) {
    if (_binding.trustedPlan != null) {
      throw const SemanticEditorUnsupported('不可嵌套片段事务');
    }
    _binding.trustedPlan = plan;
    try {
      editor.replaceBlockRange(0, editor.blocks.length - 1, plan.blocks);
    } finally {
      _binding.trustedPlan = null;
    }
  }
}
