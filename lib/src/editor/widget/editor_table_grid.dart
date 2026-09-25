/// 表格岛的编辑态渲染(M5):cell 单击原位编辑 + Notion 式行列操作。
///
/// 替换通用 EditorIsland 的 AbsorbPointer 只读渲染 —— 表格是"结构化
/// 数据",cell 级直改比源码/对话框顺手一个量级:
/// - 自绘轻量表格(边框/表头底色对齐阅读端 table_builder 视觉);
/// - 单击 cell → cell 原位变 TextField(markdown 源码口径,富格式保留),
///   编辑态 primary 描边高亮;非编辑 cell hover 淡底提示可点;
/// - 行列操作(Notion 式):hover 行 → 左缘行柄,hover 列 → 顶缘列柄,
///   点柄弹菜单(前/后插入、删除);表格右缘/下缘 hover 出 [+] 加条;
/// - 提交(回车/失焦)→ 回调宿主重建 markdown → replaceIsland。
///
/// cell 内容口径 = tableCellToMarkdown(单行 markdown 文本;`**粗**`
/// 等富格式以源码显示,cook 后还原 —— 不丢格式)。
library;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;

import '../../node/node.dart';
import 'editor_table_actions.dart';
import '../model/markdown_serializer.dart';

/// 编辑器自管交互区的命中标记(MetaData.metaData):FluxdoEditor 的
/// tap/pan 手势命中带此标记的子树时完全让路 —— 区域内的焦点/光标/
/// 输入由子组件(表格 cell TextField)自己管,编辑器不抢焦点、不设
/// 选区、不弹 IME(否则双光标)。
const Object kEditorSelfManagedRegion = _SelfManagedRegionTag();

class _SelfManagedRegionTag {
  const _SelfManagedRegionTag();
}

/// 孤岛区域命中标记(EditorIsland 打标):长按选词让路用 —— 岛不注册
/// RenderParagraph,positionAt 的最近块兜底会把岛上的长按吸到邻段文本
/// 选词。tap/整选不受影响(岛自己的 GestureDetector 处理)。
const Object kEditorIslandRegion = _IslandRegionTag();

class _IslandRegionTag {
  const _IslandRegionTag();
}

/// 单 cell 宽度(整表统一;编辑态同宽防跳动)。
const double _kCellWidth = 132.0;

/// 行柄/列柄的厚度。
const double _kHandleThickness = 14.0;

/// 表格编辑网格。所有结构变更(改 cell/增删行列/表头开关)统一走
/// [onChanged](完整 markdown 表格文本)—— 宿主经 cook 链路替换岛。
class EditorTableGrid extends StatefulWidget {
  const EditorTableGrid({
    super.key,
    required this.node,
    required this.onChanged,
    this.onNodeChanged,
    this.selected = false,
    this.autoEdit = false,
    this.onSelectRequest,
    this.onContextMenu,
    this.onEditingRectChanged,
    this.onEditingContextChanged,
    this.commitEditing,
    this.tableId,
    this.structureControlsBuilder,
    this.onStructureMenuRequested,
  });

  final TableNode node;

  /// 变更后的 markdown 表格文本(cook → replaceIsland 由宿主做)。
  final ValueChanged<String> onChanged;

  /// 结构操作直传来源，避免 Markdown 往返丢失行、单元格属性。
  final ValueChanged<TableNode>? onNodeChanged;

  /// 整选态(编辑器选区恰覆盖本表格块):primary 描边。
  final bool selected;
  final bool autoEdit;

  /// 左上角选择柄点击 → 编辑器整选本表格块(选中后退格/Delete 删整表;
  /// cell 区自管让路后这是块级选择的唯一入口)。
  final VoidCallback? onSelectRequest;
  final VoidCallback? onContextMenu;

  /// 当前聚焦编辑框的全局矩形。表格只上报几何，不自行判断视口或滚动；
  /// 宿主 FluxdoEditor 复用正文光标同一套 reveal 策略处理。
  final ValueChanged<({(int, int) cell, Rect rect})?>? onEditingRectChanged;

  final String? tableId;
  final Widget Function(BuildContext, (int, int)?, void Function(bool, Rect))?
  structureControlsBuilder;
  final Future<void> Function(bool row, Rect anchor)? onStructureMenuRequested;

