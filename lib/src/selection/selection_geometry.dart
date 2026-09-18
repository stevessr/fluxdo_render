/// 自研逻辑选区的几何/定位基础类型。
///
/// 设计对齐 super_editor 的 Document/Position/Selection 三件套,但只读场景:
/// - 文本和非文本块共享渲染偏移；行内占位符各占 1，独立非文本块也占 1，
///   通过统一几何接口提供 before/after 边界。
/// - 偏移统一用**渲染偏移**(RenderParagraph 坐标系,￼ 各占 1),命中/高亮都认它;
///   逻辑投影只在复制那一刻转(见 projection.dart)
library;

import 'dart:ui' show TextAffinity;

import 'package:flutter/foundation.dart';

/// 可选文本块的稳定标识 = **逻辑文档序** `(chunkIndex, docOrder)`。
///
/// **不再用 build 时分配的自增 seq + 几何排序**(虚拟化下注册顺序乱、滚出块
/// 取不到几何 → 选区断/乱跳)。改为对齐成熟方案(Flutter SelectionArea index /
/// CodeMirror 偏移 / ProseMirror position):
/// - [docOrder]:单个 FluxdoRender 内按 build 递归(深度优先 = 文档序)递增的
///   计数,同块每次 rebuild 稳定不变(见 NodeFactory 的共享计数器)。
/// - [chunkIndex]:长帖 sliver 分 chunk 时该 chunk 的文档序号(整帖渲染时为 0)。
///
/// `(chunkIndex, docOrder)` 字典序 = 全局文档/视觉序,纯逻辑、跨回收稳定,
/// registry 据此排序(见 SelectionRegistry.orderedBlocks),不依赖 live 几何。
@immutable
class SelectableBlockId {
  const SelectableBlockId(this.docOrder, {this.chunkIndex = 0, this.debugLabel});

  /// chunk 内文档序(深度优先 build 递增)。
  final int docOrder;

  /// 所属 chunk 的文档序号(整帖渲染时 0)。
  final int chunkIndex;

  /// 仅调试用的可读标签(如 "paragraph#3" / "codeblock"),不参与 ==。
  final String? debugLabel;

  /// 文档/视觉序比较:先 chunkIndex,再 docOrder。
  int compareTo(SelectableBlockId other) {
    final c = chunkIndex.compareTo(other.chunkIndex);
    return c != 0 ? c : docOrder.compareTo(other.docOrder);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectableBlockId &&
          runtimeType == other.runtimeType &&
          docOrder == other.docOrder &&
          chunkIndex == other.chunkIndex;

  @override
  int get hashCode => Object.hash(chunkIndex, docOrder);

  @override
  String toString() =>
      'SelectableBlockId(c$chunkIndex#$docOrder'
      '${debugLabel == null ? "" : ", $debugLabel"})';
}

/// 文档内一个点:某块 + 块内渲染偏移。
@immutable
class DocumentPosition {
  const DocumentPosition({
    required this.blockId,
    required this.renderOffset,
    this.affinity = TextAffinity.downstream,
  });

  final SelectableBlockId blockId;

  /// RenderParagraph 坐标系的字符偏移(￼ 各占 1)。
  final int renderOffset;

  /// 软换行边界的归属侧(**渲染提示,不参与 ==**):同一 offset 在换行点
  /// 有两个视觉位置 —— upstream=上一行行末,downstream=下一行行首。
  /// 命中测试保留 getPositionForOffset 的原始 affinity,编辑光标据此
  /// 画在用户点击的那一行(丢弃即"点行末光标跳下一行行首")。
  final TextAffinity affinity;

  DocumentPosition copyWith({SelectableBlockId? blockId, int? renderOffset}) =>
      DocumentPosition(
        blockId: blockId ?? this.blockId,
        renderOffset: renderOffset ?? this.renderOffset,
        affinity: affinity,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentPosition &&
          runtimeType == other.runtimeType &&
          blockId == other.blockId &&
          renderOffset == other.renderOffset;

  @override
  int get hashCode => Object.hash(blockId, renderOffset);

  @override
  String toString() => 'DocumentPosition($blockId @$renderOffset'
      '${affinity == TextAffinity.upstream ? "↑" : ""})';
}

/// 有向选区:[base] 锚点(起选不动)→ [extent] 浮标(跟手指/鼠标走)。
///
/// base/extent 的文档先后由 registry 的视觉序 + 同块 renderOffset 决定
/// (见 SelectionExporter 的归一化),本类不强制 base ≤ extent。
@immutable
class DocumentSelection {
  const DocumentSelection({required this.base, required this.extent});

  /// 折叠选区(光标态)的便捷构造 —— 只读场景下罕用,主要给"点空白前的
  /// 起选起点"或单元测试用。
  const DocumentSelection.collapsed(DocumentPosition position)
      : base = position,
        extent = position;

  final DocumentPosition base;
  final DocumentPosition extent;

  /// base == extent → 无实际选中范围。
  bool get isCollapsed => base == extent;

  /// 选区是否只落在单个块内。
  bool get isSingleBlock => base.blockId == extent.blockId;

  DocumentSelection copyWith({DocumentPosition? base, DocumentPosition? extent}) =>
      DocumentSelection(
        base: base ?? this.base,
        extent: extent ?? this.extent,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DocumentSelection &&
          runtimeType == other.runtimeType &&
          base == other.base &&
          extent == other.extent;

  @override
  int get hashCode => Object.hash(base, extent);

  @override
  String toString() => 'DocumentSelection($base → $extent)';
}
