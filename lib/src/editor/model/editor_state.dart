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
import 'inline_markdown_parser.dart';
import 'markdown_serializer.dart';

export 'editor_block.dart';

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

/// 历史快照(undo 单元)。
@immutable
class _HistoryEntry {
  const _HistoryEntry({required this.blocks, required this.selection});

  final List<EditorBlock> blocks;
  final EditorSelection? selection;
}

/// 编辑器状态机。
class EditorState extends ChangeNotifier {
  EditorState({required List<EditorBlock> blocks})
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

  List<EditorBlock> _blocks;
  List<EditorBlock> get blocks => _blocks;

  /// [InputRuleOutcome.calloutRequest] 命中时临时存放匹配到的 callout
  /// 类型(如 "note")。触发规则那一刻就把标记文本清空了,视图层收到
  /// outcome 时已经读不到原始 `[!note]` 字面量,靠这个字段带过去；
  /// 视图层读取后必须清空,一次性消费。
  String? pendingCalloutType;

  /// 文档修订号:每次 [_blocks] 快照替换 +1(选区/composing 变化不计)。
  /// 视图层用它区分「编辑引发的光标移动」(瞬时贴上)与「纯导航」(滑行)。
  int get docRevision => _docRevision;
  int _docRevision = 0;

  EditorSelection? _selection;
  EditorSelection? get selection => _selection;

  /// 当前块内的 composing 区间(编辑文本坐标),empty = 无。
  TextRange _composing = TextRange.empty;
  TextRange get composing => _composing;

  /// mark 末端边界二态(Lexical 边界 affinity 同款):光标 collapsed 且
  /// offset 恰在某 inclusive mark 的 end 时,同一内容坐标分两个瞬态停位
  /// —— false = 内侧(格式内:打字延伸、退格删字),true = 外侧(格式外:
  /// 打字不延伸、退格物化)。光标不在任何 inclusive mark.end 时该值
  /// 无意义(视为 false)。
  ///
  /// 瞬态:只由左右键在 mark.end 上切换(见 [moveCaretHorizontal]);
  /// 点击/程序化选区更新、任何文档事务后归位内侧。
  bool _caretOutsideMarkEnd = false;
  bool get caretOutsideMarkEnd => _caretOutsideMarkEnd;

  /// [pos] 是否恰在某 inclusive mark 的 end(边界二态的适用判定)。
  bool _isAtInclusiveMarkEnd(EditorPosition pos) {
    final block = textBlockById(pos.blockId);
    if (block == null) return false;
    return block.content.marks.any((m) =>
        m.end == pos.offset && EditableTextContent.isInclusiveMark(m));
  }

  bool get hasComposing => _composing.isValid && !_composing.isCollapsed;

  // -----------------------------------------------------------------
  // pending marks(折叠光标 toggle 样式 → 下次输入生效)
  // -----------------------------------------------------------------

  Set<MarkKind>? _pendingMarks;
  EditorPosition? _pendingAnchor;

  /// 当前 pending 样式集(工具栏高亮用;null = 无 pending)。
  Set<MarkKind>? get pendingMarks => _pendingMarks;

  void _clearPending() {
    _pendingMarks = null;
    _pendingAnchor = null;
  }

  int _idCounter = 0;
  String _nextId() => 'e_${_idCounter++}';

  /// 待自动进入编辑态的岛块 id(插入代码块/公式后把光标送进去 ——
  /// 否则用户打完 ``` 回车,光标停在岛外面,还得再点一下)。
  /// 由岛组件消费一次即清空。
  String? _pendingIslandEdit;

  /// 请求 [blockId] 岛插入后自动进入编辑态。
  void requestIslandEdit(String blockId) {
    _pendingIslandEdit = blockId;
    notifyListeners();
  }

  /// 岛组件取用编辑请求(取到即清,不重复触发)。
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

  /// 取文本块(岛/不存在返回 null)。IME/文本事务的守门人。
  TextBlock? textBlockById(String blockId) {
    final b = blockById(blockId);
    return b is TextBlock ? b : null;
  }

  /// 归一化选区:返回 (前位置, 后位置)(按文档序)。
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

  /// 光标处的有效样式集(工具栏高亮):pending 优先,否则取内容。
  Set<MarkKind> effectiveMarksAtCaret() {
    final pending = _pendingMarks;
    if (pending != null) return pending;
    final sel = _selection;
    if (sel == null || !sel.isCollapsed) return const {};
    final block = textBlockById(sel.extent.blockId);
    if (block == null) return const {};
    return block.content.marksAt(sel.extent.offset.clamp(0, block.content.length));
  }

  // -----------------------------------------------------------------
  // 历史
  // -----------------------------------------------------------------

  final List<_HistoryEntry> _undoStack = [];
  final List<_HistoryEntry> _redoStack = [];

  /// 栈顶是否"未封口"(后续同类编辑并入该步)。
  bool _openGroup = false;

  /// 空闲自动封口:连续打字每次续期,停顿 [_sealIdleDelay] 后当前组
  /// 自动 seal —— undo 粒度 = 一阵输入(对齐主流编辑器)。
  Timer? _sealIdleTimer;
  static const Duration _sealIdleDelay = Duration(milliseconds: 800);

  static const int _maxHistory = 200;

  void _recordHistory({required bool groupWithPrevious}) {
    if (groupWithPrevious) {
      _sealIdleTimer?.cancel();
      _sealIdleTimer = Timer(_sealIdleDelay, sealHistory);
    }
    if (groupWithPrevious && _openGroup && _undoStack.isNotEmpty) {
      return;
    }
    _undoStack.add(_HistoryEntry(blocks: _blocks, selection: _selection));
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _redoStack.clear();
    _openGroup = groupWithPrevious;
  }

  /// 封口当前历史组(composition 结束/结构操作/空闲/点击时调用)。
  void sealHistory() {
    _sealIdleTimer?.cancel();
    _sealIdleTimer = null;
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
    _redoStack.add(_HistoryEntry(blocks: _blocks, selection: _selection));
    final entry = _undoStack.removeLast();
    _blocks = entry.blocks;
    _docRevision++;
    // 历史里的选区可能指向已不存在的块/越界偏移,必须 clamp。
    _selection =
        entry.selection == null ? null : _clampSelection(entry.selection!);
    _composing = TextRange.empty;
    _caretOutsideMarkEnd = false;
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    sealHistory();
    _clearPending();
    _undoStack.add(_HistoryEntry(blocks: _blocks, selection: _selection));
    final entry = _redoStack.removeLast();
    _blocks = entry.blocks;
    _docRevision++;
    _selection =
        entry.selection == null ? null : _clampSelection(entry.selection!);
    _composing = TextRange.empty;
    _caretOutsideMarkEnd = false;
    notifyListeners();
  }

