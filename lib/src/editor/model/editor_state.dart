/// 编辑器文档状态与事务。
///
/// 设计:**不可变快照 + 事务栈**(对齐 ProseMirror 的 state/transaction,
/// 但简化为快照制 —— composer 级文档规模,整表快照成本可忽略):
/// - 文档 = `List<EditorBlock>`(TextBlock 段落/标题/列表项 + IslandBlock
///   只读孤岛,见 editor_block.dart);
/// - 每个编辑方法产生新快照并 push 历史;
/// - undo/redo = 历史栈上换快照;
/// - IME composing 是**状态而非内容**:composing 文本已实时进文档,
///   [composing] 只记录"当前块里哪一段是未上屏预编辑"(画下划线用)。
///
/// **孤岛选区语义**(M2):岛占 1 个选区单位(offset 0/1)。
/// - 退格/删除对岛是两段式:第一次整选,再按才删(主流编辑器的对象删除);
/// - deleteSelection 端点四象限:from=island@0 → 岛计入删除,@1 → 保留;
///   to=island@1 → 计入,@0 → 保留;
/// - 水平移动一步 = 整选岛,再一步 = 落到另一侧。
///
/// **不变量**:文档至少含一个 TextBlock(全岛时自动补空段)。
///
/// 历史合并(seal):连续打字/composing 过程产生的快照合并为一个 undo 步,
/// [sealHistory] 在 composition 结束、结构操作、空闲超时(800ms)时调用。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show TextRange;

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../../node/node.dart';
import 'editable_text_content.dart';
import 'editor_block.dart';
import 'editor_document_binding.dart';
import 'inline_markdown_parser.dart';
import 'inline_spin.dart';
import 'markdown_serializer.dart';

export 'editor_block.dart';
export 'editor_document_binding.dart';

/// 编辑器光标/选区:块 id + 块内**编辑文本偏移**(渲染偏移换算在视图层)。
/// 孤岛块的合法 offset 仅 0(前)/1(后)。
@immutable
class EditorPosition {
  const EditorPosition({required this.blockId, required this.offset});

  final String blockId;
  final int offset;

  EditorPosition copyWith({String? blockId, int? offset}) => EditorPosition(
    blockId: blockId ?? this.blockId,
    offset: offset ?? this.offset,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditorPosition &&
          runtimeType == other.runtimeType &&
          blockId == other.blockId &&
          offset == other.offset;

  @override
  int get hashCode => Object.hash(blockId, offset);

  @override
  String toString() => 'EditorPosition($blockId @$offset)';
}

@immutable
class EditorSelection {
  const EditorSelection({required this.base, required this.extent});

  const EditorSelection.collapsed(EditorPosition position)
    : base = position,
      extent = position;

  final EditorPosition base;
  final EditorPosition extent;

  bool get isCollapsed => base == extent;
  bool get isSingleBlock => base.blockId == extent.blockId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditorSelection &&
          runtimeType == other.runtimeType &&
          base == other.base &&
          extent == other.extent;

  @override
  int get hashCode => Object.hash(base, extent);

  @override
  String toString() => 'EditorSelection($base → $extent)';
}

/// 编辑器工作模式。
///
/// 两者共享同一份文档模型/序列化/输入规则,只在**格式边界的交互语义**
/// 上分叉(显形、mark 末端二态停位、退格物化)。
enum EditorMode {
  /// 所见即所得(默认):任何时候不显形字面定界符;mark 末端无内/外
  /// 二态停位(左右键直接过界);退格恒删字符 / mark 自然收缩,
  /// 不把 mark 物化为字面定界符。
  wysiwyg,

  /// 即时渲染(instant render):光标进入行内 mark 范围时两端显形淡色
  /// 字面定界符;mark 末端有内/外二态停位;外侧(及非 inclusive mark
  /// 末端)退格把 mark 物化为字面定界符。
  ir,
}

/// 历史快照(undo 单元)。
@immutable
class _HistoryEntry {
  const _HistoryEntry({
    required this.blocks,
    required this.selection,
    this.documentBindingState,
  });

  final Object? documentBindingState;
  final List<EditorBlock> blocks;
  final EditorSelection? selection;
}

/// A snapshot of the editing location and its text block. Unrelated document
/// changes must not request scrolling back to a caret the user scrolled away from.
typedef EditorCaretRevealKey = (EditorSelection?, TextBlock?);

/// 编辑器状态机。
class EditorState extends ChangeNotifier {
  EditorState({required List<EditorBlock> blocks, this.documentBinding})
      : _blocks = List.unmodifiable(
          blocks.any((b) => b is TextBlock)
              ? blocks
              // 不变量:文档至少一个 TextBlock(全岛/空输入自动补空段;
              // id 用不会与 e_N 冲突的保留名,后续编辑发号从 e_0 起)
              : [
                  ...blocks,
                  TextBlock(
                    id: 'e_auto_pad',
                    content: EditableTextContent.empty,
                  ),
                ],
        ) {
    _documentBindingState = documentBinding?.prepare(null, exportBlocks());
    // id 计数器越过既有 e_N,防碰撞
    for (final b in _blocks) {
      final m = RegExp(r'^e_(\d+)$').firstMatch(b.id);
      if (m != null) {
        final n = int.parse(m.group(1)!);
        if (n >= _idCounter) _idCounter = n + 1;
      }
    }
  }

  /// 便捷构造:从纯文本段落列表建文档。
  factory EditorState.fromTexts(List<String> paragraphs) {
    var counter = 0;
    return EditorState(
      blocks: [
        for (final t in (paragraphs.isEmpty ? [''] : paragraphs))
          TextBlock(
            id: 'e_${counter++}',
            content: EditableTextContent(text: t),
          ),
      ],
    );
  }

  /// 绑定在构造时固定，避免既有历史缺少对应语义快照。
  final EditorDocumentBinding? documentBinding;
  Object? _documentBindingState;

  /// 与当前正文同步发布的不可变语义快照；无绑定时为 null。
  Object? get documentBindingState => _documentBindingState;

  _HistoryEntry get _currentHistoryEntry => _HistoryEntry(
    blocks: _blocks,
    selection: _selection,
    documentBindingState: _documentBindingState,
  );

  /// 原子重写当前及全部历史；不增加 undo 步，也不清空 redo。
  /// 绑定必须同时给出正文与语义快照，禁止只映射一侧。
  void remapDocumentHistory(Object operation) {
    final binding = documentBinding;
    if (binding is! EditorDocumentHistoryBinding) {
      throw StateError('当前绑定未实现历史重映射协议');
    }
    runAtomicEdit(() {
      _HistoryEntry map(_HistoryEntry entry) {
        final mapped = (binding as EditorDocumentHistoryBinding).remapHistory(
          EditorDocumentHistorySnapshot(entry.blocks, entry.documentBindingState),
          operation,
        );
        final blocks = mapped.blocks;
        if (!blocks.any((b) => b is TextBlock) ||
            blocks.map((b) => b.id).toSet().length != blocks.length) {
          throw StateError('历史映射必须保留文本落点和唯一块 id');
        }
        EditorPosition position(EditorPosition old) {
          final surviving = blocks.where((b) => b.id == old.blockId).firstOrNull;
          final index = entry.blocks.indexWhere((b) => b.id == old.blockId);
          final block = surviving ?? blocks[index.clamp(0, blocks.length - 1)];
          return EditorPosition(
            blockId: block.id,
            offset: surviving == null ? 0 : old.offset.clamp(0, block.selectionLength),
          );
        }
        final selection = entry.selection;
        return _HistoryEntry(
          blocks: blocks,
          documentBindingState: mapped.documentState,
          selection: selection == null
              ? null
              : EditorSelection(
                  base: position(selection.base),
                  extent: position(selection.extent),
                ),
        );
      }
      final current = map(_currentHistoryEntry);
      final undo = _undoStack.map(map).toList();
      final redo = _redoStack.map(map).toList();
      sealHistory();
      _undoStack..clear()..addAll(undo);
      _redoStack..clear()..addAll(redo);
      _blocks = current.blocks;
      _selection = current.selection;
      _documentBindingState = current.documentBindingState;
      _composing = TextRange.empty;
      _lastEditPos = null;
      _pendingMarks = null;
      _pendingAnchor = null;
      _docRevision++;
      notifyListeners();
    });
  }

  bool _atomicEditActive = false;
  bool _atomicEditNotified = false;
  bool _atomicHistoryRecorded = false;
  bool? _atomicTimerAction;

