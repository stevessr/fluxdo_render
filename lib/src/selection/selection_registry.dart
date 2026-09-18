/// 全局选区注册表 —— 当前 post 的「逻辑文档」+「可见块句柄」两张表。
///
/// 对齐成熟方案(Flutter SelectionArea / CodeMirror state.doc / ProseMirror
/// doc model):选区是逻辑模型,几何按需、只对可见块算。故拆两张表:
/// - **[_logical] 逻辑块表**:order → {projection 快照, renderLength,
///   codeLanguage}。块注册/每次 flatten 写入,**unregister 不删**(整帖生命周期
///   常驻,像 state.doc)。复制/区间走它 → 滚出视口被回收的块照样完整。
/// - **[_live] 可见块句柄**:order → handle,仅已 mount 的块。命中/高亮/toolbar
///   锚点等几何走它(只对可见块算,视口外无几何是设计)。
///
/// 视觉/文档序由 SelectableBlockId `(chunkIndex, docOrder)` 字典序给出(纯逻辑,
/// 不读 globalRect)→ 虚拟化/重叠/回收下排序天然稳定。
library;

import 'package:flutter/foundation.dart';

import 'selectable_block_handle.dart';
import 'selection_coordinator.dart';
import 'selection_geometry.dart';
import 'projection.dart';

/// 逻辑块快照 —— 与 mount 无关,整帖常驻。
class LogicalBlock {
  LogicalBlock({required this.id, required this.projection, this.codeLanguage});

  final SelectableBlockId id;

  /// 渲染偏移 ↔ 逻辑投影 映射表快照(每次 flatten 刷新;块回收后保留最后值)。
  RenderTextProjection projection;

  /// 代码块语言(复制带 ```lang);非代码块为 null。
  String? codeLanguage;

  int get renderLength => projection.renderLength;
}

/// 注册表。每个 post 一个(scopeId 共享时跨 chunk 同一个)。
class SelectionRegistry {
  /// 已 mount(可见)的块句柄,按 id 索引。几何走它。
  ///
  /// 用 **List**(而非单值):分块长帖在 resize/重建/回收的瞬态里,同一
  /// `(chunkIndex,docOrder)` 可能短暂存在两个 handle(旧块未注销 + 新块已注册)。
  /// 单值会被后注册者覆盖,导致命中/高亮落到陈旧那个块(划词跳到别段)。改存多个,
  /// [byId]/命中/高亮统一取「当前可见(globalRect 有效)」的那个 → 始终落在你点的块。
  final Map<SelectableBlockId, List<SelectableBlockHandle>> _live = {};

  /// 逻辑块表(整帖常驻,unregister 不删)。复制/区间走它。
  final Map<SelectableBlockId, LogicalBlock> _logical = {};

  /// 块 mount → 登记可见句柄。
  void register(SelectableBlockHandle handle) {
    final list = _live.putIfAbsent(handle.id, () => []);
    if (!list.contains(handle)) list.add(handle);
  }

  /// 块卸载 → 摘**该** handle(按 identity,不误删同 id 的新块),
  /// **保留逻辑块表**(回收块仍可复制/算区间)。
  void unregister(SelectableBlockHandle handle) {
    final list = _live[handle.id];
    if (list == null) return;
    list.remove(handle);
    if (list.isEmpty) _live.remove(handle.id);
  }

  /// 写/刷新逻辑块表(每次 flatten 调,内容变即更新快照)。
  void updateLogical(
    SelectableBlockId id,
    RenderTextProjection projection, {
    String? codeLanguage,
  }) {
    final e = _logical[id];
    if (e == null) {
      _logical[id] =
          LogicalBlock(id: id, projection: projection, codeLanguage: codeLanguage);
    } else {
      e.projection = projection;
      e.codeLanguage = codeLanguage;
    }
  }

  /// 取可见(已 mount)块句柄;块滚出视口被回收时返回 null。
  ///
  /// 同 id 多 handle 时优先返回**当前可见**(globalRect 有效)的那个 —— resize/
  /// 重建瞬态下旧块陈旧、新块可见,务必取可见的(否则命中/高亮落到陈旧块)。
  SelectableBlockHandle? byId(SelectableBlockId id) {
    final list = _live[id];
    if (list == null || list.isEmpty) return null;
    for (final h in list) {
      if (h.globalRect() != null) return h;
    }
    return list.last;
  }

  /// 取逻辑块快照(回收块也在)。复制/区间用。
  LogicalBlock? logicalById(SelectableBlockId id) => _logical[id];

  /// 当前可见块句柄(命中测试用,只在可见块里找)。同 id 多 handle 全列出
  /// → 框架命中按 identical 在其中找到点下真实可见的那个。
  Iterable<SelectableBlockHandle> get liveHandles =>
      _live.values.expand((l) => l);

  int get length => _logical.length;

  /// 当前已 mount(可见)块句柄总数。
  int get liveLength => _live.values.fold(0, (a, l) => a + l.length);

  /// 按文档/视觉序 `(chunkIndex, docOrder)` 排序的**全部逻辑块**(含回收块)。
  /// 纯逻辑排序,不读 globalRect → 虚拟化/重叠下稳定。区间/端点导航用它。
  List<LogicalBlock> orderedBlocks() {
    final list = _logical.values.toList();
    list.sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  @override
  String toString() =>
      'SelectionRegistry(${_logical.length} logical / ${_live.length} live)';
}

/// 当前选区 + registry 的下传载体(实际作为 InheritedWidget 由 SelectionScope 持有)。
class SelectionController extends ChangeNotifier {
  SelectionController(this.registry);

  final SelectionRegistry registry;

  /// 编辑器单选图片时使用紧贴图像的淡色选区；普通选词使用整行盒。
  bool _outlineSelection = false;
  bool get outlineSelection => _outlineSelection;
  set outlineSelection(bool value) {
    if (_outlineSelection == value) return;
    _outlineSelection = value;
    notifyListeners();
  }

  DocumentSelection? _selection;
  DocumentSelection? get selection => _selection;

  set selection(DocumentSelection? value) {
    if (_selection == value) return;
    _selection = value;
    // 全局唯一活动选区:起选时清掉其他帖的选区;自己清空时注销活动者。
    if (value != null) {
      SelectionCoordinator.instance.activate(this);
    } else {
      SelectionCoordinator.instance.deactivate(this);
    }
    notifyListeners();
  }

  void clear() => selection = null;

  @override
  void dispose() {
    SelectionCoordinator.instance.deactivate(this);
    super.dispose();
  }
}
