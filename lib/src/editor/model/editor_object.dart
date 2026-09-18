import 'dart:ui' show Offset, Rect;
import 'package:flutter/foundation.dart';

import '../../node/node.dart';
import 'editable_text_content.dart';
import 'editor_image_commands.dart';
import 'editor_state.dart';
import 'markdown_serializer.dart';

/// 对象身份与屏幕位置分离；动作执行时重新解析，不能操作已删除的旧对象。
@immutable
sealed class EditorObjectTarget {
  const EditorObjectTarget(this.blockId);
  final String blockId;
}

class EditorBlockTarget extends EditorObjectTarget {
  const EditorBlockTarget(super.blockId);
  @override
  bool operator ==(Object other) =>
      other is EditorBlockTarget && blockId == other.blockId;
  @override
  int get hashCode => Object.hash(EditorBlockTarget, blockId);
}

class EditorImageTarget extends EditorObjectTarget {
  const EditorImageTarget(super.blockId, this.offset, this.src);
  final int offset;
  final String src;
  @override
  bool operator ==(Object other) =>
      other is EditorImageTarget &&
      blockId == other.blockId &&
      offset == other.offset &&
      src == other.src;
  @override
  int get hashCode => Object.hash(EditorImageTarget, blockId, offset, src);
}

class EditorGridImageTarget extends EditorObjectTarget {
  const EditorGridImageTarget(super.blockId, this.index, this.src);
  final int index;
  final String src;
  @override
  bool operator ==(Object other) =>
      other is EditorGridImageTarget &&
      blockId == other.blockId &&
      index == other.index &&
      src == other.src;
  @override
  int get hashCode => Object.hash(EditorGridImageTarget, blockId, index, src);
}

class EditorContainerTarget extends EditorObjectTarget {
  const EditorContainerTarget(super.blockId, this.groupId);
  final String groupId;
  @override
  bool operator ==(Object other) =>
      other is EditorContainerTarget &&
      blockId == other.blockId &&
      groupId == other.groupId;
  @override
  int get hashCode => Object.hash(EditorContainerTarget, blockId, groupId);
}

@immutable
class EditorObjectSelection {
  const EditorObjectSelection({
    required this.target,
    required this.globalRect,
    required this.revision,
  });
  final EditorObjectTarget target;
  final Rect globalRect;
  final int revision;
  @override
  bool operator ==(Object other) =>
      other is EditorObjectSelection &&
      target == other.target &&
      globalRect == other.globalRect &&
      revision == other.revision;
  @override
  int get hashCode => Object.hash(target, globalRect, revision);
}

/// 右键携带鼠标坐标，直接打开临时菜单，不依赖工具栏完成布局。
class EditorObjectMenuRequest {
  const EditorObjectMenuRequest({
    required this.target,
    this.globalPosition,
    this.globalAnchorRect,
    this.transient = false,
  });
  final EditorObjectTarget target;
  final Offset? globalPosition;
  final Rect? globalAnchorRect;
  final bool transient;
}

/// 同一解析结果驱动选区、复制、删除与前后输入，容器只覆盖连续的本组内容。
class ResolvedEditorObject {
  const ResolvedEditorObject({
    required this.target,
    required this.blocks,
    required this.start,
    required this.end,
    this.image,
    this.frame,
    this.frameDepth,
  });
  final EditorObjectTarget target;
  final List<EditorBlock> blocks;
  final int start;
  final int end;
  final ImageRun? image;
  final ContainerFrame? frame;
  final int? frameDepth;
  EditorBlock get block => blocks.first;
  EditorSelection get selection => switch (target) {
    EditorImageTarget(:final offset) => EditorSelection(
      base: EditorPosition(blockId: block.id, offset: offset),
      extent: EditorPosition(blockId: block.id, offset: offset + 1),
    ),
    _ => EditorSelection(
      base: EditorPosition(blockId: block.id, offset: 0),
      extent: EditorPosition(
        blockId: blocks.last.id,
        offset: blocks.last.selectionLength,
      ),
    ),
  };

  List<ContainerFrame> get parentFrames => switch (block) {
    TextBlock(:final containers) =>
      frameDepth == null ? containers : containers.take(frameDepth!).toList(),
    _ => const [],
  };

  List<EditorBlock> get fragment {
    if (image != null) {
      return [
        TextBlock(
          id: block.id,
          content: EditableTextContent.fromInlines([image!]),
        ),
      ];
    }
    return [
      for (final block in blocks)
        if (block is TextBlock)
          block.copyWith(
            containers: frameDepth == null
                ? const []
                : block.containers.sublist(frameDepth!),
          )
        else
          block,
    ];
  }

  String get markdown => docToMarkdown(fragment);

  /// 菜单能力判定不序列化正文；大代码块/容器滚动时也保持轻量。
  bool get canCopy =>
      image != null ||
      frame != null ||
      blocks.any(
        (block) => switch (block) {
          TextBlock() =>
            block.content.length > 0 || block.kind != TextBlockKind.paragraph,
          IslandBlock(:final node) =>
            islandSerializable(node) &&
                switch (node) {
                  BlankLineNode() => false,
                  OneboxNode(:final url) => url?.isNotEmpty ?? false,
                  LazyVideoNode(:final url) => url.isNotEmpty,
                  FootnotesSectionNode(:final entries) => entries.isNotEmpty,
                  DefinitionListNode(:final items) => items.isNotEmpty,
                  ImageGridNode(:final images) => images.isNotEmpty,
                  SvgNode(:final svgSource) => svgSource.isNotEmpty,
                  VideoNode(:final src) ||
                  AudioNode(:final src) => src.isNotEmpty,
                  ParagraphNode(:final inlines) => inlines.isNotEmpty,
                  _ => true,
                },
        },
      );
}

