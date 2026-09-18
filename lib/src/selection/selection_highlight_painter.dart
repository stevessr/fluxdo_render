/// 单块选区高亮绘制 —— super_editor layerBeneath 式:每个 InlineSpanText 在
/// Text.rich 底下叠一层 CustomPaint,只画落在本块的选区矩形。
///
/// 选每块自绘而非顶层 overlay:表格 cell 横滚 + 虚拟化下天然正确(顶层 overlay
/// 会与横滚内容错位)。painter 监听 controller,选区落本块时用本块的
/// RenderParagraph.getBoxesForSelection 取矩形(本地坐标)直接画。
library;

import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/widgets.dart';

import 'selectable_block_handle.dart';
import 'block_text_geometry.dart';
import 'projection.dart';
import 'selection_geometry.dart';
import 'selection_range.dart';
import 'selection_registry.dart';

class SelectionHighlight extends StatelessWidget {
  const SelectionHighlight({
    super.key,
    required this.controller,
    required this.blockHandleGetter,
    required this.color,
    required this.child,
  });

  final SelectionController controller;

  /// 取本块 handle(InlineSpanText 注册的那个);null 时不画。
  final SelectableBlockHandle? Function() blockHandleGetter;

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 用 foregroundPainter(画在 child **上层**)而非 painter(下层):
    // emoji 图片 / mention chip / 内容图片是不透明的,画在文字层之上 —— 若高亮
    // 在下层会被它们完全盖住,占位符处看不到选中态。改画上层 + 半透明主题色
    // (selectionColor ~0.3 alpha)→ 文字和占位符都被涂一层选中色,范围连贯,
    // 内容仍透出可见(对齐系统选区思路)。
    return CustomPaint(
      foregroundPainter: _HighlightPainter(
        repaint: controller,
        registry: controller.registry,
        selectionOf: () => controller.selection,
        outlineOf: () => controller.outlineSelection,
        blockHandleGetter: blockHandleGetter,
        color: color,
      ),
      child: child,
    );
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required Listenable repaint,
    required this.registry,
    required this.selectionOf,
    required this.outlineOf,
    required this.blockHandleGetter,
    required this.color,
  }) : super(repaint: repaint);

  final SelectionRegistry registry;
  final DocumentSelectionGetter selectionOf;
  final bool Function() outlineOf;
  final SelectableBlockHandle? Function() blockHandleGetter;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final selection = selectionOf();
    if (selection == null || selection.isCollapsed) return;
    final handle = blockHandleGetter();
    if (handle == null) return;
    // 防御:仅当本 handle 是注册表当前为该 id 注册的那个时才画。万一出现同 id
    // 双块(如分块重建/回收的瞬态),只有 _live 里的那个画高亮(与命中测试用的
    // 同一个)→ 杜绝「另一段也亮」的重影。
    if (!identical(registry.byId(handle.id), handle)) return;
    final geometry = handle.geometry;
    if (geometry == null) return;

    // 找本块在选区里的渲染偏移区间。
    final ranges = expandSelection(registry, selection);
    BlockRange? mine;
    for (final r in ranges) {
      if (r.id == handle.id) {
        mine = r;
        break;
      }
    }
    if (mine == null || mine.isEmpty) return;

    // BoxHeightStyle.max:每个 box 取**整行固有最大高度**(含该行最高字形/emoji),
    // **与选中了哪些字无关** —— 这是修「先矮后高」的关键:同行字符高度本就参差
    // (实测 14/16/20),若用 tight 各 box 真实高度 + union,选区往左右扩纳入更高
    // box 时整条会逐步变高;max 让行高恒定,扩选不跳变。
    // 跨行不误并:max 让相邻行 box 紧贴(非重叠),mergeSelectionBoxesByLine 的
    // 「重叠过半」阈值挡住(实测窄宽 5 行 → 仍 5 个独立矩形,不合并)。
    final outline = outlineOf();
    final rects = selectionHighlightRects(geometry, mine, tight: outline);
    if (rects.isEmpty) return;

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;
    if (outline) {
      paint.color = color.withValues(alpha: .16);
    }
    // 同行 box 合并成统一高度矩形:同一行内 emoji(偏高)与文字 box 取 union,
    // 整行等高(防 emoji 处参差);tight 间隙保证不跨行。
    for (final rowRect in rects) {
      if (outline) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rowRect, const Radius.circular(4)),
          paint,
        );
      } else {
        canvas.drawRect(rowRect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.color != color ||
      old.selectionOf != selectionOf ||
      old.registry != registry;
}

typedef DocumentSelectionGetter = DocumentSelection? Function();

/// 把 getBoxesForSelection 返回的 box 按「行」分组,每行合并成一个矩形:
/// 同行 box 取 union(水平铺满该行左到右,去相邻 box 亚像素缝隙)。
///
/// 同行判定用「垂直重叠**过半**」:相邻行 box 仅紧贴(重叠≈0)不会被误判同行,
/// 即使喂 BoxHeightStyle.max(相邻行紧贴)也绝不跨行合并(实测窄宽 5 行仍 5 个
/// 独立矩形)。配合 max(行高与选区无关)修「先矮后高」。
List<Rect> mergeSelectionBoxesByLine(List<TextBox> boxes) {
  final rows = <List<Rect>>[];
  for (final b in boxes) {
    final r = b.toRect();
    if (r.width == 0 && r.height == 0) continue;
    bool placed = false;
    for (final row in rows) {
      final ref = row.first;
      // 同行判定:垂直区间有「实质」重叠(过半),避免行间 1px 误触。
      final overlap =
          (r.bottom < ref.bottom ? r.bottom : ref.bottom) -
          (r.top > ref.top ? r.top : ref.top);
      final minH = (r.height < ref.height ? r.height : ref.height);
      if (overlap > minH * 0.5) {
        row.add(r);
        placed = true;
        break;
      }
    }
    if (!placed) rows.add([r]);
  }

  final result = <Rect>[];
  for (final row in rows) {
    var rect = row.first;
    for (final r in row.skip(1)) {
      rect = rect.expandToInclude(r);
    }
    result.add(rect);
  }
  return result;
}

/// Images have their own silhouette. Never union a tall image with neighbouring
/// text into a paragraph-sized rectangle, or let it inflate text-only selection.
List<Rect> selectionHighlightRects(
  BlockTextGeometry geometry,
  BlockRange range, {
  bool tight = false,
}) {
  final images = range.projection.entries
      .where((e) => e.kind == ProjectionKind.image)
      .toList();
  if (images.isEmpty) {
    return mergeSelectionBoxesByLine(
      geometry.getBoxesForSelection(
        TextSelection(baseOffset: range.start, extentOffset: range.end),
        boxHeightStyle: tight ? BoxHeightStyle.tight : BoxHeightStyle.max,
      ),
    );
  }
  final textBoxes = <TextBox>[];
  final imageRects = <Rect>[];
  var cursor = range.start;
  void addText(int start, int end) {
    if (start >= end) return;
    textBoxes.addAll(
      geometry.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      ),
    );
  }

  for (final image in images) {
    if (image.renderEnd <= range.start || image.renderStart >= range.end) {
      continue;
    }
    addText(cursor, image.renderStart);
    imageRects.addAll(
      geometry
          .getBoxesForSelection(
            TextSelection(
              baseOffset: image.renderStart,
              extentOffset: image.renderEnd,
            ),
          )
          .map((box) => box.toRect()),
    );
    cursor = image.renderEnd;
  }
  addText(cursor, range.end);
  return [...mergeSelectionBoxesByLine(textBoxes), ...imageRects];
}
