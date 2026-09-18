/// 选区导出 —— DocumentSelection → SelectionData(plainText + 矩形 + 代码块语言)。
///
/// plainText 按 visualOrder 遍历各块,用映射表投影,块间加 `\n`(对齐
/// HtmlTextMapper 块级换行)。选区恰好覆盖单个代码块全部内容时带 language。
library;

import 'package:flutter/rendering.dart';

import '../flatten/soft_break.dart';
import 'selection_data.dart';
import 'projection.dart';
import 'selection_geometry.dart';
import 'selection_range.dart';
import 'selection_registry.dart';

class SelectionExporter {
  const SelectionExporter(this.registry);

  final SelectionRegistry registry;

  /// 选区为空 / collapsed / 无内容时返回 null。
  SelectionData? export(DocumentSelection? selection) {
    if (selection == null || selection.isCollapsed) return null;

    final ranges = expandSelection(registry, selection);
    if (ranges.isEmpty) return null;

    // 1. plainText:各块**逻辑 projection** 投影 + 块间 \n(回收块照样完整)。
    final buf = StringBuffer();
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      buf.write(r.projection.project(r.start, r.end));
      if (i != ranges.length - 1) buf.write('\n');
    }
    // 渲染层为长串软换行插的 U+200B(见 insertSoftBreaks)不属于内容,strip。
    final plainText = buf.toString().replaceAll(kSoftBreakChar, '');
    final copyText = ranges
        .map((r) => r.projection.project(r.start, r.end, forCopy: true))
        .join('\n')
        .replaceAll(kSoftBreakChar, '');
    if (copyText.isEmpty) return null;

    // 2. 高亮矩形(全局)+ 外接框 —— 只对**可见块**(live handle)算,滚出
    //    视口的块无几何(跳过,符合预期:看不见的不画)。被 keepAlive 保活但
    //    离屏的块 localToGlobal 可能出 NaN/Infinity → finite 过滤,避免污染
    //    外接框 / toolbar 定位崩。
    final globalRects = <Rect>[];
    for (final r in ranges) {
      final g = registry.byId(r.id)?.geometry;
      if (g == null) continue;
      final boxes = g.getBoxesForSelection(
        TextSelection(baseOffset: r.start, extentOffset: r.end),
      );
      for (final b in boxes) {
        final tl = g.renderBox.localToGlobal(Offset(b.left, b.top));
        final br = g.renderBox.localToGlobal(Offset(b.right, b.bottom));
        if (!tl.dx.isFinite ||
            !tl.dy.isFinite ||
            !br.dx.isFinite ||
            !br.dy.isFinite) {
          continue;
        }
        globalRects.add(Rect.fromPoints(tl, br));
      }
    }
    final bounds = globalRects.isEmpty
        ? Rect.zero
        : globalRects.reduce((a, b) => a.expandToInclude(b));

    // 3. 代码块语言(选区完全落单代码块)
    final code = _codeInfoIfSingleCodeBlock(ranges);

