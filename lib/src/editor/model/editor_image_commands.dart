/// 图片原子/网格的块级结构命令(官方 ProseMirror composer 图片与
/// GridNodeView 工具动作)。
///
/// **加入网格**(addToGrid,对齐 image-node-view.gjs):
/// - 相邻块是 grid 岛 → 图挪入(前邻 append / 后邻 prepend);
/// - 无相邻 grid → 原地新建单图 grid 岛,原段按原子位切三段
///   (before 文本 | grid 岛 | after 文本,空半段丢弃)。
/// 全程 [EditorState.replaceBlockRange] 单事务 —— undo 一步整体还原。
///
/// **移除网格**(removeGrid,对齐 grid-node-view.gjs:tr.replaceWith(pos,
/// pos+nodeSize, node.content) 拆壳保内容):grid 岛 → 每张图一个独立
/// 图原子段(官方 grid 内每图恰是一个 paragraph,拆出来同构)。
///
/// **模式切换**(setMode,grid ⇄ carousel):改 node attr,序列化写
/// `[grid mode=carousel]`。
///
/// 图片组内单图支持移出、删除和重排；追加图片按组标识提交，不依赖光标。
library;

import '../../node/node.dart';
import 'editable_text_content.dart';
import 'editor_state.dart';

/// 把 [blockId] 块 [offset] 处的图片原子加入网格。
/// 返回 false = 该位置不是图片原子(调用方不该出这个按钮)。
bool addImageAtomToGrid(EditorState state, String blockId, int offset) {
  final i = state.indexOfBlock(blockId);
  if (i < 0) return false;
  final block = state.blocks[i];
  if (block is! TextBlock) return false;
  final img = block.content.atoms[offset];
  if (img is! ImageRun) return false;

  final removed = block.content.delete(offset, offset + 1);
  // 删原子后是否还有实际内容(纯空段丢弃;非段落属性/容器帧保留块)
  final textRemains =
      removed.length > 0 || !block.isParagraph || block.containers.isNotEmpty;

  EditorSelection selectIsland(String id) => EditorSelection(
    base: EditorPosition(blockId: id, offset: 0),
    extent: EditorPosition(blockId: id, offset: 1),
  );

  // ---- 分支 1:前邻是 grid 岛 → append ----
  final prev = i > 0 ? state.blocks[i - 1] : null;
  if (prev is IslandBlock && prev.node is ImageGridNode) {
    final grid = prev.node as ImageGridNode;
    final newGrid = IslandBlock(
      id: prev.id,
      node: ImageGridNode(
        id: grid.id,
        images: [...grid.images, img],
        columns: grid.columns,
        mode: grid.mode,
      ),
    );
    state.replaceBlockRange(i - 1, i, [
      newGrid,
      if (textRemains) block.copyWith(content: removed),
    ], selection: selectIsland(newGrid.id));
    return true;
  }

  // ---- 分支 2:后邻是 grid 岛 → prepend ----
  final next = i + 1 < state.blocks.length ? state.blocks[i + 1] : null;
  if (next is IslandBlock && next.node is ImageGridNode) {
    final grid = next.node as ImageGridNode;
    final newGrid = IslandBlock(
      id: next.id,
      node: ImageGridNode(
        id: grid.id,
        images: [img, ...grid.images],
        columns: grid.columns,
        mode: grid.mode,
      ),
    );
    state.replaceBlockRange(i, i + 1, [
      if (textRemains) block.copyWith(content: removed),
      newGrid,
    ], selection: selectIsland(newGrid.id));
    return true;
  }

  // ---- 分支 3:原地新建单图 grid 岛,段按原子位切三段 ----
  final (before, after) = removed.split(offset);
  final islandId = state.nextBlockId();
  final newGrid = IslandBlock(
    id: islandId,
    node: ImageGridNode(id: 'b_grid_$islandId', images: [img]),
  );
  state.replaceBlockRange(i, i, [
    if (before.length > 0) block.copyWith(content: before),
    newGrid,
    if (after.length > 0)
      TextBlock(
        id: state.nextBlockId(),
        content: after,
        kind: block.kind,
        headingLevel: block.headingLevel,
        ordered: block.ordered,
        depth: block.depth,
        listStart: block.listStart,
        listLoose: block.listLoose,
        containers: block.containers,
      ),
  ], selection: selectIsland(islandId));
  return true;
}

/// 移除网格:grid 岛拆壳,每张图变一个独立图原子段(官方 removeGrid
/// 的 replaceWith(node.content) 同构 —— grid 内每图恰是一段)。
/// 光标落首段图后。返回 false = 该块不是 grid 岛。
bool removeImageGrid(EditorState state, String islandId) {
  final i = state.indexOfBlock(islandId);
  if (i < 0) return false;
  final block = state.blocks[i];
  if (block is! IslandBlock || block.node is! ImageGridNode) return false;
  final grid = block.node as ImageGridNode;

  final replacement = <EditorBlock>[
    for (final img in grid.images)
      TextBlock(
        id: state.nextBlockId(),
        content: EditableTextContent.fromInlines([img]),
      ),
  ];
  state.replaceBlockRange(
    i,
    i,
    replacement,
    selection: replacement.isEmpty
        ? null
        : EditorSelection.collapsed(
            EditorPosition(blockId: replacement.first.id, offset: 1),
          ),
  );
  return true;
}