  /// 同步复合编辑：失败恢复全部编辑状态并原样抛出，成功最多通知一次。
  /// 嵌套调用加入外层事务，不创建保存点；不要在回调内吞掉编辑异常。
  /// 每次提交仍调用 binding.prepare，因此不支持的中间态仍可能被拒绝，
  /// 即使最终状态合法；最终态批量校验留待后续协议扩展。
  /// 首次历史记录保留既有合组规则，后续提交并入同一步；需要独立 undo
  /// 时调用方先 sealHistory。无历史提交不会凭空生成历史。不可执行异步
  /// 编辑、dispose 或依赖可回滚的外部副作用；binding 快照必须不可变。
  T runAtomicEdit<T>(T Function() edit) {
    if (_atomicEditActive) return edit();
    final blocks = _blocks;
    final selection = _selection;
    final composing = _composing;
    final revision = _docRevision;
    final bindingState = _documentBindingState;
    final undo = List<_HistoryEntry>.of(_undoStack);
    final redo = List<_HistoryEntry>.of(_redoStack);
    final openGroup = _openGroup;
    final pendingMarks = _pendingMarks;
    final pendingAnchor = _pendingAnchor;
    final lastEditPos = _lastEditPos;
    final idCounter = _idCounter;
    final mode = _mode;
    final softBreak = enterInsertsSoftBreak;
    final callout = pendingCalloutType;
    final island = _pendingIslandEdit;
    final reconcile = _irReconcilePending;
    final reconcileFrom = _pendingIrReconcileFrom;
    _atomicEditActive = true;
    _atomicEditNotified = false;
    _atomicHistoryRecorded = false;
    _atomicTimerAction = null;
    late T result;
    try {
      result = edit();
      if (result is Future) {
        throw StateError('runAtomicEdit 仅接受同步回调');
      }
    } catch (_) {
      _blocks = blocks;
      _selection = selection;
      _composing = composing;
      _docRevision = revision;
      _documentBindingState = bindingState;
      _undoStack..clear()..addAll(undo);
      _redoStack..clear()..addAll(redo);
      _openGroup = openGroup;
      _pendingMarks = pendingMarks;
      _pendingAnchor = pendingAnchor;
      _lastEditPos = lastEditPos;
      _idCounter = idCounter;
      _mode = mode;
      enterInsertsSoftBreak = softBreak;
      pendingCalloutType = callout;
      _pendingIslandEdit = island;
      _irReconcilePending = reconcile;
      _pendingIrReconcileFrom = reconcileFrom;
      _atomicEditActive = false;
      _atomicEditNotified = false;
      _atomicHistoryRecorded = false;
      _atomicTimerAction = null;
      rethrow;
    }
    final notify = _atomicEditNotified;
    final timerAction = _atomicTimerAction;
    _atomicEditActive = false;
    _atomicEditNotified = false;
    _atomicHistoryRecorded = false;
    _atomicTimerAction = null;
    if (timerAction != null) _updateSealTimer(timerAction);
    if (notify) notifyListeners();
    return result;
  }

  @override
  void notifyListeners() {
    if (_atomicEditActive) {
      _atomicEditNotified = true;
      return;
    }
    super.notifyListeners();
  }

  void _updateSealTimer(bool schedule) {
    if (_atomicEditActive) {
      _atomicTimerAction = schedule;
      return;
    }
    _sealIdleTimer?.cancel();
    _sealIdleTimer = schedule ? Timer(_sealIdleDelay, sealHistory) : null;
  }

  List<EditorBlock> _blocks;
  List<EditorBlock> get blocks => _blocks;

  String? pendingCalloutType;

  int get docRevision => _docRevision;
  int _docRevision = 0;

  EditorSelection? _selection;
  EditorSelection? get selection => _selection;

  EditorCaretRevealKey get caretRevealKey => (
    _selection,
    _selection == null ? null : textBlockById(_selection!.extent.blockId),
  );

  TextRange _composing = TextRange.empty;
  TextRange get composing => _composing;

  EditorMode _mode = EditorMode.wysiwyg;
  EditorMode get mode => _mode;
  set mode(EditorMode value) {
    if (_mode == value) return;
    final leavingIr = _mode == EditorMode.ir;
    _mode = value;
    if (leavingIr) _foldAllLiterals();
    notifyListeners();
  }

  void _foldAllLiterals() {
    if (hasComposing) return;
    for (var i = 0; i < _blocks.length; i++) {
      final block = _blocks[i];
      if (block is! TextBlock) continue;
      if (!hasInlineDelimiterChar(block.content.text)) continue;
      final sel = _selection;
      final inBlock =
          sel != null && sel.isCollapsed && sel.extent.blockId == block.id;
      final spun = spinInlineMarks(
        block.content,
        caret: inBlock ? sel.extent.offset : 0,
        guardAtCaret: false,
      );
      if (identical(spun.content, block.content)) continue;
      final newBlocks = [..._blocks];
      newBlocks[i] = block.copyWith(content: spun.content);
      _commit(
        newBlocks,
        inBlock
            ? EditorSelection.collapsed(
                EditorPosition(blockId: block.id, offset: spun.caret),
              )
            : _selection,
        intent: const EditorStructureIntent('_foldAllLiterals'),
        groupWithPrevious: false,
        recordHistory: false,
      );
    }
  }

  bool get hasComposing => _composing.isValid && !_composing.isCollapsed;

  // -----------------------------------------------------------------
  // pending marks(折叠光标 toggle 样式 → 下次输入生效)
  // -----------------------------------------------------------------

  Set<MarkKind>? _pendingMarks;
  EditorPosition? _pendingAnchor;

  Set<MarkKind>? get pendingMarks => _pendingMarks;

  void _clearPending() {
    _pendingMarks = null;
    _pendingAnchor = null;
  }

  int _idCounter = 0;
  String _nextId() => 'e_${_idCounter++}';

  String? _pendingIslandEdit;

  void requestIslandEdit(String blockId) {
    _pendingIslandEdit = blockId;
    notifyListeners();
  }

  bool consumeIslandEditRequest(String blockId) {
    if (_pendingIslandEdit != blockId) return false;
    _pendingIslandEdit = null;
    return true;
  }

  // -----------------------------------------------------------------
  // 查询
  // -----------------------------------------------------------------

  int indexOfBlock(String blockId) =>
      _blocks.indexWhere((b) => b.id == blockId);

  EditorBlock? blockById(String blockId) {
    final i = indexOfBlock(blockId);
    return i < 0 ? null : _blocks[i];
  }

  TextBlock? textBlockById(String blockId) {
    final b = blockById(blockId);
    return b is TextBlock ? b : null;
  }

  (EditorPosition, EditorPosition)? normalizedSelection() {
    final sel = _selection;
    if (sel == null) return null;
    final bi = indexOfBlock(sel.base.blockId);
    final ei = indexOfBlock(sel.extent.blockId);
    if (bi < 0 || ei < 0) return null;
    if (bi < ei || (bi == ei && sel.base.offset <= sel.extent.offset)) {
      return (sel.base, sel.extent);
    }
    return (sel.extent, sel.base);
  }

  Set<MarkKind> effectiveMarksAtCaret() {
    final pending = _pendingMarks;
    if (pending != null) return pending;
    final sel = _selection;
    if (sel == null || !sel.isCollapsed) return const {};
    final block = textBlockById(sel.extent.blockId);
    if (block == null) return const {};
    return block.content.marksAt(
      sel.extent.offset.clamp(0, block.content.length),
    );
  }

  // -----------------------------------------------------------------
  // 历史
  // -----------------------------------------------------------------

  final List<_HistoryEntry> _undoStack = [];
  final List<_HistoryEntry> _redoStack = [];

  bool _openGroup = false;

  Timer? _sealIdleTimer;
  static const Duration _sealIdleDelay = Duration(milliseconds: 800);

  static const int _maxHistory = 200;

  void _recordHistory({required bool groupWithPrevious}) {
    if (groupWithPrevious) {
      _updateSealTimer(true);
    }
    if (_atomicEditActive) {
      if (_atomicHistoryRecorded) return;
      _atomicHistoryRecorded = true;
    }
    if (groupWithPrevious && _openGroup && _undoStack.isNotEmpty) {
      return;
    }
    _undoStack.add(_currentHistoryEntry);
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _redoStack.clear();
    _openGroup = groupWithPrevious;
  }

  void sealHistory() {
    _updateSealTimer(false);
    _openGroup = false;
  }