  final ValueChanged<EditorTableContext?>? onEditingContextChanged;
  final Future<bool> Function(String markdown)? commitEditing;

  @override
  State<EditorTableGrid> createState() => _EditorTableGridState();
}

class _EditorTableGridState extends State<EditorTableGrid>
    with WidgetsBindingObserver
    implements TextSelectionGestureDetectorBuilderDelegate {
  late List<List<String>> _cells;
  late bool _hasHeader;
  late List<TextAlign?> _alignments;

  /// 正在编辑的 cell(row, col);null = 无。
  (int, int)? _editing;
  final Set<String> _pendingEchoes = {};
  VoidCallback? _pendingStructure;
  final TextEditingController _cellController = TextEditingController();
  final FocusNode _cellFocus = FocusNode();

  /// 编辑框句柄:编辑框随格切换在 cell 槽位间重建(共享
  /// controller/focusNode),新实例挂载时焦点已在 —— 无焦点事件、键盘
  /// 令牌已被上一格消费，不会自动 attach IME 连接(键盘看着在，打字
  /// 全无效果，再点一下编辑框本体触发 requestKeyboard 才恢复)。切格
  /// 后主动 requestKeyboard 补上；用裸 EditableText 才拿得到这个
  /// state(TextField 的内部句柄私有)。
  final GlobalKey<EditableTextState> _cellFieldKey =
      GlobalKey<EditableTextState>();

  /// 编辑框手势装配:裸 EditableText 没有任何手势处理(tap 落光标/
  /// 长按划词+拖选/双击选词/鼠标拖选全无),Flutter 的设计是把这套
  /// 交给 TextSelectionGestureDetectorBuilder 包裹 —— TextField 正是
  /// 这么做的。不接的话编辑态无法划词、双击无效。
  late final _cellGestureBuilder = TextSelectionGestureDetectorBuilder(
    delegate: this,
  );

  @override
  GlobalKey<EditableTextState> get editableTextKey => _cellFieldKey;

  @override
  bool get forcePressEnabled => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  bool get selectionEnabled => true;

  bool _hoverGrid = false;

  /// 当前 hover 的行/列(边缘柄显隐)。
  int? _hoverRow;
  int? _hoverCol;

  /// 触屏(无鼠标)设备:hover 永远不会发生 —— 行/列柄、加条改为
  /// 「cell 编辑态或表格整选态」常显(手机上此前全部隐身,加行加列
  /// 完全没有入口)。有鼠标设备保持 hover 交互不变。
  static bool get _hoverCapable =>
      RendererBinding.instance.mouseTracker.mouseIsConnected;

  /// 柄/加条的"活跃"判定:桌面 = hover;触屏 = 编辑/选中态常显。
  bool get _mobileManaged =>
      !_hoverCapable && widget.onEditingContextChanged != null;
  double get _handleInset => _mobileManaged ? 0 : _kHandleThickness + 2;

  bool get _handlesActive =>
      _hoverGrid || (!_hoverCapable && (_editing != null || widget.selected));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncFromNode();
    if (widget.autoEdit) _scheduleFirstCell();
    _cellFocus.addListener(_onCellFocusChanged);
    _cellController.addListener(_editingChanged);
  }

  void _onCellFocusChanged() {
    if (_cellFocus.hasFocus) {
      _scheduleEditingRectReport();
    } else {
      _commitCell();
    }
  }

  @override
  void didUpdateWidget(covariant EditorTableGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 键盘/工具栏动画期间布局逐帧变化，持续向宿主上报新矩形。
    if (_editing != null && _cellFocus.hasFocus) {
      _scheduleEditingRectReport();
    }
    if (widget.autoEdit && !oldWidget.autoEdit) _scheduleFirstCell();
    if (oldWidget.node != widget.node) {
      // 显式提交由宿主验证旧节点身份；格式规范化可能改变 Markdown，
      // 不能仅靠字符串相等识别这次已确认的回写。
      if (_awaitingCommitEcho) {
        _pendingEchoes.clear();
        _syncFromNode();
        return;
      }
      final echo = tableGridToMarkdown(
        [
          for (final row in widget.node.rows)
            [for (final cell in row) tableCellToMarkdown(cell)],
        ],
        hasHeader: widget.node.hasHeader,
        alignments: [
          for (var c = 0; c < widget.node.columnCount; c++)
            widget.node.rows.isNotEmpty && c < widget.node.rows.first.length
                ? widget.node.rows.first[c].alignment
                : null,
        ],
      );
      // 本地提交的异步回声不清空当前编辑格，更不能覆盖下一格未提交文字。
      if (_pendingEchoes.remove(echo)) {
        final action = _pendingStructure;
        if (action != null && _pendingEchoes.isEmpty) {
          _pendingStructure = null;
          _syncFromNode();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) action();
          });
        }
        return;
      }
      _pendingStructure = null;
      _pendingEchoes.clear();
      _editing = null;
      widget.onEditingRectChanged?.call(null);
      if (!_structureBusy) _publishContext(clear: true);
      _revision++;
      _syncFromNode();
    }
  }

  void _scheduleFirstCell() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing == null && _rows > 0 && _cols > 0) {
        _startEdit(0, 0);
      }
    });
  }

  void _syncFromNode() {
    final n = widget.node;
    _hasHeader = n.hasHeader;
    _alignments = List.generate(
      n.columnCount,
      (c) => n.rows.isNotEmpty && c < n.rows.first.length
          ? n.rows.first[c].alignment
          : null,
    );
    _cells = [
      for (final row in n.rows)
        [
          for (var c = 0; c < n.columnCount; c++)
            c < row.length ? tableCellToMarkdown(row[c]) : '',
        ],
    ];
    if (_cells.isEmpty) {
      _cells = [
        [''],
      ];
    }
  }

  void _scheduleEditingRectReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editing == null || !_cellFocus.hasFocus) return;
      final renderObject = _cellFieldKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        return;
      }
      _publishContext();
      widget.onEditingRectChanged?.call((
        cell: _editing!,
        rect: renderObject.localToGlobal(Offset.zero) & renderObject.size,
      ));
    });
  }

  @override
  void didChangeMetrics() {
    if (_editing != null && _cellFocus.hasFocus) {
      _scheduleEditingRectReport();
    }
  }

  @override
  void dispose() {
    widget.onEditingContextChanged?.call(null);
    widget.onEditingRectChanged?.call(null);
    if (!_structureBusy) _publishContext(clear: true);
    WidgetsBinding.instance.removeObserver(this);
    _cellFocus.removeListener(_onCellFocusChanged);
    _cellController.removeListener(_editingChanged);
    _cellController.dispose();
    _cellFocus.dispose();
    super.dispose();
  }

  int get _rows => _cells.length;
  int get _cols => _cells.isEmpty ? 0 : _cells.first.length;

  void _emit() {
    final markdown = tableGridToMarkdown(
      _cells,
      hasHeader: _hasHeader,
      alignments: _alignments,
    );
    _pendingEchoes.add(markdown);
    widget.onChanged(markdown);
  }

  // -----------------------------------------------------------------
  // cell 编辑
  // -----------------------------------------------------------------

  void _startEdit(int r, int c) {
    _commitCell();
    setState(() {
      _editing = (r, c);
      _cellController.text = _cells[r][c];
      // 触屏:折叠光标落在文末 —— 有光标可见、打字追加而非替换、
      // 长按/双击可选词(程序化全选在移动端既无光标也不带出选择
      // 手柄,还让首字直接覆盖整格)。鼠标:维持点击全选(桌面
      // 覆盖输入快捷路径,选区高亮清晰可见)。
      _cellController.selection = _hoverCapable
          ? TextSelection(baseOffset: 0, extentOffset: _cells[r][c].length)
          : TextSelection.collapsed(offset: _cells[r][c].length);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editing != (r, c)) return;
      _cellFocus.requestFocus();
      // 补挂 IME 连接:requestKeyboard 已持焦点时直接 attach+show(无需
      // 键盘令牌),未持焦点时走 requestFocus 正常聚焦路径。
      _cellFieldKey.currentState?.requestKeyboard();
      // 向宿主上报编辑框几何，由 FluxdoEditor 复用正文 reveal 策略。
      _scheduleEditingRectReport();
    });
  }

  void _commitCell() {
    final e = _editing;
    if (e == null) return;
    final (r, c) = e;
    final next = _cellController.text;
    _editing = null;
    widget.onEditingRectChanged?.call(null);
    if (!_structureBusy) _publishContext(clear: true);
    if (r < _rows && c < _cols && _cells[r][c] != next) {
      _cells[r][c] = next;
      _emit();
    } else if (mounted) {
      setState(() {});
    }
  }

  int _revision = 0;
  bool _structureBusy = false;
  bool? _highlightRow;
  (int, int)? _highlightCell;

  Future<void> _openStructureMenu(bool row, Rect anchor) async {
    if (_editing == null || _structureBusy || _highlightRow != null) return;
    setState(() {
      _highlightRow = row;
      _highlightCell = _editing;
    });
    try {
      await widget.onStructureMenuRequested?.call(row, anchor);
    } finally {
      if (mounted) {
        setState(() {
          _highlightRow = null;
          _highlightCell = null;
        });
      }
    }
  }

  bool _awaitingCommitEcho = false;
  (int, int)? _operationCell;

  void _editingChanged() {
    _revision++;
    _publishContext();
  }

  void _publishContext({bool clear = false}) {
    final cell = _editing ?? _operationCell;
    final revision = _revision;
    if (clear || cell == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_structureBusy && _editing == null) {
          widget.onEditingContextChanged?.call(null);
        }
      });
      return;
    }
    final (r, c) = cell;
    if (r >= _rows || c >= _cols) return;
    String value(int row, int col) =>
        _editing == (row, col) ? _cellController.text : _cells[row][col];
    final context = EditorTableContext(
      tableId: widget.tableId ?? widget.node.id,
      cell: cell,
      revision: revision,
      rows: _rows,
      columns: _cols,
      rowHasContent: List.generate(
        _cols,
        (i) => value(r, i),
      ).any((v) => v.trim().isNotEmpty),
      columnHasContent: List.generate(
        _rows,
        (i) => value(i, c),
      ).any((v) => v.trim().isNotEmpty),
      busy: _structureBusy,
      execute: (action) => _executeAction(action, cell, revision),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          revision == _revision &&
          (_editing ?? _operationCell) == cell) {
        widget.onEditingContextChanged?.call(context);
      }
    });
  }

  Future<EditorTableActionResult> _executeAction(
    EditorTableAction action,
    (int, int) cell,
    int revision,
  ) async {
    if (!mounted || revision != _revision || _editing != cell) {
      return EditorTableActionResult.stale;
    }
    if (_structureBusy ||
        widget.onNodeChanged == null ||
        widget.commitEditing == null) {
      return EditorTableActionResult.unavailable;
    }
    final (r, c) = cell;
    if ((action == EditorTableAction.deleteRow && _rows <= 1) ||
        (action == EditorTableAction.deleteColumn && _cols <= 1)) {
      return EditorTableActionResult.unavailable;
    }
    setState(() => _structureBusy = true);
    _operationCell = cell;
    _publishContext();
    final text = _cellController.text;
    try {
      if (_cells[r][c] != text) {
        final cells = [for (final row in _cells) List<String>.of(row)];
        cells[r][c] = text;
        final markdown = tableGridToMarkdown(
          cells,
          hasHeader: _hasHeader,
          alignments: _alignments,
        );
        _pendingEchoes.add(markdown);
        final accepted = await widget.commitEditing!(markdown);
        if (!mounted) return EditorTableActionResult.stale;
        if (!accepted) {
          _pendingEchoes.remove(markdown);
          return EditorTableActionResult.failed;
        }
        _awaitingCommitEcho = true;
        await WidgetsBinding.instance.endOfFrame;
        _awaitingCommitEcho = false;
        if (!mounted || _editing != cell || _cellController.text != text) {
          return EditorTableActionResult.stale;
        }
        _syncFromNode();
      }
      _editing = null;
      final target = switch (action) {
        EditorTableAction.rowBefore => (r, c),
        EditorTableAction.rowAfter => (r + 1, c),
        EditorTableAction.columnBefore => (r, c),
        EditorTableAction.columnAfter => (r, c + 1),
        EditorTableAction.deleteRow => (r.clamp(0, _rows - 2), c),
        EditorTableAction.deleteColumn => (r, c.clamp(0, _cols - 2)),
      };
      switch (action) {
        case EditorTableAction.rowBefore:
          _insertRow(r);
        case EditorTableAction.rowAfter:
          _insertRow(r + 1);
        case EditorTableAction.columnBefore:
          _insertCol(c);
        case EditorTableAction.columnAfter:
          _insertCol(c + 1);
        case EditorTableAction.deleteRow:
          _removeRow(r);
        case EditorTableAction.deleteColumn:
          _removeCol(c);
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return EditorTableActionResult.stale;
      _startEdit(target.$1, target.$2);
      return EditorTableActionResult.success;
    } catch (_) {
      return EditorTableActionResult.failed;
    } finally {
      _awaitingCommitEcho = false;
      _structureBusy = false;
      _operationCell = null;
      if (mounted) {
        setState(() {});
        _publishContext();
      }
    }
  }

  // -----------------------------------------------------------------
  // 行列结构操作
  // -----------------------------------------------------------------

  void _changeStructure(
    void Function(List<List<TableCellData>>, List<String?>) change,
  ) {
    final node = widget.node;
    final rows = [for (final row in node.rows) List<TableCellData>.of(row)];
    final ids = List<String?>.generate(
      rows.length,
      (r) => r < node.rowSourceIds.length ? node.rowSourceIds[r] : null,
    );
    change(rows, ids);
    widget.onNodeChanged!(
      TableNode(
        id: node.id,
        rows: rows,
        rowSourceIds: ids,
        columnCount: rows.fold<int>(0, (n, r) => r.length > n ? r.length : n),
        hasHeader: rows.isNotEmpty && rows.first.every((c) => c.isHeader),
        textAlign: node.textAlign,
      ),
    );
  }

  TableCellData _emptyCell({bool header = false}) => TableCellData(
    isHeader: header,
    children: [ParagraphNode(id: '${widget.node.id}-new', inlines: const [])],
  );

  void _insertRow(int at) {
    _commitCell();
    // 等待行内 Markdown 回写完成，不能让旧尺寸异步回声覆盖结构操作。
    if (widget.onNodeChanged != null && _pendingEchoes.isNotEmpty) {
      _pendingStructure = () => _insertRow(at);
      return;
    }
    if (widget.onNodeChanged != null) {
      _changeStructure((rows, ids) {
        final i = at.clamp(0, rows.length);
        rows.insert(
          i,
          List.generate(widget.node.columnCount, (_) => _emptyCell()),
        );
        ids.insert(i, null);
      });
      return;
    }
    _cells.insert(at.clamp(0, _rows), List.filled(_cols, ''));
    _emit();
  }

  void _insertCol(int at) {
    _commitCell();
    // 等待行内 Markdown 回写完成，不能让旧尺寸异步回声覆盖结构操作。
    if (widget.onNodeChanged != null && _pendingEchoes.isNotEmpty) {
      _pendingStructure = () => _insertCol(at);
      return;
    }
    if (widget.onNodeChanged != null) {
      _changeStructure((rows, ids) {
        for (final row in rows) {
          row.insert(
            at.clamp(0, row.length),
            _emptyCell(header: row.isNotEmpty && row.every((c) => c.isHeader)),
          );
        }
      });
      return;
    }
    final i = at.clamp(0, _cols);
    _alignments.insert(i, null);
    for (final row in _cells) {
      row.insert(i, '');
    }
    _emit();
  }

  void _removeRow(int r) {
    if (_rows <= 1) return;
    _commitCell();
    // 等待行内 Markdown 回写完成，不能让旧尺寸异步回声覆盖结构操作。
    if (widget.onNodeChanged != null && _pendingEchoes.isNotEmpty) {
      _pendingStructure = () => _removeRow(r);
      return;
    }
    if (widget.onNodeChanged != null) {
      _changeStructure((rows, ids) {
        rows.removeAt(r);
        ids.removeAt(r);
      });
      return;
    }
    _cells.removeAt(r);
    _emit();
  }

  void _removeCol(int c) {
    if (_cols <= 1) return;
    _commitCell();
    // 等待行内 Markdown 回写完成，不能让旧尺寸异步回声覆盖结构操作。
    if (widget.onNodeChanged != null && _pendingEchoes.isNotEmpty) {
      _pendingStructure = () => _removeCol(c);
      return;
    }
    if (widget.onNodeChanged != null) {
      _changeStructure((rows, ids) {
        for (final row in rows) {
          if (c < row.length) row.removeAt(c);
        }
      });
      return;
    }
    _alignments.removeAt(c);
    for (final row in _cells) {
      row.removeAt(c);
    }
    _emit();
  }

  /// 行柄菜单。
  Future<void> _showRowMenu(int r, Offset globalPos) async {
    final action = await _showHandleMenu(globalPos, [
      (Icons.arrow_upward_rounded, '上方插入行', 'above'),
      (Icons.arrow_downward_rounded, '下方插入行', 'below'),
      if (_rows > 1) (Icons.delete_outline_rounded, '删除此行', 'delete'),
    ]);
    switch (action) {
      case 'above':
        _insertRow(r);
      case 'below':
        _insertRow(r + 1);
      case 'delete':
        _removeRow(r);
    }
  }

  /// 列柄菜单。
  Future<void> _showColMenu(int c, Offset globalPos) async {
    final action = await _showHandleMenu(globalPos, [
      (Icons.arrow_back_rounded, '左侧插入列', 'left'),
      (Icons.arrow_forward_rounded, '右侧插入列', 'right'),
      if (_cols > 1) (Icons.delete_outline_rounded, '删除此列', 'delete'),
    ]);
    switch (action) {
      case 'left':
        _insertCol(c);
      case 'right':
        _insertCol(c + 1);
      case 'delete':
        _removeCol(c);
    }
  }

  Future<String?> _showHandleMenu(
    Offset globalPos,
    List<(IconData, String, String)> items,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        globalPos.dx + 1,
        globalPos.dy + 1,
      ),
      // 编辑器浮层统一规格:圆角 12 + 细边框 + 浮层底(composer 的
      // 斜杠/插入菜单同款)
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      color: scheme.surfaceContainerLow,
      items: [
        for (final (icon, label, value) in items)
          PopupMenuItem<String>(
            value: value,
            height: 38,
            child: Row(
              children: [
                Icon(icon, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Text(label, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
      ],
    );
  }

  // -----------------------------------------------------------------
  // build
  // -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    final borderColor = scheme.outlineVariant.withValues(alpha: 0.6);
    // cells 区总宽(固定 cell 宽 + 列分隔线),外框覆盖层同宽
    final tableWidth = _cols * _kCellWidth + (_cols - 1);

    // 行区:每行 = 行柄 + cells(cells 只画分隔线;外框与圆角由
    // 覆盖层统一画 —— 逐行画外框会丢圆角)。
    final rowsArea = Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var r = 0; r < _rows; r++)
              _buildRow(r, scheme, textStyle, borderColor),
          ],
        ),
        // 圆角外框覆盖层(只描边不拦事件;选中态 primary 加粗)
        Positioned(
          left: _handleInset,
          top: 0,
          bottom: 0,
          width: tableWidth,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: widget.selected ? scheme.primary : borderColor,
                  width: widget.selected ? 2 : 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    // 主体 = 列柄条(顶) + [行区 + 右加列条] + 下加行条。
    // 全部在 MetaData 自管区内;块级选择柄单独在区外。
    final body = MetaData(
      metaData: kEditorSelfManagedRegion,
      behavior: HitTestBehavior.opaque,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部列柄条(hover 表格淡显全部,hover 该列高亮)
            if (!_mobileManaged)
              Padding(
                padding: EdgeInsets.only(left: _handleInset),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var c = 0; c < _cols; c++)
                      _ColHandle(
                        opacity: !_handlesActive
                            ? 0
                            : (_hoverCol == c ? 1.0 : 0.35),
                        width: _kCellWidth + (c > 0 ? 1 : 0),
                        onTapDown: (pos) => _showColMenu(c, pos),
                        onHover: (h) =>
                            setState(() => _hoverCol = h ? c : null),
                      ),
                  ],
                ),
              ),
            // IntrinsicHeight:stretch 的右缘加列条随表格高(Column 的
            // 无界高约束下 stretch 会要求无限高 → 布局崩)
            IntrinsicHeight(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  rowsArea,
                  // 右缘加列条
                  if (!_mobileManaged)
                    _EdgeAddBar(
                      axis: Axis.vertical,
                      visible: _handlesActive,
                      tooltip: '添加列',
                      onTap: () => _insertCol(_cols),
                    ),
                ],
              ),
            ),
            // 下缘加行条
            if (!_mobileManaged)
              Padding(
                padding: EdgeInsets.only(left: _handleInset),
                child: _EdgeAddBar(
                  axis: Axis.horizontal,
                  visible: _handlesActive,
                  tooltip: '添加行',
                  length: tableWidth,
                  onTap: () => _insertRow(_rows),
                ),
              ),
          ],
        ),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hoverGrid = true),
      onExit: (_) => setState(() {
        _hoverGrid = false;
        _hoverRow = null;
        _hoverCol = null;
      }),
      child: widget.onContextMenu != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_mobileManaged && widget.structureControlsBuilder != null)
                  MetaData(
                    metaData: kEditorSelfManagedRegion,
                    child: TextFieldTapRegion(
                      child: widget.structureControlsBuilder!(
                        context,
                        _editing,
                        _openStructureMenu,
                      ),
                    ),
                  )
                else
                  MetaData(
                    metaData: kEditorSelfManagedRegion,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () {
                          widget.onSelectRequest?.call();
                          widget.onContextMenu!();
                        },
                        icon: const Icon(Icons.more_horiz_rounded, size: 20),
                        label: const Text('表格操作'),
                      ),
                    ),
                  ),
                body,
              ],
            )
          : Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(padding: const EdgeInsets.only(top: 4), child: body),
                // 左上角块级选择柄(hover 或已选中显示;在 MetaData 外 ——
                // 点击走编辑器整选,选中后退格删整表)
                if (widget.onSelectRequest != null &&
                    (_handlesActive || widget.selected))
                  Positioned(
                    left: -2,
                    top: -6,
                    child: Material(
                      type: MaterialType.transparency,
                      child: Tooltip(
                        message: '选中表格(选中后退格删除)',
                        child: InkWell(
                          onTap: widget.onSelectRequest,
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: widget.selected
                                  ? scheme.primary
                                  : scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: widget.selected
                                    ? scheme.primary
                                    : scheme.outlineVariant,
                              ),
                            ),
                            child: Icon(
                              Icons.drag_indicator,
                              size: 12,
                              color: widget.selected
                                  ? scheme.onPrimary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildRow(
    int r,
    ColorScheme scheme,
    TextStyle? textStyle,
    Color borderColor,
  ) {
    final isHeader = _hasHeader && r == 0;
    // cells 容器只管:表头/选中底色、行间分隔线、首末行内侧圆角裁剪
    // (外框+圆角描边由覆盖层统一画,见 build 的 rowsArea)。
    final radius = BorderRadius.vertical(
      top: r == 0 ? const Radius.circular(8) : Radius.zero,
      bottom: r == _rows - 1 ? const Radius.circular(8) : Radius.zero,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverRow = r),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_mobileManaged)
              _RowHandle(
                opacity: !_handlesActive ? 0 : (_hoverRow == r ? 1.0 : 0.35),
                onTapDown: (pos) => _showRowMenu(r, pos),
                onHover: (h) => setState(() => _hoverRow = h ? r : null),
              ),
            if (!_mobileManaged) const SizedBox(width: 2),
            ClipRRect(
              borderRadius: radius,
              child: Container(
                decoration: BoxDecoration(
                  color: isHeader
                      ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
                      : (widget.selected
                            ? scheme.primary.withValues(alpha: 0.06)
                            : null),
                  border: r > 0
                      ? Border(top: BorderSide(color: borderColor))
                      : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var c = 0; c < _cols; c++)
                      Container(
                        decoration: c > 0
                            ? BoxDecoration(
                                border: Border(
                                  left: BorderSide(color: borderColor),
                                ),
                              )
                            : null,
                        child: ColoredBox(
                          color:
                              _highlightCell != null &&
                                  (_highlightRow == true
                                      ? r == _highlightCell!.$1
                                      : c == _highlightCell!.$2)
                              ? scheme.primary.withValues(alpha: .16)
                              : Colors.transparent,
                          child: _buildCell(r, c, isHeader, textStyle, scheme),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCell(
    int r,
    int c,
    bool isHeader,
    TextStyle? textStyle,
    ColorScheme scheme,
  ) {
    final style = (textStyle ?? const TextStyle()).copyWith(
      fontSize: 13,
      fontWeight: isHeader ? FontWeight.w600 : FontWeight.w400,
    );

    if (_editing == (r, c)) {
      // 编辑态:primary 描边框住整个 cell，焦点一目了然。用裸
      // EditableText 而非 TextField:本格样式无任何 decoration，且需要
      // 持有 EditableTextState(见 _cellFieldKey 注释)。
      return Container(
        width: _kCellWidth,
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.primary, width: 1.5),
          color: scheme.primaryContainer.withValues(alpha: 0.15),
        ),
        child: _cellGestureBuilder.buildGestureDetector(
          behavior: HitTestBehavior.translucent,
          child: EditableText(
            key: _cellFieldKey,
            controller: _cellController,
            focusNode: _cellFocus,
            // 关键:关掉 RenderEditable 自带的 tap/long-press 识别器,
            // 手势全部让给外层 detector 的 TapAndHorizontalDrag ——
            // 否则自识别器永远赢下 tap 竞技场,连续 tap 计数无法跨
            // tap 累计,双击选词永远无法触发(TextField 同款做法)。
            rendererIgnoresPointer: true,
            style: style,
            cursorHeight: 15,
            cursorColor: scheme.primary,
            backgroundCursorColor: scheme.primary.withValues(alpha: 0.3),
            selectionColor: scheme.primary.withValues(alpha: 0.3),
            textAlign: c < _alignments.length
                ? _alignments[c] ?? TextAlign.start
                : TextAlign.start,
            mouseCursor: SystemMouseCursors.text,
            selectionControls: materialTextSelectionControls,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _commitCell(),
          ),
        ),
      );
    }

    final text = _cells[r][c];
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverCol = c),
      child: InkWell(
        onTap: () => _startEdit(r, c),
        hoverColor: scheme.primary.withValues(alpha: 0.05),
        child: Container(
          width: _kCellWidth,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Text(
            text.isEmpty ? ' ' : text,
            textAlign: c < _alignments.length
                ? _alignments[c] ?? TextAlign.start
                : TextAlign.start,
            style: text.isEmpty
                ? style.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                  )
                : style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// 顶部列柄:hover 表格淡显、hover 该列高亮的胶囊小条,点击弹列菜单。
class _ColHandle extends StatelessWidget {
  const _ColHandle({
    required this.opacity,
    required this.width,
    required this.onTapDown,
    required this.onHover,
  });

  final double opacity;
  final double width;
  final void Function(Offset globalPos) onTapDown;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => onHover(true),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => onTapDown(d.globalPosition),
        child: SizedBox(
          width: width,
          height: _kHandleThickness,
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: opacity,
              child: Container(
                width: 28,
                height: 5,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(
                    alpha: opacity >= 1 ? 0.7 : 0.45,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 左侧行柄:hover 表格淡显、hover 该行高亮的胶囊小条,点击弹行菜单。
class _RowHandle extends StatelessWidget {
  const _RowHandle({
    required this.opacity,
    required this.onTapDown,
    required this.onHover,
  });

  final double opacity;
  final void Function(Offset globalPos) onTapDown;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => onHover(true),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => onTapDown(d.globalPosition),
        child: SizedBox(
          width: _kHandleThickness,
          child: Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: opacity,
              child: Container(
                width: 5,
                height: 22,
                decoration: BoxDecoration(
                  color: scheme.onSurfaceVariant.withValues(
                    alpha: opacity >= 1 ? 0.7 : 0.45,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 表格边缘的加行/加列条(hover 表格时浮现,+ 号居中)。
class _EdgeAddBar extends StatefulWidget {
  const _EdgeAddBar({
    required this.axis,
    required this.visible,
    required this.tooltip,
    required this.onTap,
    this.length,
  });

  final Axis axis;
  final bool visible;
  final String tooltip;
  final VoidCallback onTap;

  /// 水平条的长度(列数 × cell 宽);垂直条随表格高度伸展。
  final double? length;

  @override
  State<_EdgeAddBar> createState() => _EdgeAddBarState();
}

class _EdgeAddBarState extends State<_EdgeAddBar> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final horizontal = widget.axis == Axis.horizontal;
    final bar = AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: widget.visible ? (_hover ? 1 : 0.55) : 0,
      child: Container(
        width: horizontal ? widget.length : 12,
        height: horizontal ? 12 : null,
        margin: horizontal
            ? const EdgeInsets.only(top: 2)
            : const EdgeInsets.only(left: 2),
        decoration: BoxDecoration(
          color: _hover
              ? scheme.primary.withValues(alpha: 0.15)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          Icons.add,
          size: 11,
          color: _hover ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(onTap: widget.onTap, child: bar),
      ),
    );
  }
}
