part of 'semantic_editor.dart';

/// 标记来源深度不随祖先/兄弟路径变化；列表和来源均属于不可变快照。
class _TransientOrigin extends ListBase<String> {
  _TransientOrigin(Iterable<String> ids, this.depth)
    : _ids = List.unmodifiable(ids);
  final List<String> _ids;
  final int depth;
  @override
  int get length => _ids.length;
  @override
  set length(int value) => throw UnsupportedError('临时来源不可变');
  @override
  String operator [](int index) => _ids[index];
  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('临时来源不可变');
}

String _transientPath(SemanticEditorProjection p, List<String> ids) {
  final path = p._paths[ids.first];
  if (path == null) throw const SemanticEditorUnsupported('临时来源路径丢失');
  return path
      .split('/')
      .take(ids is _TransientOrigin ? ids.depth + 1 : 2)
      .join('/');
}

/// 临时节点只能通过 resolve 操作移除或替换，不能接受未知来源的编辑。
void _validateTransients(
  SemanticEditorProjection previous,
  List<EditorBlock> next,
) {
  final nextIds = next.map((b) => b.id).toList();
  for (final ids in previous._transients.values) {
    for (final id in ids) {
      final old = previous._blocks.firstWhere((b) => b.id == id);
      final index = nextIds.indexOf(id);
      if (index < 0 || next[index] != old) {
        throw const SemanticEditorUnsupported(
          '临时节点不可编辑或删除，请先 resolveTransient',
        );
      }
      final oldIndex = previous._blocks.indexOf(old);
      for (var i = 0; i < previous._blocks.length; i++) {
        final other = nextIds.indexOf(previous._blocks[i].id);
        if (other >= 0 && ((i < oldIndex) != (other < index))) {
          throw const SemanticEditorUnsupported('临时节点不可移动');
        }
      }
    }
  }
}

class _ResolveTransient {
  const _ResolveTransient(this.token, this.replacements);
  final Object token;
  final List<SemanticNode> replacements;
}

/// 仅替换明确来源的任意深度节点，不删除其 quote/list 等祖先。
SemanticNode _replaceTransientNode(
  SemanticNode node,
  List<int> path,
  List<SemanticNode> replacement,
) {
  final index = path.first;
  if (index < 0 || index >= node.content.length) {
    throw const SemanticEditorUnsupported('临时来源路径越界');
  }
  return node.copy(
    content: path.length == 1
        ? [
            ...node.content.take(index),
            ...replacement,
            ...node.content.skip(index + 1),
          ]
        : [
            for (var i = 0; i < node.content.length; i++)
              if (i == index)
                _replaceTransientNode(
                  node.content[i],
                  path.sublist(1),
                  replacement,
                )
              else
                node.content[i],
          ],
  );
}

EditorDocumentHistorySnapshot _remapTransientHistory(
  EditorDocumentHistorySnapshot snapshot,
  Object operation,
) {
  if (operation is! _ResolveTransient) throw ArgumentError('未知语义历史操作');
  final previous = snapshot.documentState as SemanticEditorProjection;
  final ids = previous._transients[operation.token];
  if (ids == null) return snapshot;
  final target = _transientPath(
    previous,
    ids,
  ).split('/').skip(1).map(int.parse).toList();
  final tree = _replaceTransientNode(
    previous.source,
    target,
    operation.replacements,
  );
  final projected = SemanticEditorProjection.project(tree);
  final result = SemanticEditorProjection._(tree);
  final oldByPath = {
    for (final b in previous._blocks) previous._paths[b.id]: b,
  };
  final frames = <String, ContainerFrame>{};
  for (final generated in projected._blocks) {
    final path = projected._paths[generated.id];
    String? oldPath = path;
    if (path != null) {
      final parts = path.split('/').skip(1).map(int.parse).toList();
      final level = target.length - 1;
      if (parts.length > level &&
          listEquals(parts.take(level).toList(), target.take(level).toList())) {
        final index = parts[level];
        if (index >= target.last &&
            index < target.last + operation.replacements.length) {
          oldPath = null;
        } else if (index >= target.last + operation.replacements.length) {
          parts[level] += 1 - operation.replacements.length;
          oldPath = '/${parts.join('/')}';
        }
      }
    }
    final old = path != null && oldPath == null ? null : oldByPath[oldPath];
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
    result._blocks.add(old ?? _fragmentBlockId(generated, id, mappedFrames));
    if (path != null) {
      result._paths[id] = path;
      result._sources[id] = projected._sources[generated.id]!;
    }
  }
  result._transients.addAll(previous._transients);
  result._transients.remove(operation.token);
  return EditorDocumentHistorySnapshot(result.blocks, result);
}

extension SemanticTransientOperations on SemanticEditorSession {
  void _checkTransientToken(Object token, SemanticNode node) {
    if (_usedTransientTokens.contains(token)) {
      throw ArgumentError('临时 token 不可复用');
    }
    if (node.type == 'doc' || node.type == 'text') {
      throw const SemanticEditorUnsupported('临时节点必须是块节点');
    }
  }

