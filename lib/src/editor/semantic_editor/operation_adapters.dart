part of 'semantic_editor.dart';

/// 命令来源决定叶节点所有权；删除/合并保留存活 id 的块属性，
/// 被删除 id 的属性随该块删除，历史快照仍保存完整原树。
SemanticNode _applyStructureIntent(
  SemanticEditorProjection p,
  List<EditorBlock> blocks,
  EditorStructureIntent intent,
) {
  if (listEquals(blocks, p._blocks) &&
      !List.generate(blocks.length, (i) {
        final a = p._blocks[i], b = blocks[i];
        return a is IslandBlock && b is IslandBlock &&
            a.node is ImageGridNode && b.node is ImageGridNode &&
            !identical(a.node, b.node);
      }).any((changed) => changed)) {
    return p.source;
  }
  // 文本/IR 和同 ID 岛更新优先原位改写，绝不重组祖先容器或 list_item 分段。
  // 岛字段由 synchronize 的媒体/语义适配器校验；不支持的修改不得退回结构重建。
  if (blocks.length == p._blocks.length &&
      List.generate(blocks.length, (i) {
        final a = p._blocks[i], b = blocks[i];
        return a is TextBlock && b is TextBlock
            ? a.copyWith(content: b.content, headingLevel: b.headingLevel) == b
            : a is IslandBlock && b is IslandBlock
            ? a.id == b.id
            : a == b;
      }).every((same) => same)) {
    try {
      return p.synchronize(
        blocks,
        allowNewAtoms: intent.command == 'insertAtom',
      );
    } on SemanticEditorUnsupported {
      // 虚拟落点晋升仍走显式来源路径。
      if (blocks.every((b) => p._sources.containsKey(b.id))) rethrow;
    }
  }
  final old = {for (final b in p._blocks) b.id: b};
  if (intent.command == 'replaceBlockRange' &&
      !((intent.fragment?.every((b) =>
          b is TextBlock && b.isParagraph && b.containers.isEmpty &&
          b.content == EditableTextContent.empty) ?? false) &&
          blocks.length == 1 && blocks.single is TextBlock &&
          (blocks.single as TextBlock).isParagraph &&
          (blocks.single as TextBlock).containers.isEmpty &&
          (blocks.single as TextBlock).content == EditableTextContent.empty) &&
      blocks.isNotEmpty &&
      blocks.every((b) => !old.containsKey(b.id))) {
    throw const SemanticEditorUnsupported('整文档替换须使用可信片段计划');
  }

  final nodes = <String, SemanticNode>{};
  void index(SemanticNode n, String path) {
    nodes[path] = n;
    for (var i = 0; i < n.content.length; i++) {
      index(n.content[i], '$path/$i');
    }
  }

  index(p.source, '');
  final frameSources = <String, SemanticNode>{};
  final framePaths = <String, String>{};
  for (final b in p._blocks.whereType<TextBlock>()) {
    final path = p._paths[b.id];
    if (path == null) continue;
    final ancestors = <String>[];
    var parent = path.substring(0, path.lastIndexOf('/'));
    while (parent.isNotEmpty) {
      if (!{
        'list_item',
        'bullet_list',
        'ordered_list',
        'wrap',
      }.contains(nodes[parent]!.type)) {
        ancestors.insert(0, parent);
      }
      parent = parent.substring(0, parent.lastIndexOf('/'));
    }
    for (var i = 0; i < b.containers.length && i < ancestors.length; i++) {
      frameSources[b.containers[i].groupId] = nodes[ancestors[i]]!;
      framePaths[b.containers[i].groupId] = ancestors[i];
    }
  }
  final root = _StructureBranch('', p.source);
  List<_StructureBranch> active = [root];
  void append(List<(String, SemanticNode)> wrappers, SemanticNode leaf) {
    var shared = 0;
    while (shared < wrappers.length &&
        shared + 1 < active.length &&
        active[shared + 1].key == wrappers[shared].$1 &&
        active[shared + 1].source.type == wrappers[shared].$2.type &&
        mapEquals(active[shared + 1].source.attrs, wrappers[shared].$2.attrs)) {
      shared++;
    }
    active = active.take(shared + 1).toList();
    for (var i = shared; i < wrappers.length; i++) {
      final branch = _StructureBranch(wrappers[i].$1, wrappers[i].$2);
      active.last.children.add(branch);
      active.add(branch);
    }
    active.last.children.add(leaf);
  }

  final splitSources = <String, SemanticNode>{};
  // Enter 的新增尾段明确继承被切分叶节点，而非继承任意邻居。
  if (intent.command == 'splitBlock') {
    for (var i = 0; i < blocks.length; i++) {
      final first = blocks[i];
      final original = old[first.id];
      final origin = p._sources[first.id];
      if (first is! TextBlock || original is! TextBlock || origin == null) {
        continue;
      }
      var offset = first.content.length;
      for (
        var j = i + 1;
        j < blocks.length && !old.containsKey(blocks[j].id);
        j++
      ) {
        final tail = blocks[j];
        if (tail is! TextBlock ||
            offset + tail.content.length > original.content.length) {
          break;
        }
        splitSources[tail.id] = origin.copy(
          content: _sliceSemanticInline(
            origin,
            offset,
            offset + tail.content.length,
          ),
        );
        offset += tail.content.length;
      }
    }
  }
  final pasteSources = <String, SemanticNode>{};
  final paste = intent.fragment;
  if (intent.command == 'pasteBlocks' && paste != null && paste.isNotEmpty) {
    final start = old[intent.startBlockId];
    final end = old[intent.endBlockId];
    final host = p._sources[intent.startBlockId];
    final endNode = p._sources[intent.endBlockId];
    if (start is TextBlock &&
        end is TextBlock &&
        host != null &&
        endNode != null) {
      final head = _sliceSemanticInline(host, 0, intent.startOffset!);
      final tail = _sliceSemanticInline(
        endNode,
        intent.endOffset!,
        end.content.length,
      );
      SemanticNode leaf(EditorBlock b) {
        if (b is IslandBlock) return _semanticNodeFromBlock(b.node);
        final text = b as TextBlock;
        final original = p._sources[b.id];
        final prior = old[b.id];
        if (original != null &&
            prior is TextBlock &&
            prior.content == text.content) {
          return original;
        }
        final base = SemanticNode(
          text.isHeading ? 'heading' : 'paragraph',
          attrs: text.isHeading ? {'level': text.headingLevel} : const {},
        );
        return base.copy(
          content: SemanticEditorProjection._rewrite(
            base,
            EditableTextContent.empty,
            text.content,
            allowNewAtoms: true,
          ),
        );
      }

      final first = paste.first, last = paste.last;
      final firstPlain =
          first is TextBlock && first.isParagraph && first.containers.isEmpty;
      final lastPlain =
          paste.length > 1 &&
          last is TextBlock &&
          last.isParagraph &&
          last.containers.isEmpty;
      final assembled = <SemanticNode>[];
      if (paste.length == 1 && firstPlain) {
        assembled.add(
          host.copy(content: [...head, ...leaf(first).content, ...tail]),
        );
      } else {
        if (firstPlain || head.isNotEmpty) {
          assembled.add(
            host.copy(
              content: [...head, if (firstPlain) ...leaf(first).content],
            ),
          );
        }
        for (
          var i = firstPlain ? 1 : 0;
          i < paste.length - (lastPlain ? 1 : 0);
          i++
        ) {
          assembled.add(leaf(paste[i]));
        }
        assembled.add(
          (lastPlain ? leaf(last) : host).copy(
            content: [if (lastPlain) ...leaf(last).content, ...tail],
          ),
        );
      }
      final startIndex = p._blocks.indexOf(start);
      for (
        var i = 0;
        i < assembled.length && startIndex + i < blocks.length;
        i++
      ) {
        pasteSources[blocks[startIndex + i].id] = assembled[i];
      }
    }
  }
  final mergedContent = <String, List<SemanticNode>>{};
  // 显式跨块选区的剩余头尾来自原始范围，保留双方 inline attrs/marks。
  final startId = intent.startBlockId, endId = intent.endBlockId;
  if (startId != null &&
      endId != null &&
      startId != endId &&
      {
        'deleteSelection',
        'replaceCrossBlockSelection',
      }.contains(intent.command)) {
    final first = old[startId], last = old[endId];
    if (first is TextBlock &&
        last is TextBlock &&
        p._sources[startId] != null &&
        p._sources[endId] != null) {
      final head = _sliceSemanticInline(
        p._sources[startId]!,
        0,
        intent.startOffset!,
      );
      final tail = _sliceSemanticInline(
        p._sources[endId]!,
        intent.endOffset!,
        last.content.length,
      );
      final next = blocks
          .whereType<TextBlock>()
          .where((b) => b.id == startId)
          .firstOrNull;
      if (next != null) {
        final candidate = p._sources[startId]!.copy(
          content: [...head, ...tail],
        );
        final inline = SemanticEditorProjection._inline(candidate)!;
        mergedContent[startId] = inline == next.content
            ? candidate.content
            : SemanticEditorProjection._rewrite(
                candidate,
                inline,
                next.content,
              );
      }
    }
  }
  if (intent.command == 'mergeWithPrevious' ||
      intent.command == 'backspace' ||
      intent.command == 'deleteForward') {
    for (var i = 0; i + 1 < p._blocks.length; i++) {
      final a = p._blocks[i], b = p._blocks[i + 1];
      if (a is! TextBlock ||
          b is! TextBlock ||
          blocks.any((n) => n.id == b.id)) {
        continue;
      }
      final next = blocks
          .whereType<TextBlock>()
          .where((n) => n.id == a.id)
          .firstOrNull;
      if (next != null && next.content == a.content.concat(b.content)) {
        mergedContent[a.id] = [
          ...p._sources[a.id]!.content,
          ...p._sources[b.id]!.content,
        ];
      }
    }
  }
  String? lastList;
  var listSerial = 0;
  for (final block in blocks) {
    final before = old[block.id];
    final source =
        pasteSources[block.id] ??
        p._sources[block.id] ??
        splitSources[block.id];
    final wrappers = <(String, SemanticNode)>[];
    if (block is IslandBlock) {
      if (before == null) {
        append(wrappers, source ?? _semanticNodeFromBlock(block.node));
        lastList = null;
        continue;
      }
      if (source == null || before is! IslandBlock) {
        throw const SemanticEditorUnsupported('已有岛来源类型不一致');
      }
      var path = p._paths[block.id]!;
      final ancestors = <String>[];
      while (path.lastIndexOf('/') > 0) {
        path = path.substring(0, path.lastIndexOf('/'));
        ancestors.insert(0, path);
      }
      for (final path in ancestors) {
        wrappers.add((path, nodes[path]!));
      }
      final leaf = before == block
          ? source
          : (_synchronizeMedia(source, before.node, block.node) ??
                _synchronizeSemanticBlock(source, before.node, block.node));
      if (leaf == null) throw const SemanticEditorUnsupported('岛修改需要明确适配');
      append(wrappers, leaf);
      lastList = null;
      continue;
    }
    final text = block as TextBlock;
    // 空文档/全岛的虚拟落点不参与树，首次输入才晋升。
    if (source == null &&
        before == text &&
        text.content.length == 0 &&
        !text.isListItem &&
        text.containers.isEmpty) {
      continue;
    }
    // wrap 没有可见 frame，但仍是必须保留属性和归属的真实祖先。
    final wrapPaths = <String>[];
    var ancestor = p._paths[text.id];
    while (ancestor != null && ancestor.lastIndexOf('/') > 0) {
      ancestor = ancestor.substring(0, ancestor.lastIndexOf('/'));
      if (nodes[ancestor]?.type == 'wrap') wrapPaths.insert(0, ancestor);
    }
    var wrapIndex = 0;
    for (final frame in text.containers) {
      final framePath = framePaths[frame.groupId];
      while (wrapIndex < wrapPaths.length &&
          framePath != null &&
          framePath.startsWith('${wrapPaths[wrapIndex]}/')) {
        final path = wrapPaths[wrapIndex++];
        wrappers.add((path, nodes[path]!));
      }
      wrappers.add((
        framePath ?? frame.groupId,
        _structureFrame(frame, frameSources[frame.groupId]),
      ));
    }
    while (wrapIndex < wrapPaths.length) {
      final path = wrapPaths[wrapIndex++];
      wrappers.add((path, nodes[path]!));
    }
    if (text.isListItem) {
      final oldPath = p._paths[text.id];
      final listPaths = <String>[];
      if (oldPath != null) {
        var path = oldPath;
        while (path.lastIndexOf('/') > 0) {
          path = path.substring(0, path.lastIndexOf('/'));
          if ({'bullet_list', 'ordered_list'}.contains(nodes[path]!.type)) {
            listPaths.insert(0, path);
          }
        }
      }
      lastList ??= 'new_list_${listSerial++}';
      for (var depth = 0; depth <= text.depth; depth++) {
        final activeIndex = wrappers.length + 1;
        final previousList =
            activeIndex < active.length &&
                {
                  'ordered_list',
                  'bullet_list',
                }.contains(active[activeIndex].source.type)
            ? active[activeIndex]
            : null;
        final path = depth < listPaths.length
            ? listPaths[depth]
            : previousList?.key ?? '$lastList/$depth';
        final original = nodes[path];
        final attrs = {...?original?.attrs};
        if (text.ordered) {
          attrs['order'] = text.listStart;
        } else {
          attrs.remove('order');
        }
        if (text.listLoose || attrs.containsKey('tight')) {
          attrs['tight'] = !text.listLoose;
        }
        final listType = text.ordered ? 'ordered_list' : 'bullet_list';
        wrappers.add((
          path,
          original != null &&
                  original.type == listType &&
                  mapEquals(attrs, original.attrs)
              ? original
              : SemanticNode(
                  listType,
                  attrs: attrs,
                  marks: original?.marks ?? const [],
                ),
        ));
        final itemPath = oldPath != null && depth == text.depth
            ? oldPath.substring(0, oldPath.lastIndexOf('/'))
            : '$path/item';
        // 当前层 item 按稳定来源区分；嵌套层挂前项由深度路径分组。
        // 普通段落的父节点可能是 doc/引用/详情，只有真实 list_item
        // 才能复用其属性与来源，不能将任意原父节点塞进列表。
        final previousItem = activeIndex + 1 < active.length
            ? active[activeIndex + 1]
            : null;
        wrappers.add((
          depth < text.depth && previousItem != null
              ? previousItem.key
              : oldPath != null && before is TextBlock && before.isListItem
              ? itemPath
              : '$itemPath:${text.id}',
          depth < text.depth && previousItem != null
              ? previousItem.source
              : nodes[itemPath]?.type == 'list_item'
              ? nodes[itemPath]!
              : SemanticNode('list_item'),
        ));
      }
    } else {
      lastList = null;
    }
    final base = source ?? SemanticNode('paragraph');
    final attrs = {...base.attrs};
    if (text.isHeading) {
      attrs['level'] = text.headingLevel;
    } else {
      attrs.remove('level');
    }
    final content =
        pasteSources[text.id]?.content ??
        mergedContent[text.id] ??
        (before == null && splitSources.containsKey(text.id)
            ? splitSources[text.id]!.content
            : before is TextBlock && source != null
            ? before.content == text.content
                  ? source.content
                  : SemanticEditorProjection._rewrite(
                      source,
                      before.content,
                      text.content,
                    )
            : SemanticEditorProjection._rewrite(
                base,
                EditableTextContent.empty,
                text.content,
              ));
    final type = text.isHeading ? 'heading' : 'paragraph';
    final leaf =
        type == base.type &&
            mapEquals(attrs, base.attrs) &&
            listEquals(content, base.content)
        ? base
        : SemanticNode(type, attrs: attrs, marks: base.marks, content: content);
    append(wrappers, leaf);
  }
  return root.build();
}