/// 网格模式切换(grid ⇄ carousel):岛节点原位形变,序列化写
/// `[grid mode=carousel]`。返回 false = 该块不是 grid 岛。
bool setImageGridMode(EditorState state, String islandId, ImageGridMode mode) {
  final i = state.indexOfBlock(islandId);
  if (i < 0) return false;
  final block = state.blocks[i];
  if (block is! IslandBlock || block.node is! ImageGridNode) return false;
  final grid = block.node as ImageGridNode;
  if (grid.mode == mode) return true;
  state.updateIslandNode(
    islandId,
    ImageGridNode(
      id: grid.id,
      images: grid.images,
      columns: grid.columns,
      mode: mode,
    ),
  );
  return true;
}

/// 删除 grid 内第 [imageIndex] 张图。删到空 → 整岛移除(官方
/// appendTransaction 的空 grid 清理同语义)。返回 false = 不是 grid 岛
/// 或下标越界。
bool removeImageFromGrid(EditorState state, String islandId, int imageIndex) {
  final i = state.indexOfBlock(islandId);
  if (i < 0) return false;
  final block = state.blocks[i];
  if (block is! IslandBlock || block.node is! ImageGridNode) return false;
  final grid = block.node as ImageGridNode;
  if (imageIndex < 0 || imageIndex >= grid.images.length) return false;

  final images = [...grid.images]..removeAt(imageIndex);
  if (images.isEmpty) {
    state.replaceBlockRange(i, i, const []);
    return true;
  }
  state.updateIslandNode(
    islandId,
    ImageGridNode(
      id: grid.id,
      images: images,
      columns: grid.columns,
      mode: grid.mode,
    ),
  );
  return true;
}

/// 把 grid 内第 [imageIndex] 张图移出网格(官方 moveOutsideGrid):
/// 图从 images 抽出,变 grid 岛**后方**的独立图原子段(官方 insert at
/// gridEndPos 同方向);grid 只剩它一张时整岛替换为图段(官方
/// willGridBeEmpty 分支)。单事务 undo 一步。
bool moveImageOutsideGrid(EditorState state, String islandId, int imageIndex) {
  final i = state.indexOfBlock(islandId);
  if (i < 0) return false;
  final block = state.blocks[i];
  if (block is! IslandBlock || block.node is! ImageGridNode) return false;
  final grid = block.node as ImageGridNode;
  if (imageIndex < 0 || imageIndex >= grid.images.length) return false;

  final img = grid.images[imageIndex];
  final rest = [...grid.images]..removeAt(imageIndex);
  final imgBlock = TextBlock(
    id: state.nextBlockId(),
    content: EditableTextContent.fromInlines([img]),
  );

  state.replaceBlockRange(
    i,
    i,
    [
      if (rest.isNotEmpty)
        IslandBlock(
          id: block.id,
          node: ImageGridNode(
            id: grid.id,
            images: rest,
            columns: grid.columns,
            mode: grid.mode,
          ),
        ),
      imgBlock,
    ],
    // 移出的图保持被选中(原子整选)—— 官方 setSelection(NodeSelection)
    selection: EditorSelection(
      base: EditorPosition(blockId: imgBlock.id, offset: 0),
      extent: EditorPosition(blockId: imgBlock.id, offset: 1),
    ),
  );
  return true;
}

/// grid 内图片重排(瓦片拖拽排序):第 [from] 张抽出插到 [to] 位
/// (插入语义,官方 ProseMirror 拖放同款)。岛节点原位形变不经 cook,
/// undo 一步。返回 false = 不是 grid 岛或下标越界。
bool reorderImageInGrid(EditorState state, String islandId, int from, int to) {
  final i = state.indexOfBlock(islandId);
  if (i < 0) return false;
  final block = state.blocks[i];
  if (block is! IslandBlock || block.node is! ImageGridNode) return false;
  final grid = block.node as ImageGridNode;
  if (from < 0 || from >= grid.images.length) return false;
  if (to < 0 || to >= grid.images.length) return false;
  if (from == to) return true;

  final images = [...grid.images];
  final img = images.removeAt(from);
  images.insert(to, img);
  state.updateIslandNode(
    islandId,
    ImageGridNode(
      id: grid.id,
      images: images,
      columns: grid.columns,
      mode: grid.mode,
    ),
  );
  return true;
}

/// Append to a captured group, independently of the caret. Merge with the
/// current group so uploads completing after a reorder do not overwrite it.
bool appendImagesToGrid(
  EditorState state,
  String islandId,
  List<ImageRun> images,
) {
  if (images.isEmpty) return false;
  final index = state.indexOfBlock(islandId);
  if (index < 0) return false;
  final block = state.blocks[index];
  if (block is! IslandBlock || block.node is! ImageGridNode) return false;
  final grid = block.node as ImageGridNode;
  state.updateIslandNode(
    islandId,
    ImageGridNode(
      id: grid.id,
      images: [...grid.images, ...images],
      columns: grid.columns,
      mode: grid.mode,
    ),
  );
  return true;
}