    return SelectionData(
      plainText: plainText,
      copyText: copyText,
      globalBounds: bounds,
      globalRects: globalRects,
      code: code,
    );
  }

  /// 选区**恰好覆盖单个代码块的全部内容**时才携带语言(复制包 ```lang)。
  /// 只选中块内部分文本时返回 null → 复制为纯文本,不追加 ```。
  CodeSelectionInfo? _codeInfoIfSingleCodeBlock(List<BlockRange> ranges) {
    if (ranges.length != 1) return null;
    final block = registry.logicalById(ranges.first.id);
    if (block == null || block.codeLanguage == null) return null;
    final r = ranges.first;
    final coversWholeBlock = r.start == 0 && r.end >= block.renderLength;
    if (!coversWholeBlock) return null;
    return CodeSelectionInfo(language: block.codeLanguage);
  }

  double _anchorHeight(BlockRange range, double height, {required bool start}) {
    final offset = start ? range.start : range.end - 1;
    final objectEdge = range.projection.entries.any(
      (e) =>
          (e.kind == ProjectionKind.image ||
              e.kind == ProjectionKind.blockObject) &&
          offset >= e.renderStart &&
          offset < e.renderEnd,
    );
    // Drag handles compensate by half a text line, never half an image height.
    return objectEdge ? height.clamp(0, 32) : height;
  }

  /// 按文档序返回选区两端点的 DocumentPosition(拖手柄时固定一端、动另一端)。
  /// visualStart = 视觉最前端点,visualEnd = 视觉最后端点。空选区返回 null。
  ({DocumentPosition visualStart, DocumentPosition visualEnd})?
  orderedEndpoints(DocumentSelection? selection) {
    if (selection == null) return null;
    final order = registry.orderedBlocks();
    if (order.isEmpty) return null;
    int idx(SelectableBlockId id) {
      for (var i = 0; i < order.length; i++) {
        if (order[i].id == id) return i;
      }
      return -1;
    }

    final bi = idx(selection.base.blockId);
    final ei = idx(selection.extent.blockId);
    if (bi < 0 || ei < 0) return null;
    final baseFirst =
        bi < ei ||
        (bi == ei &&
            selection.base.renderOffset <= selection.extent.renderOffset);
    return baseFirst
        ? (visualStart: selection.base, visualEnd: selection.extent)
        : (visualStart: selection.extent, visualEnd: selection.base);
  }

  /// 选区两端的全局锚点(给拖拽手柄实时定位用,**按当前 selection 随时重算**,
  /// 不复用松手快照)。
  /// - start = 选区视觉首 box 的**左下角**(左手柄贴这里)
  /// - end   = 选区视觉末 box 的**右下角**(右手柄贴这里)
  /// - startLineHeight / endLineHeight = 对应 box 高度(手柄尺寸/锚点按行高算)。
  ///
  /// **端点块滚出视口(被回收,无几何)时容忍**:跳过不可见端点,fallback 到
  /// 当前**可见 ranges** 的首/末 box(toolbar/手柄跟随可见部分,不返回 null
  /// 导致 toolbar 消失/定位崩)。全部端点都不可见时才返回 null。
  SelectionEndpoints? endpointAnchors(DocumentSelection? selection) {
    if (selection == null || selection.isCollapsed) return null;
    final ranges = expandSelection(registry, selection);
    if (ranges.isEmpty) return null;

    // 找首个**可见**range(其首 box 左下 = start)。
    _BoxAnchor? startAnchor;
    for (final r in ranges) {
      final g = registry.byId(r.id)?.geometry;
      if (g == null) continue;
      final boxes = g.getBoxesForSelection(
        TextSelection(baseOffset: r.start, extentOffset: r.end),
      );
      if (boxes.isEmpty) continue;
      final fb = boxes.first;
      final gp = g.renderBox.localToGlobal(Offset(fb.left, fb.bottom));
      if (!gp.dx.isFinite || !gp.dy.isFinite) continue; // 离屏保活块 NaN → 跳过
      startAnchor = _BoxAnchor(
        global: gp,
        lineHeight: _anchorHeight(r, fb.bottom - fb.top, start: true),
      );
      break;
    }

    // 找末个**可见**range(其末 box 右下 = end)。
    _BoxAnchor? endAnchor;
    for (final r in ranges.reversed) {
      final g = registry.byId(r.id)?.geometry;
      if (g == null) continue;
      final boxes = g.getBoxesForSelection(
        TextSelection(baseOffset: r.start, extentOffset: r.end),
      );
      if (boxes.isEmpty) continue;
      final lb = boxes.last;
      final gp = g.renderBox.localToGlobal(Offset(lb.right, lb.bottom));
      if (!gp.dx.isFinite || !gp.dy.isFinite) continue; // 离屏保活块 NaN → 跳过
      endAnchor = _BoxAnchor(
        global: gp,
        lineHeight: _anchorHeight(r, lb.bottom - lb.top, start: false),
      );
      break;
    }

    if (startAnchor == null || endAnchor == null) return null;

    return SelectionEndpoints(
      start: startAnchor.global,
      end: endAnchor.global,
      startLineHeight: startAnchor.lineHeight,
      endLineHeight: endAnchor.lineHeight,
    );
  }
}

/// 单个 box 锚点(全局点 + 行高)。
class _BoxAnchor {
  const _BoxAnchor({required this.global, required this.lineHeight});
  final Offset global;
  final double lineHeight;
}

/// 选区两端全局锚点 + 行高(手柄定位用)。
class SelectionEndpoints {
  const SelectionEndpoints({
    required this.start,
    required this.end,
    required this.startLineHeight,
    required this.endLineHeight,
  });

  /// 选区视觉起点(首 box 左下角,全局)。
  final Offset start;

  /// 选区视觉终点(末 box 右下角,全局)。
  final Offset end;

  final double startLineHeight;
  final double endLineHeight;
}
