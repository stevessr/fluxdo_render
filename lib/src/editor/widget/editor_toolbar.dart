/// 极简选区工具栏(M2):行内格式 + 块类型切换。
///
/// 形态:编辑器上方常驻按钮条(选区工具栏的浮动锚定留 M3 打磨 ——
/// M2 重点是命令链路;常驻条避免 Overlay/滚动联动的复杂度)。
/// 所有按钮 canRequestFocus: false(不抢编辑器焦点,否则点一下
/// 光标就没了 —— M1 踩过的坑)。
library;

import 'package:material_ui/material_ui.dart';

import '../model/editable_text_content.dart';
import '../model/editor_state.dart';

class EditorToolbar extends StatefulWidget {
  const EditorToolbar({super.key, required this.state});

  final EditorState state;

  @override
  State<EditorToolbar> createState() => _EditorToolbarState();
}

/// 工具栏关心的派生状态签名。**纯打字时签名不变 → 工具栏零重建**——
/// 10 个带 Tooltip(内部 OverlayPortal+MouseRegion)的按钮每键全量重建
/// 单项就 ~20ms,是打字卡顿的最大单一来源(JANK-PROF 实测)。
typedef _ToolbarSig = ({
  int marksBits,
  int kindIndex,
  int headingLevel,
  bool ordered,
  bool inQuote,
});

class _EditorToolbarState extends State<EditorToolbar> {
  late _ToolbarSig _sig = _compute();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void didUpdateWidget(covariant EditorToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onState);
      widget.state.addListener(_onState);
      _sig = _compute();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final next = _compute();
    if (next != _sig && mounted) {
      setState(() => _sig = next);
    }
  }

  _ToolbarSig _compute() {
    final state = widget.state;
    final marks = state.effectiveMarksAtCaret();
    final sel = state.selection;
    final block =
        sel == null ? null : state.textBlockById(sel.extent.blockId);
    return (
      marksBits: marks.fold(0, (a, k) => a | (1 << k.index)),
      kindIndex: block?.kind.index ?? -1,
      headingLevel: block?.isHeading == true ? block!.headingLevel : 0,
      ordered: block?.isListItem == true && block!.ordered,
      inQuote: (block?.quoteDepth ?? 0) > 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final marks = state.effectiveMarksAtCaret();
    final sel = state.selection;
    final block =
        sel == null ? null : state.textBlockById(sel.extent.blockId);

        return Wrap(
          spacing: 2,
          children: [
            _MarkButton(
              icon: Icons.format_bold,
              tooltip: '粗体 (Cmd+B)',
              active: marks.contains(MarkKind.strong),
              onPressed: () => state.toggleMark(MarkKind.strong),
            ),
            _MarkButton(
              icon: Icons.format_italic,
              tooltip: '斜体 (Cmd+I)',
              active: marks.contains(MarkKind.em),
              onPressed: () => state.toggleMark(MarkKind.em),
            ),
            _MarkButton(
              icon: Icons.strikethrough_s,
              tooltip: '删除线 (Cmd+Shift+X)',
              active: marks.contains(MarkKind.lineThrough),
              onPressed: () => state.toggleMark(MarkKind.lineThrough),
            ),
            _MarkButton(
              icon: Icons.code,
              tooltip: '行内代码 (Cmd+E)',
              active: marks.contains(MarkKind.inlineCode),
              onPressed: () => state.toggleMark(MarkKind.inlineCode),
            ),
            const SizedBox(width: 8),
            for (final level in [1, 2, 3])
              _MarkButton(
                label: 'H$level',
                tooltip: '标题 $level',
                active: block?.isHeading == true &&
                    block?.headingLevel == level,
                onPressed: () => state.toggleHeading(level),
              ),
            const SizedBox(width: 8),
            _MarkButton(
              icon: Icons.format_list_bulleted,
              tooltip: '无序列表',
              active: block?.isListItem == true && block?.ordered == false,
              onPressed: () => state.toggleList(ordered: false),
            ),
            _MarkButton(
              icon: Icons.format_list_numbered,
              tooltip: '有序列表',
              active: block?.isListItem == true && block?.ordered == true,
              onPressed: () => state.toggleList(ordered: true),
            ),
            _MarkButton(
              icon: Icons.format_quote,
              tooltip: '引用',
              active: (block?.quoteDepth ?? 0) > 0,
              onPressed: state.toggleQuote,
            ),
          ],
        );
  }
}

class _MarkButton extends StatefulWidget {
  const _MarkButton({
    this.icon,
    this.label,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  }) : assert(icon != null || label != null);

  final IconData? icon;
  final String? label;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  State<_MarkButton> createState() => _MarkButtonState();
}

class _MarkButtonState extends State<_MarkButton> {
  // 工具栏按钮不抢编辑器焦点(编辑器工具栏惯例)
  final FocusNode _focus = FocusNode(canRequestFocus: false, skipTraversal: true);

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final child = widget.icon != null
        ? Icon(widget.icon, size: 18)
        : Text(widget.label!,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600));
    return Tooltip(
      message: widget.tooltip,
      child: IconButton(
        focusNode: _focus,
        onPressed: widget.onPressed,
        icon: child,
        isSelected: widget.active,
        style: IconButton.styleFrom(
          minimumSize: const Size(34, 34),
          padding: EdgeInsets.zero,
          backgroundColor:
              widget.active ? scheme.primaryContainer : null,
          foregroundColor:
              widget.active ? scheme.onPrimaryContainer : scheme.onSurface,
        ),
      ),
    );
  }
}