  // -----------------------------------------------------------------
  // 选区/composing 更新(不产历史)
  // -----------------------------------------------------------------

  void updateSelection(EditorSelection? selection) {
    if (_selection == selection) {
      // 点击/程序化跳转默认内侧:同位置重设选区也要把外侧态切回来
      // (早退前判断,否则点击同位置永远切不回内侧)。
      if (_caretOutsideMarkEnd) {
        _caretOutsideMarkEnd = false;
        notifyListeners();
      }
      return;
    }
    _caretOutsideMarkEnd = false;
    _selection = selection == null ? null : _clampSelection(selection);
    // 选区跳走 = composition/pending 语境失效。
    _composing = TextRange.empty;
    _clearPending();
    notifyListeners();
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
        // 幽灵块 → 落到最后一个 TextBlock 尾(不变量保证存在)
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
        base: clampPos(sel.base), extent: clampPos(sel.extent));
  }

  /// 全岛文档兜底:确保 [blocks] 至少含一个 TextBlock(尾部补空段)。
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

  /// 唯一的文档快照替换出口(imeReplace 也走这里,无旁路):
  /// [composing] 透传给状态(IME 预编辑标记;非 IME 事务默认清空)。
  void _commit(
    List<EditorBlock> newBlocks,
    EditorSelection? newSelection, {
    required bool groupWithPrevious,
    TextRange composing = TextRange.empty,
  }) {
    _recordHistory(groupWithPrevious: groupWithPrevious);
    _blocks = List.unmodifiable(_ensureTextBlock(newBlocks));
    _docRevision++;
    _selection = newSelection == null ? null : _clampSelection(newSelection);
    _composing = composing;
    // 边界二态收敛点:任何文档事务后归位内侧(外侧打完字光标已在普通
    // 文本内;物化/删除/分块后原停位语境已失效)。
    _caretOutsideMarkEnd = false;
    notifyListeners();
  }

  // -----------------------------------------------------------------
  // 文本事务
  // -----------------------------------------------------------------

  /// 折叠光标处插入文本(打字主路径;选区非折叠时先删)。
  void insertText(String inserted) {
    final sanitized = EditableTextContent.sanitizeText(inserted);
    if (sanitized.isEmpty) return;
    if (normalizedSelection() == null) return;
    if (!(_selection?.isCollapsed ?? true)) {
      deleteSelection();
    }
    final pos = _selection!.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return; // 岛上无文本插入
    // 末端延伸(inclusive marks):粗体末尾继续打字 = 继续粗体。
    // pending marks 命中锚点时用户意图已显式给出,不做隐式延伸;
    // 边界二态外侧停位 = 用户显式走出格式,同样不延伸(mark 到段末时
    // 这是追加普通文本的唯一出口)。
    var content = block.content.insert(
      pos.offset,
      sanitized,
      extendMarksAtEnd: !_caretOutsideMarkEnd &&
          (_pendingMarks == null || _pendingAnchor != pos),
    );
    // pending marks:命中锚点时对插入区间施加
    if (_pendingMarks != null && _pendingAnchor == pos) {
      content = content.applyExactMarks(
        pos.offset,
        pos.offset + sanitized.length,
        _pendingMarks!,
      );
      _clearPending();
    }
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        pos.copyWith(offset: pos.offset + sanitized.length),
      ),
      groupWithPrevious: true,
    );
  }

  /// 折叠光标处插入原子(emoji picker / mention 补全 / 测试)。
  void insertAtom(InlineNode atom) {
    if (normalizedSelection() == null) return;
    if (!(_selection?.isCollapsed ?? true)) {
      deleteSelection();
    }
    final pos = _selection!.extent;
    final i = indexOfBlock(pos.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content: block.content.insertAtom(pos.offset, atom),
    );
    _commit(
      newBlocks,
      EditorSelection.collapsed(pos.copyWith(offset: pos.offset + 1)),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// 替换 [blockId] 块 [offset] 处的原子(date chip 编辑确认 / 图片
  /// 缩放/改 alt)。该位置不是原子时无操作。undo 一步。
  ///
  /// [reselect]:true 时 commit 后保持原子整选 [offset, offset+1] ——
  /// 图片工具条动作后浮层不消失、disabled 态原位刷新(官方 scale 后
  /// setSelection(NodeSelection) 同语义);false(默认)光标折叠到
  /// 原子后(date chip 现行为)。
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
    sealHistory();
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
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// 用 [replacement] 替换 blocks[start..end](**含端点**),单 _commit =
  /// 单 undo 步。图片「加入网格」等跨块结构命令的事务底座 —— 两个块的
  /// 改写若分两次 commit 会产生两个 undo 步且中间态是「图凭空消失」。
  void replaceBlockRange(
    int start,
    int end,
    List<EditorBlock> replacement, {
    EditorSelection? selection,
  }) {
    assert(start >= 0 && end < _blocks.length && start <= end);
    sealHistory();
    _clearPending();
    final newBlocks = [
      ..._blocks.sublist(0, start),
      ...replacement,
      ..._blocks.sublist(end + 1),
    ];
    _commit(newBlocks, selection ?? _selection, groupWithPrevious: false);
    sealHistory();
  }

  /// 块 id 发号(结构命令新建块用,与内部序列一致不撞号)。
  String nextBlockId() => _nextId();

  /// 在 [blockId] 之后插入孤岛块。
  void insertIslandAfter(String blockId, BlockNode node) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    sealHistory();
    final islandId = _nextId();
    final newBlocks = [..._blocks];
    newBlocks.insert(i + 1, IslandBlock(id: islandId, node: node));
    _commit(
      newBlocks,
      EditorSelection.collapsed(EditorPosition(blockId: islandId, offset: 1)),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// IME 主路径:替换 [blockId] 块内 `[start, end)` 为 [replacement],
  /// 光标置于 [caretOffset],composing 透传。
  ///
  /// `start == end && replacement.isEmpty` = 纯选区/composing 更新
  /// (IME 移动光标 / 仅更新 composing 标记),**不记历史**。
  ///
  /// [replacement] 应已由调用方(EditorImeClient)sanitize。
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
      _selection = _clampSelection(EditorSelection.collapsed(
        EditorPosition(blockId: blockId, offset: caretOffset),
      ));
      _composing = composing;
      // 平台驱动的纯光标移动:边界二态归位内侧(与 updateSelection 同语义)
      _caretOutsideMarkEnd = false;
      notifyListeners();
      return;
    }

    // 末端延伸(inclusive marks;仅纯插入形态生效,replace 内部判定):
    // 粗体末尾继续打字 = 继续粗体。pending 锚点命中时不隐式延伸(下方
    // applyExactMarks 按用户显式意图整段重设);边界二态外侧停位同样
    // 不延伸(用户显式走出格式)。
    final pendingHit = _pendingMarks != null &&
        _pendingAnchor != null &&
        _pendingAnchor!.blockId == blockId &&
        _pendingAnchor!.offset == safeStart;
    var content = block.content.replace(
      safeStart,
      safeEnd,
      replacement,
      extendMarksAtEnd: !_caretOutsideMarkEnd && !pendingHit,
    );
    // pending marks:替换起点命中锚点(打字第一个字符)时施加。
    // composing 进行中保留 pending(候选切换会反复 replace 同区间)。
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
      final composingActive = composing.isValid && !composing.isCollapsed;
      if (!composingActive) _clearPending();
    }
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: blockId, offset: caretOffset),
      ),
      groupWithPrevious: true,
      composing: composing,
    );
  }

  /// 删除当前选区(跨块支持;孤岛按端点四象限归一)。
  void deleteSelection() {
    final norm = normalizedSelection();
    if (norm == null) return;
    var (from, to) = norm;
    if (_selection!.isCollapsed) return;
    sealHistory();
    _clearPending();

    var fi = indexOfBlock(from.blockId);
    var ti = indexOfBlock(to.blockId);
    if (fi < 0 || ti < 0) return;

    // 端点四象限归一:岛端点按 offset 决定计入/保留。
    if (_blocks[fi] is IslandBlock) {
      if (from.offset >= 1) {
        // 起于岛后 → 岛保留,起点顺移到下一块头
        fi += 1;
        if (fi > ti) return;
        from = EditorPosition(blockId: _blocks[fi].id, offset: 0);
      } else {
        from = EditorPosition(blockId: _blocks[fi].id, offset: 0);
      }
    }
    if (_blocks[ti] is IslandBlock) {
      if (to.offset <= 0) {
        // 止于岛前 → 岛保留,终点回移到上一块尾
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
        newBlocks.add(fromBlock.copyWith(
          content: fromBlock.content.delete(from.offset, to.offset),
        ));
        caret = EditorSelection.collapsed(from).extent;
      }
      // 单岛整选:直接不加(删除),光标落到邻近文本块(clamp 兜底)
      caret ??= from;
    } else {
      // 首块残余
      EditableTextContent? headContent;
      TextBlock? headBlock;
      if (fromBlock is TextBlock) {
        headBlock = fromBlock;
        headContent =
            fromBlock.content.delete(from.offset, fromBlock.content.length);
      }
      // 尾块残余
      EditableTextContent? tailContent;
      TextBlock? tailBlock;
      if (toBlock is TextBlock) {
        tailBlock = toBlock;
        tailContent = toBlock.content.delete(0, to.offset);
      }

      if (headBlock != null && tailContent != null) {
        // 文-文:合并(首块 kind 胜出)
        newBlocks.add(headBlock.copyWith(
          content: headContent!.concat(tailContent),
        ));
        caret = EditorPosition(blockId: headBlock.id, offset: from.offset);
      } else if (headBlock != null) {
        // 文-岛:首块残余保留,岛删除
        newBlocks.add(headBlock.copyWith(content: headContent!));
        caret = EditorPosition(blockId: headBlock.id, offset: from.offset);
      } else if (tailBlock != null) {
        // 岛-文:尾块残余保留
        newBlocks.add(tailBlock.copyWith(content: tailContent!));
        caret = EditorPosition(blockId: tailBlock.id, offset: 0);
      }
      // 岛-岛:两端都删,caret 由 clamp 兜底
      caret ??= from;
    }

    newBlocks.addAll(_blocks.sublist(ti + 1));
    _commit(
      newBlocks,
      EditorSelection.collapsed(caret),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// 光标前删一个 grapheme(折叠态 Backspace)。
  ///
  /// - 块首 + 前块是文本块 → 合并;
  /// - 块首 + 前块是岛 → **第一次整选岛**(两段式删除,再按才删);
  /// - 光标在岛上(整选态由 deleteSelection 处理,折叠在岛 offset 上
  ///   理论不出现,防御为选中岛)。
  void backspace() {
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
      // 列表项/容器块首退格:先降级(语义表),不合并。
      if (block.isListItem) {
        if (block.depth > 0) {
          _updateBlockAttrs(i, block.copyWith(depth: block.depth - 1));
        } else {
          _updateBlockAttrs(i, block.asParagraph());
        }
        return;
      }
      if (block.containers.isNotEmpty) {
        // 弹出最内层容器(退出 quote/spoiler/details/callout 一层)
        _updateBlockAttrs(
          i,
          block.copyWith(
            containers:
                block.containers.sublist(0, block.containers.length - 1),
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
    // 闭端退格 = 拆标记:光标恰在某 mark.end(显形态,闭定界符紧贴
    // 光标左边)时,第一次退格不删正文字符,而是把该 mark 物化为字面
    // 定界符;物化后光标在闭定界符末尾,再退格走常规路径删字面字符,
    // 行为连贯。开端(mark.start)不触发 —— 普通退格删前一字符、mark
    // 区间自然收缩,现有行为已合理。
    //
    // 边界二态:inclusive mark.end 上物化只在**外侧**停位触发 ——
    // 内侧退格 = 删格式内最后一个字符(mark 自然收缩),否则「删最后
    // 一个字」会意外把 mark 拆成字面。非 inclusive(link/inlineCode/
    // 带 attr)的 end 没有内侧停位,恒视为外侧,物化行为不变。
    final atInclusiveEnd = _isAtInclusiveMarkEnd(pos);
    if ((!atInclusiveEnd || _caretOutsideMarkEnd) &&
        _tryMaterializeAtMarkEnd(block, pos)) {
      return;
    }
    // 找光标前一个 grapheme 的起点(原子 FFFC 恒 1)
    final before = block.content.text.substring(0, pos.offset);
    final lastCluster =
        before.characters.isEmpty ? '' : before.characters.last;
    final delStart = pos.offset - lastCluster.length;
    final newBlocks = [..._blocks];
    newBlocks[i] =
        block.copyWith(content: block.content.delete(delStart, pos.offset));
    _commit(
      newBlocks,
      EditorSelection.collapsed(pos.copyWith(offset: delStart)),
      groupWithPrevious: true,
    );
  }

  /// 闭端退格的物化判定:collapsed 光标恰在某 mark.end(显形判定
  /// [EditableTextContent.revealableMarksAt] 对 end==caret 恒命中)时,
  /// 取**最内层**的那个 mark 物化,返回 true(一次退格拆一层)。
  ///
  /// 最内层口径与显形定界符的闭合发射序(toInlines.appendDelimiters)
  /// 同源:start 更大 = 更内层;同界按 [kMarkNestingOrder] 更靠后为内。
  bool _tryMaterializeAtMarkEnd(TextBlock block, EditorPosition pos) {
    MarkSpan? target;
    for (final m in block.content.marks) {
      if (m.end != pos.offset) continue;
      // 定界符文案覆盖不了的 kind 不参与(物化会 no-op,退格必须照常删字)
      if (markOpeningDelimiter(m).isEmpty && markClosingDelimiter(m).isEmpty) {
        continue;
      }
      if (target == null ||
          m.start > target.start ||
          (m.start == target.start &&
              kMarkNestingOrder.indexOf(m.kind) >
                  kMarkNestingOrder.indexOf(target.kind))) {
        target = m;
      }
    }
    if (target == null) return false;
    materializeMarkAt(block.id, target);
    return true;
  }

  /// 光标后删一个 grapheme(Forward Delete;段尾对岛同样两段式)。
  void deleteForward() {
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
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content: block.content.delete(pos.offset, pos.offset + step),
    );
    _commit(
      newBlocks,
      EditorSelection.collapsed(pos),
      groupWithPrevious: true,
    );
  }

  void _selectIsland(String islandId) {
    sealHistory();
    updateSelection(EditorSelection(
      base: EditorPosition(blockId: islandId, offset: 0),
      extent: EditorPosition(blockId: islandId, offset: 1),
    ));
  }

  /// 回车是否插**软换行**(段内 `\n` → cook 成 `<br>`)而非新建块。
  ///
  /// 宿主偏好,硬件按键链与 IME 两条回车路径共用(见 [insertNewline])。
  /// 默认 false = 保持"回车即分块"的历史语义,由宿主显式打开。
  ///
  /// 背景:块间序列化用 `\n\n`,cook 成两个 `<p>`,行距比 Discourse
  /// 网页版 composer(回车插单个 `\n`)明显大。
  bool enterInsertsSoftBreak = false;

  /// 回车的统一入口:按 [enterInsertsSoftBreak] 决定软换行还是分块。
  ///
  /// 列表项、标题、容器内的块始终分块 —— 前两者要接着开下一条 / 退出
  /// 标题,软换行没有意义;容器内(引用/剧透/…)必须走 splitBlock,
  /// 因为"回车退出容器"的逐级弹出只写在 splitBlock 里 —— 若软换行只
  /// insertText('\n'),光标会被永远困在容器最后一个非空段里,回车多少
  /// 次都出不去(容器内软换行本身对 BBCode/blockquote 序列化也没意义)。
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

  /// 光标处回车分块(属性感知,语义表见计划)。
  void splitBlock() {
    final sel = _selection;
    if (sel == null) return;
    // 岛整选态回车:不删岛,岛后建空段(Notion 等主流的"选中块回车")。
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

    // 岛上折叠光标回车:offset 0 → 岛前建段;1 → 岛后建段。
    if (block is IslandBlock) {
      _insertParagraphNear(i, after: pos.offset > 0);
      return;
    }
    block as TextBlock;

    // 空列表项回车:原地降级(逐级退出),不分裂。
    if (block.isListItem && block.content.length == 0) {
      if (block.depth > 0) {
        _updateBlockAttrs(i, block.copyWith(depth: block.depth - 1));
      } else {
        _updateBlockAttrs(i, block.asParagraph());
      }
      return;
    }
    // 容器内空段回车:弹出最内层容器(逐级退出 quote/spoiler/…)。
    if (block.containers.isNotEmpty &&
        block.isParagraph &&
        block.content.length == 0) {
      _updateBlockAttrs(
        i,
        block.copyWith(
          containers:
              block.containers.sublist(0, block.containers.length - 1),
        ),
      );
      return;
    }

    sealHistory();
    final (before, after) = block.content.split(pos.offset);
    final newId = _nextId();

    // 新块属性:heading 尾回车 → 段落;其余继承(heading 中部两半同级,
    // listItem 同 kind/depth,容器同栈)。
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
                depth: b.depth,
                // listStart 只属于 run 首项,分裂出的新项不带
                containers: b.containers,
              ));
    }

    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: before);
    newBlocks.insert(i + 1, newBlock);
    _commit(
      newBlocks,
      EditorSelection.collapsed(EditorPosition(blockId: newId, offset: 0)),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// 在 [index] 块前/后插入空段并聚焦(岛回车路径共用)。
  /// 在岛前/后插入空段并落光标(岛选中态「加段」把手;splitBlock 的
  /// 岛路径同语义,公开给视图层直调)。
  void insertParagraphNearIsland(String islandId, {required bool after}) {
    final i = indexOfBlock(islandId);
    if (i < 0 || _blocks[i] is! IslandBlock) return;
    _insertParagraphNear(i, after: after);
  }

  void _insertParagraphNear(int index, {required bool after}) {
    if (index < 0) return;
    sealHistory();
    final newId = _nextId();
    final newBlocks = [..._blocks];
    newBlocks.insert(
      after ? index + 1 : index,
      TextBlock(id: newId, content: EditableTextContent.empty),
    );
    _commit(
      newBlocks,
      EditorSelection.collapsed(EditorPosition(blockId: newId, offset: 0)),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// [blockId] 与上一块合并(块首退格;前块 kind 胜出)。
  /// 首块/前块是岛时无操作(岛路径由 backspace 处理)。
  void mergeWithPrevious(String blockId) {
    final i = indexOfBlock(blockId);
    if (i <= 0) return;
    final prev = _blocks[i - 1];
    final cur = _blocks[i];
    if (prev is! TextBlock || cur is! TextBlock) return;
    sealHistory();
    final joinOffset = prev.content.length;
    final newBlocks = [..._blocks];
    newBlocks[i - 1] = prev.copyWith(content: prev.content.concat(cur.content));
    newBlocks.removeAt(i);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: prev.id, offset: joinOffset),
      ),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  // -----------------------------------------------------------------
  // 格式命令
  // -----------------------------------------------------------------

  /// toggle 行内样式:选区非空 → 区间 toggle;折叠 → pending(下次输入生效)。
  ///
  /// [MarkKind.link] 不走本方法(带 href,用 [applyLink]/[removeLink])。
  void toggleMark(MarkKind kind) {
    assert(kind != MarkKind.link, 'link 用 applyLink/removeLink');
    final sel = _selection;
    if (sel == null) return;

    if (sel.isCollapsed) {
      final block = textBlockById(sel.extent.blockId);
      if (block == null) return;
      final current = _pendingMarks ??
          block.content
              .marksAt(sel.extent.offset.clamp(0, block.content.length));
      final next = {...current};
      if (!next.remove(kind)) next.add(kind);
      _pendingMarks = next;
      _pendingAnchor = sel.extent;
      notifyListeners();
      return;
    }

    // 区间 toggle:M2 仅支持单块选区(跨块 toggle 到 M3 与序列化一起做)。
    final norm = normalizedSelection()!;
    final (from, to) = norm;
    if (from.blockId != to.blockId) return;
    final i = indexOfBlock(from.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(
      content:
          block.content.toggleMarkInRange(from.offset, to.offset, kind),
    );
    _commit(newBlocks, sel, groupWithPrevious: false);
    sealHistory();
  }

  /// 对选区施加链接(单块选区;覆盖旧链接)。折叠选区无操作 ——
  /// 视图层负责"无选区时插入 [text](url) 文本"的路径。
  void applyLink(String href) {
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
      content: block.content
          .applyMark(from.offset, to.offset, MarkKind.link, attr: href),
    );
    _commit(newBlocks, _selection, groupWithPrevious: false);
    sealHistory();
  }

  /// 移除选区上的链接(单块选区)。
  void removeLink() {
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
      content: block.content.removeMark(from.offset, to.offset, MarkKind.link),
    );
    _commit(newBlocks, _selection, groupWithPrevious: false);
    sealHistory();
  }

  /// 物化事务:把 [mark] 从样式区间还原为**真实字面文本**(投影显形的
  /// 反向操作)。mark 摘除,mark.start 前插开定界符、mark.end 后插闭
  /// 定界符(与序列化 [markOpeningDelimiter]/[markClosingDelimiter]
  /// 单一真相),文本变成普通可编辑内容 —— 用户改完字面(`**`→`*`)
  /// 由 input rules 重新识别折叠。
  ///
  /// - 单次 _commit = 独立 undo 步(undo 一步整体回滚:mark 回来、
  ///   字面消失、光标还原);
  /// - 只物化目标 mark:其余 marks/atoms 经 [EditableTextContent.insert]
  ///   的区间调整语义平移(跨插入点的区间拉伸、其后的整体右移),
  ///   先插闭定界符再插开(先尾后头,避免偏移平移);
  /// - [mark] 必须是 content.marks 里现存的区间(displaced/陈旧 span
  ///   无操作);
  /// - **边界(本阶段不做)**:link 的 href 原位编辑走物化后的字面
  ///   `](href)` 修改;原子(图片/emoji/date chip)不参与物化 ——
  ///   它们没有"字面定界符"形态,序列化时整体重写。
  void materializeMarkAt(String blockId, MarkSpan mark) {
    final i = indexOfBlock(blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock) return;
    final content = block.content;
    if (!content.marks.contains(mark)) return;
    final opening = markOpeningDelimiter(mark);
    final closing = markClosingDelimiter(mark);
    if (opening.isEmpty && closing.isEmpty) return; // 覆盖不了的 kind
    sealHistory();
    _clearPending();
    // 摘掉目标 mark(其余 marks/atoms 原样),再插字面定界符
    var next = EditableTextContent(
      text: content.text,
      marks: [
        for (final m in content.marks)
          if (m != mark) m,
      ],
      atoms: content.atoms,
    );
    next = next.insert(mark.end, closing);
    next = next.insert(mark.start, opening);
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: next);
    _commit(
      newBlocks,
      // 光标落在物化后的闭定界符末尾(mark.end 处退格触发的自然落点:
      // 再退格 = 删字面字符,行为连贯)
      EditorSelection.collapsed(EditorPosition(
        blockId: blockId,
        offset: mark.end + opening.length + closing.length,
      )),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  // -----------------------------------------------------------------
  // 块命令
  // -----------------------------------------------------------------

  /// 选区(或光标)覆盖的 TextBlock 下标区间;无选区返回 null。
  (int, int)? _selectedTextBlockRange() {
    final norm = normalizedSelection();
    if (norm == null) return null;
    final fi = indexOfBlock(norm.$1.blockId);
    final ti = indexOfBlock(norm.$2.blockId);
    if (fi < 0 || ti < 0) return null;
    return (fi, ti);
  }

  void _updateBlockAttrs(int index, TextBlock updated) {
    sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[index] = updated;
    _commit(newBlocks, _selection, groupWithPrevious: false);
    sealHistory();
  }

  /// 批量改写选区覆盖的文本块(结构命令共用)。
  void _mapSelectedTextBlocks(TextBlock Function(TextBlock) f) {
    final range = _selectedTextBlockRange();
    if (range == null) return;
    sealHistory();
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
    _commit(newBlocks, _selection, groupWithPrevious: false);
    sealHistory();
  }

  /// 设置标题级别;null = 回段落。
  void setHeading(int? level) => _mapSelectedTextBlocks(
        (b) => level == null ? b.asParagraph() : b.asHeading(level),
      );

  /// toggle 标题:选区全为该级 heading → 回段落;否则设为该级。
  void toggleHeading(int level) {
    final range = _selectedTextBlockRange();
    if (range == null) return;
    final all = _blocks
        .sublist(range.$1, range.$2 + 1)
        .whereType<TextBlock>()
        .toList();
    if (all.isEmpty) return;
    final isAll =
        all.every((b) => b.isHeading && b.headingLevel == level);
    setHeading(isAll ? null : level);
  }

  /// toggle 列表:选区全为同类列表 → 还原段落;否则统一转为该类列表。
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

  /// 列表项缩进(Tab)。上限 = 前一相邻 listItem.depth + 1。
  void indentListItem() {
    final sel = _selection;
    if (sel == null || !sel.isCollapsed) return;
    final i = indexOfBlock(sel.extent.blockId);
    if (i < 0) return;
    final block = _blocks[i];
    if (block is! TextBlock || !block.isListItem) return;
    final prev = i > 0 ? _blocks[i - 1] : null;
    final maxDepth =
        prev is TextBlock && prev.isListItem ? prev.depth + 1 : 0;
    if (block.depth >= maxDepth) return;
    _updateBlockAttrs(i, block.copyWith(depth: block.depth + 1));
  }

  /// 列表项反缩进(Shift+Tab):depth>0 减层;0 → 退出列表。
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

  /// toggle 引用:选区覆盖块全在引用内 → 弹出最外层 Quote;否则包一层。
  void toggleQuote() {
    final range = _selectedTextBlockRange();
    if (range == null) return;
    final all = _blocks
        .sublist(range.$1, range.$2 + 1)
        .whereType<TextBlock>()
        .toList();
    if (all.isEmpty) return;
    final isAll = all.every((b) => b.containers.any((f) => f is QuoteFrame));
    // 包层:选区覆盖块共享**同一个**新帧(一个引用包全部)
    final newFrame = QuoteFrame(groupId: nextFrameGroupId());
    _mapSelectedTextBlocks((b) {
      if (isAll) {
        // 弹出最内层的 QuoteFrame(保留其他容器)
        final idx = b.containers.lastIndexWhere((f) => f is QuoteFrame);
        if (idx < 0) return b;
        final next = [...b.containers]..removeAt(idx);
        return b.copyWith(containers: next);
      }
      // 外面再包一层引用(栈头插入 —— 语义上新引用包住现有容器)
      return b.copyWith(
        containers: [newFrame, ...b.containers],
      );
    });
  }

  /// 对选区覆盖块统一包一层容器(工具栏/插入菜单:spoiler/details/
  /// callout 可进入化)。包在最外层。
  void wrapInContainer(ContainerFrame frame) {
    _mapSelectedTextBlocks(
      (b) => b.copyWith(containers: [frame, ...b.containers]),
    );
  }

  /// 全文档替换 [groupId] 容器帧为 [newFrame](壳标题原位编辑:改
  /// details summary / callout title)。newFrame 沿用同 groupId ——
  /// 分组身份不变,壳 Element 复用,只有属性变。undo 一步。
  void updateContainerFrame(String groupId, ContainerFrame newFrame) {
    assert(newFrame.groupId == groupId, '保持 groupId 才能不破坏分组');
    sealHistory();
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
    _commit(newBlocks, _selection, groupWithPrevious: false);
    sealHistory();
  }

  // -----------------------------------------------------------------
  // input rules(markdown 快捷语法,input_rules.dart 调用)
  // -----------------------------------------------------------------

  /// 块级规则应用:删标记字符 + [transform] 换块属性,光标落到内容起点。
  /// 独立 undo 步(undo 回到字面文本)。
  ///
  /// [lineStart]:标记所在**软行**的行首偏移(input_rules 计算)。0 =
  /// 块首,整块转换(原语义);> 0 = 软换行段内的第二行起 —— 块在该处
  /// 分裂:行首前的内容(去掉分隔的 '\n')留在原块,当前软行起的内容
  /// 成为新块并应用 [transform],光标落新块起点。
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
        groupWithPrevious: false,
      );
      sealHistory();
      return;
    }
    // 软行触发:块分裂。lineStart-1 处必是 '\n'(input_rules 的行首定义)。
    if (lineStart > block.content.length) return;
    final markerEnd =
        (lineStart + markerLength).clamp(lineStart, block.content.length);
    final (head, tail) = block.content.split(lineStart);
    final newId = _nextId();
    final newBlocks = [..._blocks];
    // 去掉 head 尾部的软换行分隔符(它只是两行的分隔,分裂后不该留)。
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
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// 行内规则应用:`[matchStart, matchStart+delim+content+delim)` 区间,
  /// 删两侧定界符、对内容施加 [kind],光标落内容尾。独立 undo 步。
  /// `![alt](src)` input rule:整段字面换成图片原子。
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
      groupWithPrevious: false,
    );
  }

  /// `[文字](href)` input rule:留下文字,href 进 link mark 的 attr。
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
        .applyMark(start, start + label.length, MarkKind.link, attr: href);
    final newBlocks = [..._blocks];
    newBlocks[i] = block.copyWith(content: content);
    _commit(
      newBlocks,
      EditorSelection.collapsed(
        EditorPosition(blockId: blockId, offset: start + label.length),
      ),
      groupWithPrevious: false,
    );
  }

  void applyInlineInputRule(
    String blockId, {
    required int matchStart,
    required int delimLength,
    required int contentLength,
    required MarkKind kind,
    /// 光标落在内容尾(默认,对应"刚打完闭定界符")还是内容首。
    ///
    /// 补打**开**定界符时光标本来就在内容首,甩到尾巴上等于替用户跳一次
    /// 光标 —— 那不是他的意图。
    bool caretAtEnd = true,
    /// 开定界符长度(不传则同 [delimLength],对称定界符如 `**`/`~~`)。
    /// BBCode 属性标记(`[size=150]`/`[/size]`)开闭不等长,需要分开传。
    int? openLength,
    /// mark 附加值(color/size 的色值/百分比),同 [MarkSpan.attr]。
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

    // 先删尾定界符再删头(避免偏移平移),再对留下的内容区间加 mark
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
      groupWithPrevious: false,
    );
    sealHistory();
  }

  // -----------------------------------------------------------------
  // 剪贴板(复制/剪切/粘贴)
  // -----------------------------------------------------------------

  /// 提取当前选区为独立块片段(复制)。空/折叠选区返回空表。
  ///
  /// 端点四象限与 [deleteSelection] 同口径:岛端点 @0/@1 决定计入与否;
  /// 文本块取 slice 子区间。块属性(kind/depth/quote)原样保留 ——
  /// 序列化 markdown 后列表/标题/引用结构不丢。
  List<EditorBlock> copySelectionAsBlocks() {
    final norm = normalizedSelection();
    if (norm == null || _selection!.isCollapsed) return const [];
    var (from, to) = norm;
    var fi = indexOfBlock(from.blockId);
    var ti = indexOfBlock(to.blockId);
    if (fi < 0 || ti < 0) return const [];

    // 岛端点归一(deleteSelection 同款四象限)
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
        out.add(b); // 原引用直存(不可变节点,共享安全)
        continue;
      }
      b as TextBlock;
      final s = i == fi ? from.offset.clamp(0, b.content.length) : 0;
      final e = i == ti ? to.offset.clamp(0, b.content.length) : b.content.length;
      out.add(b.copyWith(content: b.content.slice(s, e)));
    }
    return out;
  }

  /// 当前选区 → markdown(系统剪贴板文本;跨 app 粘贴通用格式)。
  String copySelectionAsMarkdown() {
    final blocks = copySelectionAsBlocks();
    if (blocks.isEmpty) return '';
    return docToMarkdown(blocks);
  }

  /// 粘贴块片段(内部结构化路径;markdown → 块由视图层经 cook 链路转)。
  ///
  /// 拼接语义(主流编辑器):
  /// - 片段首块与光标块**内联合并**(纯文本类内容接在光标处,光标块
  ///   属性胜出);
  /// - 中间块整块插入(re-id 防碰撞);
  /// - 片段尾块与光标块尾段合并;单块片段=纯内联插入。
  /// - 首/尾块是岛 → 不合并,按整块插入。
  void pasteBlocks(List<EditorBlock> fragment) {
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

    // 片段容器帧 groupId 重发(自我复制粘贴时旧 id 会与原文档同组吸并;
    // 片段内同组映射同一个新 id —— 粘贴的多块卡保持一张卡)。
    fragment = _reGroupFragment(fragment);

    // 光标在岛上(理论只有整选态,防御):落到岛后插整段
    if (host is! TextBlock) {
      final newBlocks = [..._blocks];
      final inserted = <EditorBlock>[
        for (final b in fragment) _reIdBlock(b),
      ];
      newBlocks.insertAll(i + 1, inserted);
      final last = inserted.last;
      _commit(
        newBlocks,
        EditorSelection.collapsed(
          EditorPosition(blockId: last.id, offset: last.selectionLength),
        ),
        groupWithPrevious: false,
      );
      sealHistory();
      return;
    }

    final offset = pos.offset.clamp(0, host.content.length);
    final first = fragment.first;

    // 单**纯段落**片段:纯内联并入(不分裂宿主)。带块属性的单块
    // (容器壳/列表项/标题)不能内联 —— 内联只拿 content,容器帧/
    // 列表性会静默蒸发(插入菜单 [quote]/[spoiler] 模板全是这形态)。
    final firstPlain = first is TextBlock &&
        first.containers.isEmpty &&
        first.isParagraph;
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
        groupWithPrevious: false,
      );
      sealHistory();
      return;
    }

    // 多块(或带块属性的单块):宿主在光标处劈开,纯段落首块并入前半,
    // 纯段落尾块并入后半;带块属性的首/尾块整块插入。
    final (head, tail) = host.content.split(offset);
    final newBlocks = [..._blocks];
    newBlocks.removeAt(i);

    final assembled = <EditorBlock>[];
    // 首块内联并入条件 = 纯段落(同上);否则整块插入
    final firstText = firstPlain ? first : null;
    // 宿主前半:有内容、或首块要并入时保留;空且不并入 → 不留孤儿空段
    // (空文档插容器模板不该在壳上方多一个空行)
    if (firstText != null || head.length > 0) {
      assembled.add(host.copyWith(
        content: firstText != null
            ? _spliceContent(head, head.length, firstText.content)
            : head,
      ));
    }

    final last = fragment.last;
    final lastPlain = fragment.length > 1 &&
        last is TextBlock &&
        last.containers.isEmpty &&
        last.isParagraph;
    final lastText = lastPlain ? last : null;

    for (var k = (firstText != null ? 1 : 0);
        k < fragment.length - (lastText != null ? 1 : 0);
        k++) {
      assembled.add(_reIdBlock(fragment[k]));
    }

    EditorPosition caret;
    if (lastText != null) {
      // 纯段落尾块:并入宿主后半(tail 接在其后)
      final tailId = _nextId();
      assembled.add(TextBlock(
        id: tailId,
        content: lastText.content.concat(tail),
        kind: lastText.kind,
        headingLevel: lastText.headingLevel,
        ordered: lastText.ordered,
        depth: lastText.depth,
        listStart: lastText.listStart,
        containers: lastText.containers,
      ));
      caret = EditorPosition(blockId: tailId, offset: lastText.content.length);
    } else {
      // 尾块整块插入(岛/容器块/列表项):tail 残余单独成段。
      // tail 为空也保留 —— 容器/岛后的空段是继续打字的落点
      // (官方 trailing paragraph 惯例)。
      final tailId = _nextId();
      assembled.add(TextBlock(
        id: tailId,
        content: tail,
        kind: host.kind,
        headingLevel: host.headingLevel,
        ordered: host.ordered,
        depth: host.depth,
        containers: host.containers,
      ));
      caret = EditorPosition(blockId: tailId, offset: 0);
    }

    newBlocks.insertAll(i, assembled);
    _commit(
      newBlocks,
      EditorSelection.collapsed(caret),
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// 纯文本粘贴降级(cook 不可用/剪贴板无结构):按换行拆段插入。
  void pastePlainText(String text) {
    final sanitized = EditableTextContent.sanitizeText(text)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    if (sanitized.isEmpty) return;
    // 双换行 = 分段;单换行 = 段内硬换行(与 markdown 语义一致)
    final paras = sanitized.split('\n\n');
    var n = 0;
    pasteBlocks([
      for (final p in paras) _paragraphFromMarkdown('p_${n++}', p),
    ]);
  }

  /// 一段纯文本 → 块:行首块级标记(`# `/`- `/`1. `/`> `)转结构,
  /// 正文走轻量行内解析(`**加粗**` 不该原样躺成字面星号)。
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

  /// 片段块重发 id(粘贴片段可能来自本文档自身的复制,原 id 会碰撞)。
  EditorBlock _reIdBlock(EditorBlock b) => switch (b) {
        final TextBlock tb => TextBlock(
            id: _nextId(),
            content: tb.content,
            kind: tb.kind,
            headingLevel: tb.headingLevel,
            ordered: tb.ordered,
            depth: tb.depth,
            listStart: tb.listStart,
            containers: tb.containers,
          ),
        final IslandBlock ib => IslandBlock(id: _nextId(), node: ib.node),
      };

  /// 片段容器帧 groupId 重发:片段内同组 → 同一个新 id(保持分组),
  /// 与原文档的旧 id 隔离(自我复制粘贴不吸并进原容器)。
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
        DetailsFrame(:final summary, :final open) =>
          DetailsFrame(groupId: newId, summary: summary, open: open),
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
        out.add(b.copyWith(
          containers: [for (final f in b.containers) remap(f)],
        ));
        changed = true;
      } else {
        out.add(b);
      }
    }
    return changed ? out : fragment;
  }

  /// 原位更新 [islandId] 岛的节点(同类型形变,如图片缩放档切换)。
  /// 与 [replaceIsland] 的区别:不 re-id、不动光标/选区 —— 岛身份保持,
  /// EditorIsland 的 Element 原位重渲染,不闪跳。
  void updateIslandNode(String islandId, BlockNode newNode) {
    final i = indexOfBlock(islandId);
    if (i < 0 || _blocks[i] is! IslandBlock) return;
    sealHistory();
    final newBlocks = [..._blocks];
    newBlocks[i] = IslandBlock(id: islandId, node: newNode);
    _commit(newBlocks, _selection, groupWithPrevious: false);
    sealHistory();
  }

  /// 用 [fragment] 整体替换 [islandId] 岛(岛源码编辑确认后调用)。
  ///
  /// 编辑后的 markdown 可能 cook 出多块(如 details 改成两段),故接受
  /// 片段;空片段 = 删岛(用户清空源码)。片段 re-id;光标落片段末尾。
  void replaceIsland(String islandId, List<EditorBlock> fragment) {
    final i = indexOfBlock(islandId);
    if (i < 0 || _blocks[i] is! IslandBlock) return;
    sealHistory();
    _clearPending();
    final newBlocks = [..._blocks];
    newBlocks.removeAt(i);
    if (fragment.isEmpty) {
      // 删岛:光标落原位邻块(clamp 兜底)
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
      groupWithPrevious: false,
    );
    sealHistory();
  }

  /// 在 [content] 的 [offset] 处拼入另一段内容(text+marks+atoms 全量)。
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

  /// 全选。
  void selectAll() {
    final first = _blocks.first;
    final last = _blocks.last;
    updateSelection(EditorSelection(
      base: EditorPosition(blockId: first.id, offset: 0),
      extent: EditorPosition(
        blockId: last.id,
        offset: last.selectionLength,
      ),
    ));
  }

  /// 光标水平移动 ±1 grapheme(跨块衔接;岛两段式跳跃)。
  void moveCaretHorizontal(int direction, {bool extend = false}) {
    final sel = _selection;
    if (sel == null) return;
    // 非扩选且有选中范围:折叠到方向端点。端点若在岛上(整选岛态),
    // 顺移到岛外邻块(岛端点不是光标可停位)。
    if (!extend && !sel.isCollapsed) {
      final norm = normalizedSelection()!;
      var target = direction < 0 ? norm.$1 : norm.$2;
      final ti = indexOfBlock(target.blockId);
      if (ti >= 0 && _blocks[ti] is IslandBlock) {
        final moved =
            direction < 0 ? _positionBefore(ti) : _positionAfter(ti);
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

    // mark 末端边界二态切换(仅非扩选;扩选语义按内容坐标,跳过这层):
    // 内容坐标不动,只翻转内/外侧停位。
    if (!extend && _isAtInclusiveMarkEnd(pos)) {
      if (direction > 0 && !_caretOutsideMarkEnd) {
        // 内侧 → 外侧:视觉上跨过闭定界符,内容坐标原地。
        _caretOutsideMarkEnd = true;
        notifyListeners();
        return;
      }
      if (direction < 0 && _caretOutsideMarkEnd) {
        // 外侧 → 内侧。
        _caretOutsideMarkEnd = false;
        notifyListeners();
        return;
      }
    }

    if (direction < 0) {
      if (pos.offset > 0) {
        final before = block.content.text.substring(0, pos.offset);
        final step =
            before.characters.isEmpty ? 1 : before.characters.last.length;
        next = pos.copyWith(offset: pos.offset - step);
      } else if (i > 0) {
        final prev = _blocks[i - 1];
        if (prev is IslandBlock && !extend) {
          // 岛两段式:第一步整选,再按一步才落到另一侧。
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
        final step =
            after.characters.isEmpty ? 1 : after.characters.first.length;
        next = pos.copyWith(
            offset: math.min(pos.offset + step, block.content.length));
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
    if (next == null) return;
    if (extend) {
      updateSelection(EditorSelection(base: sel.base, extent: next));
      return;
    }
    // 左移落到 inclusive mark.end 时停**外侧**(对称序:end+1 → 外 →
    // 内 → end-1);updateSelection 默认归位内侧,落点后补置。
    final landOutside = direction < 0 && _isAtInclusiveMarkEnd(next);
    updateSelection(EditorSelection.collapsed(next));
    if (landOutside && !_caretOutsideMarkEnd) {
      _caretOutsideMarkEnd = true;
      notifyListeners();
    }
  }

  /// [index] 前一个可停位置(前块尾;岛为其 offset 0)。
  EditorPosition? _positionBefore(int index) {
    if (index <= 0) return null;
    final prev = _blocks[index - 1];
    return prev is TextBlock
        ? EditorPosition(blockId: prev.id, offset: prev.content.length)
        : EditorPosition(blockId: prev.id, offset: 0);
  }

  /// [index] 后一个可停位置(后块头)。
  EditorPosition? _positionAfter(int index) {
    if (index + 1 >= _blocks.length) return null;
    final next = _blocks[index + 1];
    return EditorPosition(blockId: next.id, offset: 0);
  }
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