ResolvedEditorObject? resolveEditorObject(
  EditorState state,
  EditorObjectTarget target,
) {
  final index = state.indexOfBlock(target.blockId);
  if (index < 0) return null;
  final block = state.blocks[index];
  switch (target) {
    case EditorImageTarget(:final offset, :final src):
      final image = block is TextBlock ? block.content.atoms[offset] : null;
      if (image is! ImageRun || image.src != src) return null;
      return ResolvedEditorObject(
        target: target,
        blocks: [block],
        start: index,
        end: index,
        image: image,
      );
    case EditorGridImageTarget(:final index, :final src):
      final node = block is IslandBlock ? block.node : null;
      if (node is! ImageGridNode ||
          index < 0 ||
          index >= node.images.length ||
          node.images[index].src != src) {
        return null;
      }
      return ResolvedEditorObject(
        target: target,
        blocks: [block],
        start: state.indexOfBlock(block.id),
        end: state.indexOfBlock(block.id),
        image: node.images[index],
      );
    case EditorContainerTarget(:final groupId):
      if (block is! TextBlock) return null;
      final depth = block.containers.indexWhere(
        (frame) => frame.groupId == groupId,
      );
      if (depth < 0) return null;
      bool belongs(EditorBlock candidate) =>
          candidate is TextBlock &&
          candidate.containers.length > depth &&
          listEquals(
            candidate.containers.take(depth + 1).toList(),
            block.containers.take(depth + 1).toList(),
          );
      var start = index;
      var end = index;
      while (start > 0 && belongs(state.blocks[start - 1])) {
        start--;
      }
      while (end + 1 < state.blocks.length && belongs(state.blocks[end + 1])) {
        end++;
      }
      return ResolvedEditorObject(
        target: target,
        blocks: state.blocks.sublist(start, end + 1),
        start: start,
        end: end,
        frame: block.containers[depth],
        frameDepth: depth,
      );
    case EditorBlockTarget():
      return ResolvedEditorObject(
        target: target,
        blocks: [block],
        start: index,
        end: index,
      );
  }
}

bool deleteEditorObject(EditorState state, EditorObjectTarget target) {
  final object = resolveEditorObject(state, target);
  if (object == null) return false;
  switch (target) {
    case EditorGridImageTarget(:final index):
      return removeImageFromGrid(state, target.blockId, index);
    case EditorImageTarget():
      state.updateSelection(object.selection);
      state.deleteSelection();
    case EditorBlockTarget() || EditorContainerTarget():
      final next = object.end + 1 < state.blocks.length
          ? state.blocks[object.end + 1]
          : object.start > 0
          ? state.blocks[object.start - 1]
          : null;
      final empty = TextBlock(
        id: state.nextBlockId(),
        content: EditableTextContent.empty,
      );
      final replacement = next == null ? [empty] : <EditorBlock>[];
      state.replaceBlockRange(
        object.start,
        object.end,
        replacement,
        selection: EditorSelection.collapsed(
          EditorPosition(
            blockId: next?.id ?? empty.id,
            offset: next == null || object.end + 1 < state.blocks.length
                ? 0
                : next.selectionLength,
          ),
        ),
      );
  }
  return true;
}

void placeCaretBesideEditorObject(
  EditorState state,
  EditorObjectTarget target, {
  required bool after,
}) {
  final object = resolveEditorObject(state, target);
  if (object == null) return;
  if (target case EditorImageTarget(:final offset)) {
    state.placeCaretBesideObject(
      target.blockId,
      atomOffset: offset,
      after: after,
    );
    return;
  }
  final edge = after ? object.end : object.start;
  final neighborIndex = edge + (after ? 1 : -1);
  final parents = object.parentFrames;
  if (neighborIndex >= 0 && neighborIndex < state.blocks.length) {
    final neighbor = state.blocks[neighborIndex];
    if (neighbor is TextBlock && listEquals(neighbor.containers, parents)) {
      state.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(
            blockId: neighbor.id,
            offset: after ? 0 : neighbor.selectionLength,
          ),
        ),
      );
      return;
    }
  }
  final empty = TextBlock(
    id: state.nextBlockId(),
    content: EditableTextContent.empty,
    containers: parents,
  );
  state.replaceBlockRange(
    edge,
    edge,
    after ? [state.blocks[edge], empty] : [empty, state.blocks[edge]],
    selection: EditorSelection.collapsed(
      EditorPosition(blockId: empty.id, offset: 0),
    ),
  );
}

bool unwrapEditorContainer(EditorState state, EditorContainerTarget target) {
  final object = resolveEditorObject(state, target);
  if (object == null) return false;
  state.replaceBlockRange(object.start, object.end, [
    for (final block in object.blocks)
      (block as TextBlock).copyWith(
        containers: [...block.containers]..removeAt(object.frameDepth!),
      ),
  ], selection: object.selection);
  return true;
}