class _StructureBranch {
  _StructureBranch(this.key, this.source);
  final String key;
  final SemanticNode source;
  final List<Object> children = [];
  SemanticNode build() {
    final content = <SemanticNode>[
      if (source.type == 'details' &&
          source.content.firstOrNull?.type == 'summary')
        source.content.first,
      for (final child in children)
        child is _StructureBranch ? child.build() : child as SemanticNode,
    ];
    return listEquals(content, source.content)
        ? source
        : source.copy(content: content);
  }
}

SemanticNode _structureFrame(ContainerFrame frame, SemanticNode? old) {
  final attrs = {...?old?.attrs};
  String type;
  List<SemanticNode> content = old?.content ?? const [];
  switch (frame) {
    case QuoteFrame():
      type = 'blockquote';
    case QuoteCardFrame f:
      type = 'quote';
      attrs['username'] = f.username;
      if (f.postNumber != null || attrs.containsKey('postNumber')) {
        attrs['postNumber'] = f.postNumber;
      }
      if (f.topicId != null || attrs.containsKey('topicId')) {
        attrs['topicId'] = f.topicId;
      }
      if (f.full || attrs.containsKey('full')) attrs['full'] = f.full;
      if (f.displayName != null || attrs.containsKey('displayName')) {
        attrs['displayName'] = f.displayName;
      }
    case DetailsFrame f:
      type = 'details';
      if (f.open || attrs.containsKey('open')) attrs['open'] = f.open;
      if (content.firstOrNull?.textContent != f.summary) {
        content = [
          SemanticNode(
            'summary',
            content: [SemanticNode('text', text: f.summary)],
          ),
        ];
      }
    case SpoilerFrame():
      type = 'spoiler';
    case CalloutFrame f:
      type = 'callout';
      if (f.typeRaw != 'note' || attrs.containsKey('typeRaw')) {
        attrs['typeRaw'] = f.typeRaw;
      }
      if (f.title != null || attrs.containsKey('title')) {
        attrs['title'] = f.title;
      }
      if (f.foldable != null || attrs.containsKey('foldable')) {
        attrs['foldable'] = f.foldable;
      }
  }
  if (old != null &&
      type == old.type &&
      mapEquals(attrs, old.attrs) &&
      identical(content, old.content)) {
    return old;
  }
  return SemanticNode(
    type,
    attrs: attrs,
    marks: old?.marks ?? const [],
    content: content,
  );
}
