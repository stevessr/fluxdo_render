import 'package:flutter/foundation.dart';

/// 表格结构动作：宿主只展示命令，不复制表格数据或计算索引。
enum EditorTableAction {
  rowBefore,
  rowAfter,
  columnBefore,
  columnAfter,
  deleteRow,
  deleteColumn,
}

enum EditorTableActionResult { success, stale, unavailable, failed }

@immutable
class EditorTableContext {
  const EditorTableContext({
    required this.tableId,
    required this.cell,
    required this.revision,
    required this.rows,
    required this.columns,
    required this.rowHasContent,
    required this.columnHasContent,
    required this.busy,
    required this.execute,
  });
  final String tableId;
  final (int, int) cell;
  final int revision;
  final int rows;
  final int columns;
  final bool rowHasContent;
  final bool columnHasContent;
  final bool busy;
  final Future<EditorTableActionResult> Function(EditorTableAction) execute;

  bool enabled(EditorTableAction action) =>
      !busy &&
      switch (action) {
        EditorTableAction.deleteRow => rows > 1,
        EditorTableAction.deleteColumn => columns > 1,
        _ => true,
      };
  bool needsConfirmation(EditorTableAction action) => switch (action) {
    EditorTableAction.deleteRow => rowHasContent,
    EditorTableAction.deleteColumn => columnHasContent,
    _ => false,
  };
}