  void _applyTransientPlan(
    Object token,
    SemanticNode node,
    SemanticEditorProjection plan, {
    String? insertedPath,
  }) {
    String? origin = insertedPath;
    void find(SemanticNode current, String path) {
      if (identical(current, node)) {
        if (origin != null) throw const SemanticEditorUnsupported('临时来源不唯一');
        origin = path;
      }
      for (var i = 0; i < current.content.length; i++) {
        find(current.content[i], '$path/$i');
      }
    }

    if (origin == null) find(plan.source, '');
    if (origin == null) throw const SemanticEditorUnsupported('临时来源丢失');
    final ids = plan._blocks
        .where((b) {
          final path = plan._paths[b.id];
          return path == origin || (path?.startsWith('$origin/') ?? false);
        })
        .map((b) => b.id)
        .toList();
    if (ids.isEmpty) throw const SemanticEditorUnsupported('临时节点没有可追踪投影');
    plan._transients[token] = _TransientOrigin(
      ids,
      origin!.split('/').length - 1,
    );
    // 先登记以支持提交通知中同步完成；失败必须释放 token。
    _usedTransientTokens.add(token);
    try {
      editor.runAtomicEdit(() {
        editor.sealHistory();
        _applyFragmentPlan(plan);
      });
    } catch (_) {
      _usedTransientTokens.remove(token);
      rethrow;
    }
  }

  /// 兼容旧整根边界入口；新上传使用 insertTransientAtSelection。
  void insertTransientNodeAtBlock(
    int boundaryIndex,
    Object token,
    SemanticNode node,
  ) {
    _checkTransientToken(token, node);
    final current = _currentProjection;
    final root = _rootBoundary(current, boundaryIndex);
    _applyTransientPlan(
      token,
      node,
      _fragmentPlan(current, root, root, [node]),
      insertedPath: '/$root',
    );
  }

  /// 在当前选区插入独立占位节点，保留段中两侧正文和原容器。
  void insertTransientAtSelection(
    Object token,
    SemanticNode placeholder, {
    EditorSelection? selection,
  }) {
    _checkTransientToken(token, placeholder);
    // 独立来源对象，调用者可以复用相同节点值甚至同一对象。
    final originNode = placeholder.copy();
    try {
      editor.runAtomicEdit(() {
        editor.sealHistory();
        if (selection != null) editor.updateSelection(selection);
        if (editor.selection == null) {
          throw const SemanticEditorUnsupported('插入临时节点需要有效选区');
        }
        if (!editor.selection!.isCollapsed) editor.deleteSelection();
        final (plan, target) = _selectionFragmentPlan(
          SemanticNode('doc', content: [originNode]),
          mergeParagraphs: false,
        );
        _validateTransients(_currentProjection, plan.blocks);
        _applyTransientPlan(token, originNode, plan);
        if (target != null) {
          editor.updateSelection(EditorSelection.collapsed(target));
        }
      });
    } catch (_) {
      _usedTransientTokens.remove(token);
      rethrow;
    }
  }

  /// 当前快照的投影块 id；undo 后可能为空，redo 后恢复同一来源。
  List<String> transientBlockIds(Object token) => List.unmodifiable(
    _currentProjection._transients[token] ?? const <String>[],
  );

  /// 多块替换/取消同时映射当前、undo、redo；任一映射失败全部回滚。
  void resolveTransientFragment(Object token, SemanticNode? fragmentDoc) {
    if (!_usedTransientTokens.contains(token)) {
      throw ArgumentError('未知临时 token');
    }
    if (fragmentDoc != null &&
        (fragmentDoc.type != 'doc' ||
            fragmentDoc.content.any(
              (n) => n.type == 'doc' || n.type == 'text',
            ))) {
      throw const SemanticEditorUnsupported('替换片段必须是包含块节点的 doc');
    }
    editor.remapDocumentHistory(
      _ResolveTransient(token, fragmentDoc?.content ?? const []),
    );
  }

  void resolveTransient(Object token, [SemanticNode? replacement]) {
    if (replacement?.type == 'doc' || replacement?.type == 'text') {
      throw const SemanticEditorUnsupported('替换节点必须是块节点');
    }
    resolveTransientFragment(
      token,
      replacement == null ? null : SemanticNode('doc', content: [replacement]),
    );
  }

  /// 递归过滤来源节点；保留容器及所有周围正文。
  SemanticNode exportTree() {
    final p = _currentProjection;
    final paths = p._transients.values
        .map((ids) => _transientPath(p, ids))
        .toSet();
    SemanticNode filter(SemanticNode node, String path) => node.copy(
      content: [
        for (var i = 0; i < node.content.length; i++)
          if (!paths.contains('$path/$i')) filter(node.content[i], '$path/$i'),
      ],
    );
    return filter(p.source, '');
  }
}
