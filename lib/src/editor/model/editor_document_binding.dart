import 'editor_block.dart';
import 'editor_state.dart' show EditorSelection;

/// 可选语义导出协议；未知片段必须拒绝，不得回退有损的扁平序列化。
abstract interface class EditorDocumentExportBinding {
  String exportDocument(Object state, {List<EditorBlock>? fragment});

  /// 使用原始选区坐标，避免重复文本的片段无法确定源码范围。
  String exportSelection(
    Object state,
    EditorSelection selection, {
    required List<EditorBlock> blocks,
  });
}

/// 可选文档事务门禁。实现必须纯计算，不得修改旧快照或编辑器。
///
/// 输入为已补齐文本块、折叠 IR 表示的只读语义块。返回不可变语义快照，
/// 无法投影时抛出 [EditorDocumentRejection]；不能监听提交后再拒绝。
/// 历史回放直接恢复已批准快照，不重新调用 [prepare]。
/// 当前保证单次 _commit 原子性，并非所有公共复合命令的一致事务；
/// 启用生产前还需隔离先删除再插入等多提交命令，以及前置历史封口。
abstract interface class EditorDocumentBinding {
  Object prepare(Object? previousState, List<EditorBlock> normalizedBlocks);
}

/// 供可选历史重映射协议使用的只读正文与语义快照。
class EditorDocumentHistorySnapshot {
  EditorDocumentHistorySnapshot(List<EditorBlock> blocks, this.documentState)
    : blocks = List.unmodifiable(blocks);
  final List<EditorBlock> blocks;
  final Object? documentState;
}

/// 仅需要重写历史的绑定实现；映射必须纯计算，不能修改输入快照。
abstract interface class EditorDocumentHistoryBinding {
  EditorDocumentHistorySnapshot remapHistory(
    EditorDocumentHistorySnapshot snapshot,
    Object operation,
  );
}

/// 文档事务未通过绑定门禁。调用方可捕获并向用户展示原因。
class EditorDocumentRejection implements Exception {
  const EditorDocumentRejection(
    this.message, {
    this.code = 'projection_rejected',
  });

  final String message;
  final String code;

  @override
  String toString() => 'EditorDocumentRejection($code): $message';
}

/// 明确命令意图；来源为提交前稳定块及选区，而非反推最终快照。
class EditorStructureIntent {
  const EditorStructureIntent(
    this.command, {
    this.startBlockId,
    this.startOffset,
    this.endBlockId,
    this.endOffset,
    this.fragment,
  });
  final List<EditorBlock>? fragment;
  final String? startBlockId;
  final int? startOffset;
  final String? endBlockId;
  final int? endOffset;
  EditorStructureIntent withRange(
    String? startId,
    int? start,
    String? endId,
    int? end,
  ) => EditorStructureIntent(
    command,
    startBlockId: startId,
    startOffset: start,
    endBlockId: endId,
    endOffset: end,
    fragment: fragment,
  );
  final String command;
}

abstract interface class EditorDocumentIntentBinding {
  Object prepareWithIntent(
    Object? previousState,
    List<EditorBlock> normalizedBlocks,
    EditorStructureIntent intent,
  );
}