  @override
  void dispose() {
    _sealIdleTimer?.cancel();
    super.dispose();
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void undo() {
    if (_undoStack.isEmpty) return;
    sealHistory();
    _clearPending();
    _redoStack.add(_currentHistoryEntry);
    final entry = _undoStack.removeLast();
    _blocks = entry.blocks;
    _documentBindingState = entry.documentBindingState;
    _docRevision++;
    _selection = entry.selection == null
        ? null
        : _clampSelection(entry.selection!);
    _composing = TextRange.empty;
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    sealHistory();
    _clearPending();
    _undoStack.add(_currentHistoryEntry);
    final entry = _redoStack.removeLast();
    _blocks = entry.blocks;
    _documentBindingState = entry.documentBindingState;
    _docRevision++;
    _selection = entry.selection == null
        ? null
        : _clampSelection(entry.selection!);
    _composing = TextRange.empty;
    notifyListeners();
  }

  // -----------------------------------------------------------------
  // 选区/composing 更新(不产历史)
  // -----------------------------------------------------------------

  void updateSelection(
    EditorSelection? selection, {
    bool deferIrReconcile = false,
  }) {
    if (_selection == selection) {
      if (deferIrReconcile && selection != null && !_irReconcilePending) {
        _irReconcilePending = true;
        _pendingIrReconcileFrom = selection.extent.blockId;
      }
      return;
    }
    final prevBlockId = _selection?.extent.blockId;
    _selection = selection == null ? null : _clampSelection(selection);
    _composing = TextRange.empty;
    _clearPending();
    _lastEditPos = null;

    if (deferIrReconcile) {
      if (!_irReconcilePending) {
        _irReconcilePending = true;
        _pendingIrReconcileFrom = prevBlockId;
      }
    } else {
      _irReconcilePending = false;
      _pendingIrReconcileFrom = null;
      _reconcileLiteralsAfterCaretMove(prevBlockId);
    }
    notifyListeners();
  }

  bool _irReconcilePending = false;
  String? _pendingIrReconcileFrom;

  void commitDeferredIrReconcile() {
    if (!_irReconcilePending) return;
    _irReconcilePending = false;
    final from = _pendingIrReconcileFrom;
    _pendingIrReconcileFrom = null;
    _reconcileLiteralsAfterCaretMove(from);
  }

  void cancelDeferredIrReconcile() {
    _irReconcilePending = false;
    _pendingIrReconcileFrom = null;
  }

  void _reconcileLiteralsAfterCaretMove(String? prevBlockId) {
    if (_mode != EditorMode.ir) return;
    if (hasComposing) return;
    final sel = _selection;
    if (sel != null && !sel.isCollapsed) return;

    var foldedInCaretBlock = false;
    final targets = <String>{?prevBlockId, if (sel != null) sel.extent.blockId};
    for (final id in targets) {
      final i = indexOfBlock(id);
      if (i < 0) continue;
      final block = _blocks[i];
      if (block is! TextBlock) continue;
      if (!hasInlineDelimiterChar(block.content.text)) continue;
      final inBlock = sel != null && sel.extent.blockId == id;
      final spun = spinInlineMarks(
        block.content,
        caret: inBlock ? sel.extent.offset : 0,
        guardAtCaret: inBlock,
        guardInclusive: true,
      );
      if (identical(spun.content, block.content)) continue;
      if (inBlock) foldedInCaretBlock = true;
      final newBlocks = [..._blocks];
      newBlocks[i] = block.copyWith(content: spun.content);
      _commit(
        newBlocks,
        inBlock
            ? EditorSelection.collapsed(
                EditorPosition(blockId: id, offset: spun.caret),
              )
            : _selection,
        intent: const EditorStructureIntent('_reconcileLiteralsAfterCaretMove'),
        groupWithPrevious: false,
        recordHistory: false,
      );
    }

    final cur = _selection;
    if (cur == null || !cur.isCollapsed) return;
    if (foldedInCaretBlock) {
      final b = textBlockById(cur.extent.blockId);
      final off = cur.extent.offset;
      final strictlyInside =
          b != null &&
          b.content.marks.any(
            (m) =>
                m.start < off && off < m.end && isRefoldableMark(b.content, m),
          );
      if (!strictlyInside) return;
    }
    materializeClusterAt(cur.extent.blockId, cur.extent.offset);
  }

  bool materializeClusterAt(String blockId, int offset) {
    if (_mode != EditorMode.ir) return false;
    if (hasComposing) return false;
    final i = indexOfBlock(blockId);
    if (i < 0) return false;
    final block = _blocks[i];
    if (block is! TextBlock) return false;
    final content = block.content;

    final seeds = <MarkSpan>[
      for (final m in content.marks)
        if (m.start <= offset &&
            offset <= m.end &&
            isRefoldableMark(content, m))
          m,
    ];
    if (seeds.isEmpty) return false;
    final cluster = <MarkSpan>{...seeds};
    var grew = true;
    while (grew) {
      grew = false;
      for (final m in content.marks) {
        if (cluster.contains(m) || !isRefoldableMark(content, m)) continue;
        final touches = cluster.any(
          (c) => m.start <= c.end && c.start <= m.end,
        );
        if (touches) {
          cluster.add(m);
          grew = true;
        }
      }
    }

    final materialized = materializeMarksToLiteral(
      content,
      cluster,
      caret: offset,
    );

    final verify = spinInlineMarks(
      materialized.content,
      caret: 0,
      guardAtCaret: false,
    );
    if (verify.content.text != content.text ||
        !_sameMarkSet(verify.content.marks, content.marks)) {
      return false;
    }
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: materialized.content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: blockId, offset: materialized.caret),
      ),
      intent: const EditorStructureIntent('materializeClusterAt'),
      groupWithPrevious: false,
      recordHistory: false,
    );
    return true;
  }

  static bool _sameMarkSet(List<MarkSpan> a, List<MarkSpan> b) {
    if (a.length != b.length) return false;
    final rest = [...b];
    for (final m in a) {
      if (rest.remove(m)) continue;
      final index = rest.indexWhere((old) =>
          m.kind == MarkKind.link && old.kind == m.kind &&
          m.isAutoLink == false && old.isAutoLink == null &&
          old.start == m.start && old.end == m.end && old.attr == m.attr);
      if (index < 0) return false;
      rest.removeAt(index);
    }
    return true;
  }

  void updateComposing(TextRange range) {
    if (_composing == range) return;
    _composing = range;
    notifyListeners();
  }

  EditorSelection _clampSelection(EditorSelection sel) {
    EditorPosition clampPos(EditorPosition p) {
      final block = blockById(p.blockId);
      if (block == null) {
        final lastText = _blocks.lastWhere((b) => b is TextBlock) as TextBlock;
        return EditorPosition(
          blockId: lastText.id,
          offset: lastText.content.length,
        );
      }
      return EditorPosition(
        blockId: p.blockId,
        offset: p.offset.clamp(0, block.selectionLength),
      );
    }

    return EditorSelection(
      base: clampPos(sel.base),
      extent: clampPos(sel.extent),
    );
  }

  List<EditorBlock> _ensureTextBlock(List<EditorBlock> blocks) {
    if (blocks.any((b) => b is TextBlock)) return blocks;
    return [
      ...blocks,
      TextBlock(id: _nextId(), content: EditableTextContent.empty),
    ];
  }

  // -----------------------------------------------------------------
  // 事务提交
  // -----------------------------------------------------------------

  void _commit(
    List<EditorBlock> newBlocks,
    EditorSelection? newSelection, {
    required bool groupWithPrevious,
    TextRange composing = TextRange.empty,
    bool recordHistory = true,
    bool sealBeforeCommit = false,
    bool clearPendingBeforeCommit = false,
    EditorStructureIntent? intent,
  }) {
    final preparedBlocks = List<EditorBlock>.unmodifiable(
      _ensureTextBlock(newBlocks),
    );
    final binding = documentBinding;
    final range = normalizedSelection();
    intent = intent?.withRange(
      range?.$1.blockId,
      range?.$1.offset,
      range?.$2.blockId,
      range?.$2.offset,
    );
    final normalized = exportBlocks(fragment: preparedBlocks);
    final preparedState = binding is EditorDocumentIntentBinding && intent != null
        ? (binding as EditorDocumentIntentBinding).prepareWithIntent(_documentBindingState, normalized, intent)
        : binding?.prepare(_documentBindingState, normalized);

    if (documentBinding != null) {
      if (sealBeforeCommit) sealHistory();
      if (clearPendingBeforeCommit) _clearPending();
    }
    if (recordHistory) {
      _recordHistory(groupWithPrevious: groupWithPrevious);
    }
    _blocks = preparedBlocks;
    _documentBindingState = preparedState;
    _docRevision++;
    _selection = newSelection == null ? null : _clampSelection(newSelection);
    _composing = composing;
    _lastEditPos = recordHistory && (_selection?.isCollapsed ?? false)
        ? _selection!.extent
        : null;
    notifyListeners();
  }

  // -----------------------------------------------------------------
  // 文本事务
  // -----------------------------------------------------------------

  bool _irSuppressEndExtension(
    EditableTextContent c,
    String blockId,
    int offset,
  ) {
    if (_mode != EditorMode.ir) return false;
    final le = _lastEditPos;
    if (le != null && le.blockId == blockId && le.offset == offset) {
      return false;
    }
    return c.marks.any(
      (m) =>
          m.end == offset &&
          EditableTextContent.isInclusiveMark(m) &&
          isRefoldableMark(c, m),
    );
  }

  EditorPosition? _lastEditPos;
  EditorPosition? get lastEditPos => _lastEditPos;

  void insertText(String inserted) {
    if (documentBinding != null && !_atomicEditActive) {
      return runAtomicEdit(() => insertText(inserted));
    }
    final sanitized = EditableTextContent.sanitizeText(inserted);
    if (sanitized.isEmpty) return;
    if (normalizedSelection() == null) return;
    if (replaceCrossBlockSelection(sanitized, caretOffset: sanitized.length)) {
      return;
    }
    if (!(_selection?.isCollapsed ?? true)) {
      deleteSelection();
    }
    final pos = _selection!.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;

    final hasNewline = sanitized.contains('\n');
    var content = block.content.insert(
      pos.offset,
      sanitized,
      extendMarksAtEnd:
          !hasNewline &&
          !hasInlineDelimiterChar(sanitized) &&
          !_irSuppressEndExtension(block.content, pos.blockId, pos.offset) &&
          (_pendingMarks == null || _pendingAnchor != pos),
    );

    final clearPendingAfterCommit = hasNewline ||
        (_pendingMarks != null && _pendingAnchor == pos);
    if (!hasNewline && _pendingMarks != null && _pendingAnchor == pos) {
      content = content.applyExactMarks(
        pos.offset,
        pos.offset + sanitized.length,
        _pendingMarks!,
      );
    }
    if (documentBinding == null && clearPendingAfterCommit) _clearPending();

    var caret = pos.offset + sanitized.length;
    final spun = _maybeSpin(content, caret);
    content = spun.content;
    caret = spun.caret;
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(pos.copyWith(offset: caret)),
      intent: const EditorStructureIntent('insertText'),
      groupWithPrevious: true,
    );
    if (documentBinding != null && clearPendingAfterCommit) _clearPending();
  }

  void insertAtom(InlineNode atom) {
    if (documentBinding != null && !_atomicEditActive) {
      return runAtomicEdit(() => insertAtom(atom));
    }
    if (normalizedSelection() == null) return;
    if (!(_selection?.isCollapsed ?? true)) {
      deleteSelection();
    }
    final pos = _selection!.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    if (documentBinding == null) sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content: block.content.insertAtom(pos.offset, atom),
    );
    _commit(
      newBlocks,
      EditorSelection.collapsed(pos.copyWith(offset: pos.offset + 1)),
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('insertAtom'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void replaceAtomAt(
    String blockId,
    int offset,
    InlineNode newAtom, {
    bool reselect = false,
  }) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    if (!block.content.isAtomAt(offset)) return;
    if (documentBinding == null) sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content: block.content
          .delete(offset, offset + 1)
          .insertAtom(offset, newAtom),
    );
    _commit(
      newBlocks,
      reselect
          ? EditorSelection(
              base: EditorPosition(blockId: blockId, offset: offset),
              extent: EditorPosition(blockId: blockId, offset: offset + 1),
            )
          : EditorSelection.collapsed(
              EditorPosition(blockId: blockId, offset: offset + 1),
            ),
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('replaceAtomAt'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  bool editLinkAtomAt(String blockId, int offset, {
    required String text,
    required String href,
  }) {
    final atom = textBlockById(blockId)?.content.atoms[offset];
    if (atom is! LinkRun) return false;
    final oldText = EditableTextContent.fromInlines(atom.children).text;
    replaceAtomAt(blockId, offset, LinkRun(
      href: href,
      children: text == oldText ? atom.children : [TextRun(text)],
      isAttachment: atom.isAttachment,
      filename: text == oldText ? atom.filename : text,
      origHref: atom.origHref == null ? null : href,
      hashtagRef: atom.hashtagRef,
      hashtagIcon: atom.hashtagIcon,
      isOneboxLink: atom.isOneboxLink,
      editorLinkSource: atom.editorLinkSource,
      editorLinkTitle: atom.editorLinkTitle,
      editorAngleLink: atom.editorAngleLink && text == href,
    ), reselect: true);
    return true;
  }

  void replaceBlockRange(
    int start,
    int end,
    List<EditorBlock> replacement, {
    EditorSelection? selection,
  }) {
    assert(start >= 0 && end < _blocks.length && start <= end);
    if (documentBinding == null) {
      sealHistory();
      _clearPending();
    }
    final newBlocks = [
      ..._blocks.sublist(0, start),
      ...replacement,
      ..._blocks.sublist(end + 1),
    ];
    _commit(newBlocks, selection ?? _selection,
      sealBeforeCommit: true,
      clearPendingBeforeCommit: true,
      intent: EditorStructureIntent('replaceBlockRange', fragment: replacement),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void forgetTransientBlockInHistory(String blockId) {
    if (documentBinding != null) {
      throw const EditorDocumentRejection(
        '文档绑定尚不支持清理临时块历史',
        code: 'history_remap_unsupported',
      );
    }
    _HistoryEntry clean(_HistoryEntry entry) {
      final blocks = entry.blocks.where((block) => block.id != blockId).toList();
      if (blocks.length == entry.blocks.length) return entry;
      final selection = entry.selection;
      return _HistoryEntry(
        blocks: List.unmodifiable(blocks.isEmpty
            ? [TextBlock(id: _nextId(), content: EditableTextContent.empty)]
            : blocks),
        selection: selection?.base.blockId == blockId || selection?.extent.blockId == blockId
            ? null : selection,
      );
    }
    for (var i = 0; i < _undoStack.length; i++) { _undoStack[i] = clean(_undoStack[i]); }
    for (var i = 0; i < _redoStack.length; i++) { _redoStack[i] = clean(_redoStack[i]); }
  }

  String nextBlockId() => _nextId();

  void insertIslandAfter(String blockId, BlockNode node) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    if (documentBinding == null) sealHistory();
    final islandId = _nextId();
    final newBlocks = [..._blocks];
    newBlocks.insert(i + 1, IslandBlock(id: islandId, node: node));
    _commit(
      newBlocks,
      EditorSelection.collapsed(EditorPosition(blockId: islandId, offset: 1)),
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('insertIslandAfter'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void imeReplace(
    String blockId,
    int start,
    int end,
    String replacement, {
    required int caretOffset,
    TextRange composing = TextRange.empty,
  }) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    final safeStart = start.clamp(0, block.content.length);
    final safeEnd = end.clamp(safeStart, block.content.length);
    final isTextChange = safeStart != safeEnd || replacement.isNotEmpty;

    if (!isTextChange) {
      final prevBlockId = _selection?.extent.blockId;
      final prevSel = _selection;
      _selection = _clampSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: blockId, offset: caretOffset),
        ),
      );
      if (_selection != prevSel) _lastEditPos = null;
      _composing = composing;
      _reconcileLiteralsAfterCaretMove(prevBlockId);
      notifyListeners();
      return;
    }

    final pendingHit =
        _pendingMarks != null &&
        _pendingAnchor != null &&
        _pendingAnchor!.blockId == blockId &&
        _pendingAnchor!.offset == safeStart;
    var content = block.content.replace(
      safeStart,
      safeEnd,
      replacement,
      extendMarksAtEnd:
          !pendingHit &&
          !hasInlineDelimiterChar(replacement) &&
          !_irSuppressEndExtension(block.content, blockId, safeStart),
    );

    final anchor = _pendingAnchor;
    if (_pendingMarks != null &&
        anchor != null &&
        anchor.blockId == blockId &&
        anchor.offset == safeStart &&
        replacement.isNotEmpty) {
      content = content.applyExactMarks(
        safeStart,
        safeStart + replacement.length,
        _pendingMarks!,
      );
      if (documentBinding == null &&
          !(composing.isValid && !composing.isCollapsed)) {
        _clearPending();
      }
    }
    final newBlocks = [..._blocks];
    final composingActive = composing.isValid && !composing.isCollapsed;
    var caret = caretOffset;
    if (!composingActive) {
      final spun = _maybeSpin(content, caretOffset.clamp(0, content.length));
      content = spun.content;
      caret = spun.caret;
    }
    newBlocks[i] = block.copyWith(content: content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: blockId, offset: caret),
      ),
      intent: const EditorStructureIntent('imeReplace'),
      groupWithPrevious: true,
      composing: composing,
    );
    if (documentBinding != null && pendingHit &&
        replacement.isNotEmpty && !composingActive) {
      _clearPending();
    }
  }

  bool replaceCrossBlockSelection(String inserted, {
    required int caretOffset,
    TextRange composing = TextRange.empty,
  }) {
    final selection = _selection;
    final normalized = normalizedSelection();
    if (selection == null || selection.isSingleBlock || normalized == null) return false;
    var (from, to) = normalized;
    var first = indexOfBlock(from.blockId);
    var last = indexOfBlock(to.blockId);
    if (_blocks[first] is IslandBlock && from.offset >= 1) {
      first++;
      if (first > last) return false;
      from = EditorPosition(blockId: _blocks[first].id, offset: 0);
    }
    if (_blocks[last] is IslandBlock && to.offset <= 0) {
      last--;
      if (last < first) return false;
      to = EditorPosition(blockId: _blocks[last].id, offset: _blocks[last].selectionLength);
    }
    final head = _blocks[first];
    final tail = _blocks[last];
    final prefix = head is TextBlock ? head.content.slice(0, from.offset) : EditableTextContent.empty;
    final suffix = tail is TextBlock ? tail.content.slice(to.offset, tail.content.length) : EditableTextContent.empty;
    final text = EditableTextContent.sanitizeText(inserted);
    final merged = prefix.concat(suffix).insert(prefix.length, text);
    final block = head is TextBlock ? head : tail is TextBlock ? tail : TextBlock(id: _nextId(), content: EditableTextContent.empty);
    if (documentBinding == null) sealHistory();
    if (documentBinding == null) _clearPending();
    _commit([
      ..._blocks.sublist(0, first),
      block.copyWith(content: merged),
      ..._blocks.sublist(last + 1),
    ], EditorSelection.collapsed(EditorPosition(blockId: block.id, offset: prefix.length + caretOffset.clamp(0, text.length))),
      sealBeforeCommit: true,
      clearPendingBeforeCommit: true,
      intent: const EditorStructureIntent('replaceCrossBlockSelection'),
      groupWithPrevious: true,
      composing: composing.isValid ? TextRange(
        start: prefix.length + composing.start.clamp(0, text.length),
        end: prefix.length + composing.end.clamp(0, text.length),
      ) : TextRange.empty,
    );
    return true;
  }

  void deleteSelection() {
    final norm = normalizedSelection();
    if (norm == null) return;
    var (from, to) = norm;
    if (_selection!.isCollapsed) return;
    if (documentBinding == null) sealHistory();
    if (documentBinding == null) _clearPending();

    var fi = indexOfBlock(from.blockId);
    var ti = indexOfBlock(to.blockId);
    if (fi < 0 || ti < 0) return;

    if (_blocks[fi] is IslandBlock) {
      if (from.offset >= 1) {
        fi += 1;
        if (fi > ti) return;
        from = EditorPosition(blockId: _blocks[fi].id, offset: 0);
      } else {
        from = EditorPosition(blockId: _blocks[fi].id, offset: 0);
      }
    }
    if (_blocks[ti] is IslandBlock) {
      if (to.offset <= 0) {
        ti -= 1;
        if (ti < fi) return;
        to = EditorPosition(
          blockId: _blocks[ti].id,
          offset: _blocks[ti].selectionLength,
        );
      } else {
        to = EditorPosition(blockId: _blocks[ti].id, offset: 1);
      }
    }

    final fromBlock = _blocks[fi];
    final toBlock = _blocks[ti];
    final newBlocks = <EditorBlock>[..._blocks.sublist(0, fi)];
    EditorPosition? caret;

    if (fi == ti) {
      if (fromBlock is TextBlock) {
        final spun = _maybeSpin(
          fromBlock.content.delete(from.offset, to.offset),
          from.offset,
        );
        newBlocks.add(fromBlock.copyWith(content: spun.content));
        caret = EditorPosition(blockId: fromBlock.id, offset: spun.caret);
      }
      caret ??= from;
    } else {
      EditableTextContent? headContent;
      TextBlock? headBlock;
      if (fromBlock is TextBlock) {
        headBlock = fromBlock;
        headContent = fromBlock.content.delete(
          from.offset,
          fromBlock.content.length,
        );
      }
      EditableTextContent? tailContent;
      TextBlock? tailBlock;
      if (toBlock is TextBlock) {
        tailBlock = toBlock;
        tailContent = toBlock.content.delete(0, to.offset);
      }

      if (headBlock != null && tailContent != null) {
        final spun = _maybeSpin(headContent!.concat(tailContent), from.offset);
        newBlocks.add(headBlock.copyWith(content: spun.content));
        caret = EditorPosition(blockId: headBlock.id, offset: spun.caret);
      } else if (headBlock != null) {
        newBlocks.add(headBlock.copyWith(content: headContent!));
        caret = EditorPosition(blockId: headBlock.id, offset: from.offset);
      } else if (tailBlock != null) {
        newBlocks.add(tailBlock.copyWith(content: tailContent!));
        caret = EditorPosition(blockId: tailBlock.id, offset: 0);
      }
      caret ??= from;
    }

    newBlocks.addAll(_blocks.sublist(ti + 1));
    _commit(
      newBlocks,
      EditorSelection.collapsed(caret),
      clearPendingBeforeCommit: true,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('deleteSelection'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void backspace() {
    if (documentBinding != null && !_atomicEditActive) {
      return runAtomicEdit(() => backspace());
    }
    final sel = _selection;
    if (sel == null) return;
    if (!sel.isCollapsed) {
      deleteSelection();
      return;
    }
    final pos = sel.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final block = _blocks[i];

    if (block is IslandBlock) {
      _selectIsland(block.id);
      return;
    }
    block as TextBlock;

    if (pos.offset == 0) {
      if (block.isListItem) {
        if (block.depth > 0) {
          _updateBlockAttrs(i, block.copyWith(depth: block.depth - 1));
        } else {
          _updateBlockAttrs(i, block.asParagraph());
        }
        return;
      }
      if (block.containers.isNotEmpty) {
        _updateBlockAttrs(
          i,
          block.copyWith(
            containers: block.containers.sublist(
              0,
              block.containers.length - 1,
            ),
          ),
        );
        return;
      }
      if (i == 0) return;
      final prev = _blocks[i - 1];
      if (prev is IslandBlock) {
        _selectIsland(prev.id);
        return;
      }
      mergeWithPrevious(pos.blockId);
      return;
    }

    final before = block.content.text.substring(0, pos.offset);
    final lastCluster = before.characters.isEmpty ? '' : before.characters.last;
    final delStart = pos.offset - lastCluster.length;
    final spun = _maybeSpin(
      block.content.delete(delStart, pos.offset),
      delStart,
    );
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: spun.content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(pos.copyWith(offset: spun.caret)),
      intent: const EditorStructureIntent('backspace'),
      groupWithPrevious: true,
    );
  }

  SpinResult _maybeSpin(EditableTextContent content, int caret) {
    if (_mode != EditorMode.ir) return (content: content, caret: caret);
    return spinInlineMarks(content, caret: caret, guardInclusive: true);
  }

  void deleteForward() {
    if (documentBinding != null && !_atomicEditActive) {
      return runAtomicEdit(() => deleteForward());
    }
    final sel = _selection;
    if (sel == null) return;
    if (!sel.isCollapsed) {
      deleteSelection();
      return;
    }
    final pos = sel.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final block = _blocks[i];

    if (block is IslandBlock) {
      _selectIsland(block.id);
      return;
    }
    block as TextBlock;

    if (pos.offset >= block.content.length) {
      if (i + 1 >= _blocks.length) return;
      final next = _blocks[i + 1];
      if (next is IslandBlock) {
        _selectIsland(next.id);
        return;
      }
      mergeWithPrevious(next.id);
      return;
    }
    final after = block.content.text.substring(pos.offset);
    final step = after.characters.isEmpty ? 0 : after.characters.first.length;
    if (step == 0) return;
    final spun = _maybeSpin(
      block.content.delete(pos.offset, pos.offset + step),
      pos.offset,
    );
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: spun.content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(pos.copyWith(offset: spun.caret)),
      intent: const EditorStructureIntent('deleteForward'),
      groupWithPrevious: true,
    );
  }

  void _selectIsland(String islandId) {
    sealHistory();
    updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: islandId, offset: 0),
        extent: EditorPosition(blockId: islandId, offset: 1),
      ),
    );
  }

  bool enterInsertsSoftBreak = false;

  void insertNewline() {
    if (!enterInsertsSoftBreak) {
      splitBlock();
      return;
    }
    final sel = _selection;
    final block = sel == null ? null : textBlockById(sel.extent.blockId);
    if (block == null ||
        block.isListItem ||
        block.isHeading ||
        block.containers.isNotEmpty) {
      splitBlock();
      return;
    }
    insertText('\n');
  }

  void splitBlock() {
    if (documentBinding != null && !_atomicEditActive) {
      return runAtomicEdit(() => splitBlock());
    }
    final sel = _selection;
    if (sel == null) return;
    if (!sel.isCollapsed && sel.isSingleBlock) {
      final b = blockById(sel.extent.blockId);
      if (b is IslandBlock) {
        _insertParagraphNear(indexOfBlock(b.id), after: true);
        return;
      }
    }
    if (!sel.isCollapsed) deleteSelection();
    final pos = _selection!.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final block = _blocks[i];

    if (block is IslandBlock) {
      _insertParagraphNear(i, after: pos.offset > 0);
      return;
    }
    block as TextBlock;

    if (block.isListItem && block.content.length == 0) {
      if (block.depth > 0) {
        _updateBlockAttrs(i, block.copyWith(depth: block.depth - 1));
      } else {
        _updateBlockAttrs(i, block.asParagraph());
      }
      return;
    }
    if (block.containers.isNotEmpty &&
        block.isParagraph &&
        block.content.length == 0) {
      _updateBlockAttrs(
        i,
        block.copyWith(
          containers: block.containers.sublist(0, block.containers.length - 1),
        ),
      );
      return;
    }

    if (documentBinding == null) sealHistory();
    final (before, after) = block.content.split(pos.offset);
    final newId = _nextId();

    final atTail = pos.offset >= block.content.length;
    final TextBlock newBlock;
    if (block.isHeading && atTail) {
      newBlock = TextBlock(
        id: newId,
        content: after,
        containers: block.containers,
      );
    } else {
      newBlock = block
          .copyWith(content: after)
          .let((b) => TextBlock(
                id: newId,
                content: b.content,
                kind: b.kind,
                headingLevel: b.headingLevel,
                ordered: b.ordered,
                listLoose: b.listLoose,
                depth: b.depth,
                containers: b.containers,
              ));
    }

    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: before);
    newBlocks.insert(i + 1, newBlock);
    _commit(
      newBlocks,
      EditorSelection.collapsed(EditorPosition(blockId: newId, offset: 0)),
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('splitBlock'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void insertParagraphNearIsland(String islandId, {required bool after}) {
    final i = indexOfBlock(islandId);
    if (i < 0 || _blocks[i] is! IslandBlock) return;
    _insertParagraphNear(i, after: after);
  }

  void continueAfterDocument() {
    _insertParagraphNear(_blocks.length - 1, after: true);
  }

  void placeCaretBesideObject(
    String blockId, {
    int? atomOffset,
    required bool after,
  }) {
    final index = indexOfBlock(blockId);
    if (index < 0) return;
    final block = _blocks[index];
    final offset = (atomOffset ?? 0) + (after ? 1 : 0);
    if (block is TextBlock &&
        atomOffset != null &&
        (after ? offset < block.content.length : offset > 0)) {
      updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: blockId, offset: offset),
        ),
      );
      return;
    }
    final neighborIndex = index + (after ? 1 : -1);
    if (neighborIndex >= 0 &&
        neighborIndex < _blocks.length &&
        _blocks[neighborIndex] is TextBlock) {
      final neighbor = _blocks[neighborIndex] as TextBlock;
      updateSelection(
        EditorSelection.collapsed(
          EditorPosition(
            blockId: neighbor.id,
            offset: after ? 0 : neighbor.content.length,
          ),
        ),
      );
      return;
    }
    if (block is IslandBlock) {
      _insertParagraphNear(index, after: after);
    } else if (block is TextBlock && atomOffset != null) {
      updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: blockId, offset: offset),
        ),
      );
      splitBlock();
      if (!after) {
        updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: blockId, offset: 0),
          ),
        );
      }
    }
  }

  void _insertParagraphNear(int index, {required bool after}) {
    if (index < 0) return;
    if (documentBinding == null) sealHistory();
    final newId = _nextId();
    final newBlocks = [..._blocks];
    newBlocks.insert(
      after ? index + 1 : index,
      TextBlock(id: newId, content: EditableTextContent.empty),
    );
    _commit(
      newBlocks,
      EditorSelection.collapsed(EditorPosition(blockId: newId, offset: 0)),
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('_insertParagraphNear'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void mergeWithPrevious(String blockId) {
    final i = indexOfBlock(blockId);
    if (i <= 0) return;
    final prev = _blocks[i - 1];
    final cur = _blocks[i];
    if (prev is! TextBlock || cur is! TextBlock) return;
    if (documentBinding == null) sealHistory();
    final joinOffset = prev.content.length;
    final newBlocks = [..._blocks];
    newBlocks[i - 1] = prev.copyWith(content: prev.content.concat(cur.content));
    newBlocks.removeAt(i);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: prev.id, offset: joinOffset),
      ),
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('mergeWithPrevious'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  // -----------------------------------------------------------------
  // 格式命令
  // -----------------------------------------------------------------

  void toggleMark(MarkKind kind) {
    assert(kind != MarkKind.link, 'link 用 applyLink/removeLink');
    final sel = _selection;
    if (sel == null) return;

    if (sel.isCollapsed) {
      final block = textBlockById(sel.extent.blockId);
      if (block == null) return;
      final current =
          _pendingMarks ??
          block.content.marksAt(
            sel.extent.offset.clamp(0, block.content.length),
          );
      final next = {...current};
      if (!next.remove(kind)) next.add(kind);
      _pendingMarks = next;
      _pendingAnchor = sel.extent;
      notifyListeners();
      return;
    }

    final norm = normalizedSelection()!;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return;
    final i = indexOfBlock(from.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    if (documentBinding == null) sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content: block.content.toggleMarkInRange(from.offset, to.offset, kind),
    );
    _commit(newBlocks, sel,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('toggleMark'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void applyLink(String href) {
    final norm = normalizedSelection();
    if (norm == null || _selection!.isCollapsed) return;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return;
    final i = indexOfBlock(from.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    if (documentBinding == null) sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content: block.content
          .applyMark(from.offset, to.offset, MarkKind.link,
              attr: href, isAutoLink: false),
    );
    _commit(newBlocks, _selection,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('applyLink'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void removeLink() {
    final norm = normalizedSelection();
    if (norm == null || _selection!.isCollapsed) return;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return;
    final i = indexOfBlock(from.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    if (documentBinding == null) sealHistory();
    final newBlocks = [..._blocks];
    final atom = block.content.atoms[from.offset];
    final content = atom is LinkRun && to.offset == from.offset + 1
        ? block.content.delete(from.offset, to.offset).insert(
            from.offset, EditableTextContent.fromInlines(atom.children).text)
        : block.content.removeMark(from.offset, to.offset, MarkKind.link);
    newBlocks[i] = block.copyWith(content: content);
    _commit(newBlocks, _selection,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('removeLink'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void applyTextColor(String colorValue) {
    final norm = normalizedSelection();
    if (norm == null || _selection!.isCollapsed) return;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return;
    final i = indexOfBlock(from.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content: block.content.applyMark(
        from.offset,
        to.offset,
        MarkKind.textColor,
        attr: colorValue,
      ),
    );
    _commit(newBlocks, _selection, groupWithPrevious: false);
    sealHistory();
  }

  void materializeMarkAt(String blockId, MarkSpan mark, {int? caretOffset}) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    final content = block.content;
    if (!content.marks.contains(mark)) return;
    final opening = markOpeningDelimiter(mark);
    final closing = markClosingDelimiter(mark);
    if (opening.isEmpty && closing.isEmpty) return;
    if (documentBinding == null) sealHistory();
    if (documentBinding == null) _clearPending();

    var next = EditableTextContent(
      text: content.text,
      marks: [
        for (final m in content.marks)
          if (m != mark) m,
      ],
      atoms: content.atoms,
      softBreaks: content.softBreaks,
    );
    next = next.insert(mark.end, closing);
    next = next.insert(mark.start, opening);

    final caret =
        caretOffset?.clamp(0, next.length) ??
        mark.end + opening.length + closing.length;
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: next);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: blockId, offset: caret),
      ),
      clearPendingBeforeCommit: true,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('materializeMarkAt'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  // -----------------------------------------------------------------
  // 块命令
  // -----------------------------------------------------------------

  (int, int)? _selectedTextBlockRange() {
    final norm = normalizedSelection();
    if (norm == null) return null;
    final fi = indexOfBlock(norm.$1.blockId);
    final ti = indexOfBlock(norm.$2.blockId);
    if (fi < 0 || ti < 0) return null;
    return (fi, ti);
  }

  void _updateBlockAttrs(int index, TextBlock updated) {
    if (documentBinding == null) sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[index] = updated;
    _commit(newBlocks, _selection,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('_updateBlockAttrs'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void _mapSelectedTextBlocks(TextBlock Function(TextBlock) f) {
    final range = _selectedTextBlockRange();
    if (range == null) return;
    if (documentBinding == null) sealHistory();
    final newBlocks = [..._blocks];
    var changed = false;
    for (var i = range.$1; i <= range.$2; i++) {
      final b = newBlocks[i];
      if (b is TextBlock) {
        final nb = f(b);
        if (nb != b) {
          newBlocks[i] = nb;
          changed = true;
        }
      }
    }
    if (!changed) return;
    _commit(newBlocks, _selection,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('_mapSelectedTextBlocks'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void setHeading(int? level) => _mapSelectedTextBlocks(
    (b) => level == null ? b.asParagraph() : b.asHeading(level),
  );

  void toggleHeading(int level) {
    final range = _selectedTextBlockRange();
    if (range == null) return;
    final all = _blocks
        .sublist(range.$1, range.$2 + 1)
        .whereType<TextBlock>()
        .toList();
    if (all.isEmpty) return;
    final isAll = all.every((b) => b.isHeading && b.headingLevel == level);
    setHeading(isAll ? null : level);
  }

  void toggleList({required bool ordered}) {
    final range = _selectedTextBlockRange();
    if (range == null) return;
    final all = _blocks
        .sublist(range.$1, range.$2 + 1)
        .whereType<TextBlock>()
        .toList();
    if (all.isEmpty) return;
    final isAll = all.every((b) => b.isListItem && b.ordered == ordered);
    _mapSelectedTextBlocks(
      (b) => isAll ? b.asParagraph() : b.asListItem(ordered: ordered),
    );
  }

  void indentListItem() {
    final sel = _selection;
    if (sel == null || !sel.isCollapsed) return;
    final i = indexOfBlock(sel.extent.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock || !block.isListItem) return;
    final prev = i > 0 ? _blocks[i - 1] : null;
    final maxDepth = prev is TextBlock && prev.isListItem ? prev.depth + 1 : 0;
    if (block.depth >= maxDepth) return;
    _updateBlockAttrs(i, block.copyWith(depth: block.depth + 1));
  }

  void outdentListItem() {
    final sel = _selection;
    if (sel == null || !sel.isCollapsed) return;
    final i = indexOfBlock(sel.extent.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock || !block.isListItem) return;
    if (block.depth > 0) {
      _updateBlockAttrs(i, block.copyWith(depth: block.depth - 1));
    } else {
      _updateBlockAttrs(i, block.asParagraph());
    }
  }

  void toggleQuote() {
    final range = _selectedTextBlockRange();
    if (range == null) return;
    final all = _blocks
        .sublist(range.$1, range.$2 + 1)
        .whereType<TextBlock>()
        .toList();
    if (all.isEmpty) return;
    final isAll = all.every((b) => b.containers.any((f) => f is QuoteFrame));
    final newFrame = QuoteFrame(groupId: nextFrameGroupId());
    _mapSelectedTextBlocks((b) {
      if (isAll) {
        final idx = b.containers.lastIndexWhere((f) => f is QuoteFrame);
        if (idx < 0) return b;
        final next = [...b.containers]..removeAt(idx);
        return b.copyWith(containers: next);
      }
      return b.copyWith(containers: [newFrame, ...b.containers]);
    });
  }

  void wrapInContainer(ContainerFrame frame) {
    _mapSelectedTextBlocks(
      (b) => b.copyWith(containers: [frame, ...b.containers]),
    );
  }

  void updateContainerFrame(String groupId, ContainerFrame newFrame) {
    assert(newFrame.groupId == groupId, '保持 groupId 才能不破坏分组');
    if (documentBinding == null) sealHistory();
    final newBlocks = <EditorBlock>[..._blocks];
    var changed = false;
    for (var i = 0; i < newBlocks.length; i++) {
      final b = newBlocks[i];
      if (b is! TextBlock) continue;
      final idx = b.containers.indexWhere((f) => f.groupId == groupId);
      if (idx < 0) continue;
      final next = [...b.containers];
      next[idx] = newFrame;
      newBlocks[i] = b.copyWith(containers: next);
      changed = true;
    }
    if (!changed) return;
    _commit(newBlocks, _selection,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('updateContainerFrame'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  // -----------------------------------------------------------------
  // input rules(markdown 快捷语法,input_rules.dart 调用)
  // -----------------------------------------------------------------

  void applyBlockInputRule(
    String blockId, {
    required int markerLength,
    int lineStart = 0,
    required TextBlock Function(TextBlock) transform,
  }) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    if (lineStart <= 0) {
      final len = markerLength.clamp(0, block.content.length);
      final newBlocks = [..._blocks];
      newBlocks[i] = transform(
        block.copyWith(content: block.content.delete(0, len)),
      );
      _commit(
        newBlocks,
        EditorSelection.collapsed(EditorPosition(blockId: blockId, offset: 0)),
        intent: const EditorStructureIntent('applyBlockInputRule'),
        groupWithPrevious: false,
      );
      sealHistory();
      return;
    }
    if (lineStart > block.content.length) return;
    final markerEnd = (lineStart + markerLength).clamp(
      lineStart,
      block.content.length,
    );
    final (head, tail) = block.content.split(lineStart);
    final newId = _nextId();
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content: head.delete(head.length - 1, head.length),
    );
    newBlocks.insert(
      i + 1,
      transform(
        TextBlock(
          id: newId,
          content: tail.delete(0, markerEnd - lineStart),
          containers: block.containers,
        ),
      ),
    );
    _commit(
      newBlocks,
      EditorSelection.collapsed(EditorPosition(blockId: newId, offset: 0)),
      intent: const EditorStructureIntent('applyBlockInputRule'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void applyImageInputRule(
    String blockId, {
    required int start,
    required int end,
    required InlineNode image,
  }) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    if (end > block.content.length) return;
    final content = block.content.delete(start, end).insertAtom(start, image);
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: blockId, offset: start + 1),
      ),
      intent: const EditorStructureIntent('applyImageInputRule'),
      groupWithPrevious: false,
    );
  }

  void applyLinkInputRule(
    String blockId, {
    required int start,
    required int end,
    required String label,
    required String href,
  }) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    if (end > block.content.length) return;
    final content = block.content
        .delete(start, end)
        .insert(start, label)
        .applyMark(start, start + label.length, MarkKind.link,
            attr: href, isAutoLink: false);
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: blockId, offset: start + label.length),
      ),
      intent: const EditorStructureIntent('applyLinkInputRule'),
      groupWithPrevious: false,
    );
  }

  void applyInlineInputRule(
    String blockId, {
    required int matchStart,
    required int delimLength,
    required int contentLength,
    required MarkKind kind,
    bool caretAtEnd = true,
    int? openLength,
    String? attr,
  }) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    final openLen = openLength ?? delimLength;
    final contentStart = matchStart + openLen;
    final contentEnd = contentStart + contentLength;
    final matchEnd = contentEnd + delimLength;
    if (matchEnd > block.content.length) return;

    var content = block.content
        .delete(contentEnd, matchEnd)
        .delete(matchStart, contentStart);
    content = content.applyMark(
      matchStart,
      matchStart + contentLength,
      kind,
      attr: attr,
    );
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(
          blockId: blockId,
          offset: caretAtEnd ? matchStart + contentLength : matchStart,
        ),
      ),
      intent: const EditorStructureIntent('applyInlineInputRule'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  // -----------------------------------------------------------------
  // 剪贴板(复制/剪切/粘贴)
  // -----------------------------------------------------------------

  List<EditorBlock> copySelectionAsBlocks() {
    final norm = normalizedSelection();
    if (norm == null || _selection!.isCollapsed) return const [];
    var (from, to) = norm;
    var fi = indexOfBlock(from.blockId);
    var ti = indexOfBlock(to.blockId);
    if (fi < 0 || ti < 0) return const [];

    if (_blocks[fi] is IslandBlock && from.offset >= 1) {
      fi += 1;
      if (fi > ti) return const [];
      from = EditorPosition(blockId: _blocks[fi].id, offset: 0);
    }
    if (_blocks[ti] is IslandBlock && to.offset <= 0) {
      ti -= 1;
      if (ti < fi) return const [];
      to = EditorPosition(
        blockId: _blocks[ti].id,
        offset: _blocks[ti].selectionLength,
      );
    }

    final out = <EditorBlock>[];
    for (var i = fi; i <= ti; i++) {
      final b = _blocks[i];
      if (b is IslandBlock) {
        out.add(b);
        continue;
      }
      b as TextBlock;
      final s = i == fi ? from.offset.clamp(0, b.content.length) : 0;
      final e = i == ti
          ? to.offset.clamp(0, b.content.length)
          : b.content.length;
      out.add(b.copyWith(content: b.content.slice(s, e)));
    }
    return out;
  }

  List<EditorBlock> exportBlocks({List<EditorBlock>? fragment}) {
    final source = fragment ?? _blocks;
    if (_mode != EditorMode.ir) return List.unmodifiable(source);
    return List<EditorBlock>.unmodifiable([
      for (final block in source)
        if (block is TextBlock)
          block.copyWith(content: spinInlineMarks(
            block.content,
            caret: 0,
            guardAtCaret: false,
            maxPasses: block.content.length + 1,
          ).content)
        else
          block,
    ]);
  }

  String exportMarkdown({List<EditorBlock>? fragment}) {
    final binding = documentBinding;
    if (binding is EditorDocumentExportBinding) {
      return (binding as EditorDocumentExportBinding).exportDocument(
        _documentBindingState!, fragment: fragment,
      );
    }
    return docToMarkdown(exportBlocks(fragment: fragment));
  }

  String copySelectionAsMarkdown() {
    final binding = documentBinding;
    if (binding is EditorDocumentExportBinding) {
      final selection = _selection;
      if (selection == null || selection.isCollapsed) return '';
      return (binding as EditorDocumentExportBinding).exportSelection(
        _documentBindingState!, selection, blocks: _blocks,
      );
    }
    final blocks = copySelectionAsBlocks();
    if (blocks.isEmpty) return '';
    return exportMarkdown(fragment: blocks);
  }

  void pasteBlocks(List<EditorBlock> fragment) {
    if (documentBinding != null && !_atomicEditActive) {
      return runAtomicEdit(() => pasteBlocks(fragment));
    }
    if (fragment.isEmpty || normalizedSelection() == null) return;
    final draft = EditorState(blocks: _blocks);
    draft._idCounter = _idCounter;
    draft._selection = _selection;
    draft._mode = _mode;
    try {
      draft._pasteBlocksImpl(fragment);
      if (documentBinding == null) {
        _idCounter = draft._idCounter;
        sealHistory();
        _clearPending();
      }
      _commit(draft._blocks, draft._selection,
        sealBeforeCommit: true,
        clearPendingBeforeCommit: true,
        intent: EditorStructureIntent('pasteBlocks', fragment: exportBlocks(fragment: fragment)),
        groupWithPrevious: false,
      );
      if (documentBinding != null) {
        _idCounter = draft._idCounter;
      }
      sealHistory();
    } finally {
      draft.dispose();
    }
  }

  void _pasteBlocksImpl(List<EditorBlock> fragment) {
    if (fragment.isEmpty) return;
    if (normalizedSelection() == null) return;
    if (!(_selection?.isCollapsed ?? true)) {
      deleteSelection();
    }
    final pos = _selection!.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final host = _blocks[i];

    sealHistory();
    _clearPending();

    fragment = _reGroupFragment(fragment);

    if (host is! TextBlock) {
      final newBlocks = [..._blocks];
      final inserted = <EditorBlock>[for (final b in fragment) _reIdBlock(b)];
      newBlocks.insertAll(i + 1, inserted);
      final last = inserted.last;
      _commit(
        newBlocks,
        EditorSelection.collapsed(
          EditorPosition(blockId: last.id, offset: last.selectionLength),
        ),
        intent: const EditorStructureIntent('_pasteBlocksImpl'),
        groupWithPrevious: false,
      );
      sealHistory();
      return;
    }

    final offset = pos.offset.clamp(0, host.content.length);
    final first = fragment.first;

    final firstPlain =
        first is TextBlock && first.containers.isEmpty && first.isParagraph;
    if (fragment.length == 1 && firstPlain) {
      final newBlocks = [..._blocks];
      newBlocks[i] = host.copyWith(
        content: _spliceContent(host.content, offset, first.content),
      );
      _commit(
        newBlocks,
        EditorSelection.collapsed(
          pos.copyWith(offset: offset + first.content.length),
        ),
        intent: const EditorStructureIntent('_pasteBlocksImpl'),
        groupWithPrevious: false,
      );
      sealHistory();
      return;
    }

    final (head, tail) = host.content.split(offset);
    final newBlocks = [..._blocks];
    newBlocks.removeAt(i);

    final assembled = <EditorBlock>[];
    final firstText = firstPlain ? first : null;
    if (firstText != null || head.length > 0) {
      assembled.add(
        host.copyWith(
          content: firstText != null
              ? _spliceContent(head, head.length, firstText.content)
              : head,
        ),
      );
    }

    final last = fragment.last;
    final lastPlain =
        fragment.length > 1 &&
        last is TextBlock &&
        last.containers.isEmpty &&
        last.isParagraph;
    final lastText = lastPlain ? last : null;

    for (
      var k = (firstText != null ? 1 : 0);
      k < fragment.length - (lastText != null ? 1 : 0);
      k++
    ) {
      assembled.add(_reIdBlock(fragment[k]));
    }

    EditorPosition caret;
    if (lastText != null) {
      final tailId = _nextId();
      assembled.add(TextBlock(
        id: tailId,
        content: lastText.content.concat(tail),
        kind: lastText.kind,
        headingLevel: lastText.headingLevel,
        ordered: lastText.ordered,
        depth: lastText.depth,
        listStart: lastText.listStart,
        listLoose: lastText.listLoose,
        containers: lastText.containers,
      ));
      caret = EditorPosition(blockId: tailId, offset: lastText.content.length);
    } else {
      final tailId = _nextId();
      assembled.add(TextBlock(
        id: tailId,
        content: tail,
        kind: host.kind,
        headingLevel: host.headingLevel,
        ordered: host.ordered,
        listLoose: host.listLoose,
        depth: host.depth,
        containers: host.containers,
      ));
      caret = EditorPosition(blockId: tailId, offset: 0);
    }

    newBlocks.insertAll(i, assembled);
    _commit(
      newBlocks,
      EditorSelection.collapsed(caret),
      intent: const EditorStructureIntent('_pasteBlocksImpl'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void pastePlainText(String text) {
    if (documentBinding != null && !_atomicEditActive) {
      return runAtomicEdit(() => pastePlainText(text));
    }
    final sanitized = EditableTextContent.sanitizeText(text)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    if (sanitized.isEmpty) return;
    final paras = sanitized.split('\n\n');
    var n = 0;
    pasteBlocks([for (final p in paras) _paragraphFromMarkdown('p_${n++}', p)]);
  }

  static TextBlock _paragraphFromMarkdown(String id, String source) {
    var body = source;
    var quoted = false;
    if (body.startsWith('> ')) {
      body = body.substring(2);
      quoted = true;
    }
    final heading = RegExp(r'^(#{1,6}) ').firstMatch(body);
    final bullet = RegExp(r'^[-*] ').firstMatch(body);
    final ordered = RegExp(r'^(\d{1,9})[.)] ').firstMatch(body);
    final marker = heading ?? bullet ?? ordered;
    if (marker != null) body = body.substring(marker.group(0)!.length);

    var block = TextBlock(id: id, content: parseInlineMarkdown(body));
    if (heading != null) {
      block = block.asHeading(heading.group(1)!.length);
    } else if (bullet != null) {
      block = block.asListItem(ordered: false);
    } else if (ordered != null) {
      block = block.asListItem(
        ordered: true,
        listStart: int.tryParse(ordered.group(1)!) ?? 1,
      );
    }
    if (quoted) {
      block = block.copyWith(
        containers: [QuoteFrame(groupId: nextFrameGroupId())],
      );
    }
    return block;
  }

  EditorBlock _reIdBlock(EditorBlock b) => switch (b) {
        final TextBlock tb => TextBlock(
            id: _nextId(),
            content: tb.content,
            kind: tb.kind,
            headingLevel: tb.headingLevel,
            ordered: tb.ordered,
            depth: tb.depth,
            listStart: tb.listStart,
            listLoose: tb.listLoose,
            containers: tb.containers,
          ),
        final IslandBlock ib => IslandBlock(id: _nextId(), node: ib.node),
      };

  static List<EditorBlock> _reGroupFragment(List<EditorBlock> fragment) {
    final mapping = <String, String>{};
    ContainerFrame remap(ContainerFrame f) {
      final newId = mapping.putIfAbsent(f.groupId, nextFrameGroupId);
      return switch (f) {
        QuoteFrame() => QuoteFrame(groupId: newId),
        QuoteCardFrame(
          :final username,
          :final displayName,
          :final postNumber,
          :final topicId,
          :final full,
        ) =>
          QuoteCardFrame(
            groupId: newId,
            username: username,
            displayName: displayName,
            postNumber: postNumber,
            topicId: topicId,
            full: full,
          ),
        SpoilerFrame() => SpoilerFrame(groupId: newId),
        DetailsFrame(:final summary, :final open) => DetailsFrame(
          groupId: newId,
          summary: summary,
          open: open,
        ),
        CalloutFrame(
          :final kind,
          :final typeRaw,
          :final title,
          :final foldable,
        ) =>
          CalloutFrame(
            groupId: newId,
            kind: kind,
            typeRaw: typeRaw,
            title: title,
            foldable: foldable,
          ),
      };
    }

    var changed = false;
    final out = <EditorBlock>[];
    for (final b in fragment) {
      if (b is TextBlock && b.containers.isNotEmpty) {
        out.add(
          b.copyWith(containers: [for (final f in b.containers) remap(f)]),
        );
        changed = true;
      } else {
        out.add(b);
      }
    }
    return changed ? out : fragment;
  }

  void updateIslandNode(String islandId, BlockNode newNode) {
    final i = indexOfBlock(islandId);
    if (i < 0 || _blocks[i] is! IslandBlock) return;
    if (documentBinding == null) sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = IslandBlock(id: islandId, node: newNode);
    _commit(newBlocks, _selection,
      sealBeforeCommit: true,
      intent: const EditorStructureIntent('updateIslandNode'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  void replaceIsland(String islandId, List<EditorBlock> fragment) {
    final i = indexOfBlock(islandId);
    if (i < 0 || _blocks[i] is! IslandBlock) return;
    if (documentBinding == null) sealHistory();
    if (documentBinding == null) _clearPending();
    final newBlocks = [..._blocks];
    newBlocks.removeAt(i);
    if (fragment.isEmpty) {
      final anchor = i < newBlocks.length
          ? EditorPosition(blockId: newBlocks[i].id, offset: 0)
          : (newBlocks.isEmpty
                ? null
                : EditorPosition(
                    blockId: newBlocks.last.id,
                    offset: newBlocks.last.selectionLength,
                  ));
      _commit(
        newBlocks,
        anchor == null ? null : EditorSelection.collapsed(anchor),
        clearPendingBeforeCommit: true,
        sealBeforeCommit: true,
        intent: const EditorStructureIntent('replaceIsland'),
        groupWithPrevious: false,
      );
      sealHistory();
      return;
    }
    final inserted = [for (final b in fragment) _reIdBlock(b)];
    newBlocks.insertAll(i, inserted);
    final last = inserted.last;
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: last.id, offset: last.selectionLength),
      ),
      sealBeforeCommit: true,
      clearPendingBeforeCommit: true,
      intent: const EditorStructureIntent('replaceIsland'),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  static EditableTextContent _spliceContent(
    EditableTextContent content,
    int offset,
    EditableTextContent inserted,
  ) {
    final (head, tail) = content.split(offset);
    return head.concat(inserted).concat(tail);
  }

  // -----------------------------------------------------------------
  // 导航
  // -----------------------------------------------------------------

  void selectAll() {
    final first = _blocks.first;
    final last = _blocks.last;
    updateSelection(
      EditorSelection(
        base: EditorPosition(blockId: first.id, offset: 0),
        extent: EditorPosition(blockId: last.id, offset: last.selectionLength),
      ),
    );
  }

  void moveCaretHorizontal(int direction, {bool extend = false}) {
    final sel = _selection;
    if (sel == null) return;
    if (!extend && !sel.isCollapsed) {
      final norm = normalizedSelection()!;
      var target = direction < 0 ? norm.$1 : norm.$2;
      final ti = indexOfBlock(target.blockId);
      if (ti >= 0 && _blocks[ti] is IslandBlock) {
        final moved = direction < 0 ? _positionBefore(ti) : _positionAfter(ti);
        if (moved != null) target = moved;
      }
      updateSelection(EditorSelection.collapsed(target));
      return;
    }
    final pos = sel.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    EditorPosition? next;

    if (block is IslandBlock) {
      if (direction < 0) {
        next = _positionBefore(i);
      } else {
        next = _positionAfter(i);
      }
      if (next == null) return;
      updateSelection(
        extend
            ? EditorSelection(base: sel.base, extent: next)
            : EditorSelection.collapsed(next),
      );
      return;
    }
    block as TextBlock;

    if (direction < 0) {
      if (pos.offset > 0) {
        final before = block.content.text.substring(0, pos.offset);
        final step = before.characters.isEmpty
            ? 1
            : before.characters.last.length;
        next = pos.copyWith(offset: pos.offset - step);
      } else if (i > 0) {
        final prev = _blocks[i - 1];
        if (prev is IslandBlock && !extend) {
          _selectIsland(prev.id);
          return;
        }
        next = prev is IslandBlock
            ? EditorPosition(blockId: prev.id, offset: 0)
            : EditorPosition(
                blockId: prev.id,
                offset: (prev as TextBlock).content.length,
              );
      }
    } else {
      if (pos.offset < block.content.length) {
        final after = block.content.text.substring(pos.offset);
        final step = after.characters.isEmpty
            ? 1
            : after.characters.first.length;
        next = pos.copyWith(
          offset: math.min(pos.offset + step, block.content.length),
        );
      } else if (i + 1 < _blocks.length) {
        final nextBlock = _blocks[i + 1];
        if (nextBlock is IslandBlock && !extend) {
          _selectIsland(nextBlock.id);
          return;
        }
        next = nextBlock is IslandBlock
            ? EditorPosition(blockId: nextBlock.id, offset: 1)
            : EditorPosition(blockId: nextBlock.id, offset: 0);
      }
    }
    if (next == null) {
      if (_lastEditPos != null) {
        _lastEditPos = null;
        notifyListeners();
      }
      return;
    }
    if (extend) {
      updateSelection(EditorSelection(base: sel.base, extent: next));
      return;
    }
    updateSelection(EditorSelection.collapsed(next));
  }

  EditorPosition? _positionBefore(int index) {
    if (index <= 0) return null;
    final prev = _blocks[index - 1];
    return prev is TextBlock
        ? EditorPosition(blockId: prev.id, offset: prev.content.length)
        : EditorPosition(blockId: prev.id, offset: 0);
  }

  EditorPosition? _positionAfter(int index) {
    if (index + 1 >= _blocks.length) return null;
    final next = _blocks[index + 1];
    return EditorPosition(blockId: next.id, offset: 0);
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}