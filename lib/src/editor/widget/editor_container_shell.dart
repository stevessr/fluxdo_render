/// 容器壳(M5-B):可进入容器的编辑态装饰。
///
/// FluxdoEditor 按相邻块的 containers 公共前缀分组后,把组内子 widget
/// 交给本文件按帧类型包壳。**壳只是装饰**(竖条/底纹/边框/标题行),
/// 子块本体仍是正常 EditableParagraph —— 光标/选区/IME 完全不感知壳。
///
/// 视觉对照阅读端 NodeFactory 同类容器(quote 竖条灰底、spoiler 遮罩感
/// 底纹、details 折叠框、callout 彩条),编辑态一律**展开显示**(不折叠
/// 不遮蔽 —— 编辑时内容必须可见,对齐官方 rich editor 行为)。
library;

import 'package:flutter/material.dart';

import '../model/editor_block.dart';
import 'editor_table_grid.dart' show kEditorSelfManagedRegion;
import '../../node/node.dart' show CalloutKind;

/// 把一组同容器子块包上对应装饰壳。
class EditorContainerShell extends StatelessWidget {
  const EditorContainerShell({
    super.key,
    required this.frame,
    required this.children,
    this.onTitleTap,
    this.onContextMenu,
  });

  final ContainerFrame frame;
  final List<Widget> children;

  /// 点壳标题行(details summary / callout 标题)→ 宿主弹原位编辑。
  /// null = 标题不可改(quote 的 username 行是引用元数据,不开放)。
  final VoidCallback? onTitleTap;
  final VoidCallback? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );

    switch (frame) {
      case QuoteFrame():
        // 阅读端 buildBlockquote 视觉:左 4px 竖条 + 浅灰底
        return DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
            border: Border(
              left: BorderSide(color: scheme.outlineVariant, width: 4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
            child: column,
          ),
        );

      case QuoteCardFrame(:final username, :final displayName):
        // 阅读端 QuoteCard 视觉简化:灰底圆角 + 头部 username 行
        // (头像/徽章是服务端注入的展示字段,编辑态不渲染)
        final name = displayName ?? username;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(4),
              bottomRight: Radius.circular(4),
            ),
            border: Border(
              left: BorderSide(color: scheme.outlineVariant, width: 4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (name.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '$name:',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                column,
              ],
            ),
          ),
        );

      case SpoilerFrame():
        // 编辑态剧透壳:淡遮罩底纹 + 顶部小标签(内容可见可编辑)
        return DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.visibility_off_outlined,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '剧透',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                column,
              ],
            ),
          ),
        );

      case DetailsFrame(:final summary):
        // 编辑态 details:边框 + summary 标题行(恒展开;点标题改文案)
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TitleRow(
                  onTap: onTitleTap,
                  onContextMenu: onContextMenu,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_drop_down,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      Expanded(
                        child: Text(
                          summary.isEmpty ? '详情' : summary,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (onTitleTap != null)
                        Icon(
                          Icons.edit_outlined,
                          size: 13,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                column,
              ],
            ),
          ),
        );

      case CalloutFrame(:final kind, :final typeRaw, :final title):
        // 阅读端 callout 视觉:主色底 10% + 左 4px 彩条 + 图标标题行
        // (色/图标映射对齐 node_factory._calloutConfigFor)
        final (calloutColor, calloutIcon) = _calloutStyle(kind);
        final displayTitle = (title ?? '').isEmpty
            ? (typeRaw.isEmpty
                  ? ''
                  : typeRaw[0].toUpperCase() + typeRaw.substring(1))
            : title!;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: calloutColor.withValues(alpha: 0.1),
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(4),
              bottomRight: Radius.circular(4),
            ),
            border: Border(left: BorderSide(color: calloutColor, width: 4)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TitleRow(
                  onTap: onTitleTap,
                  onContextMenu: onContextMenu,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(calloutIcon, size: 16, color: calloutColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          displayTitle,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: calloutColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (onTitleTap != null)
                        Icon(
                          Icons.edit_outlined,
                          size: 13,
                          color: calloutColor.withValues(alpha: 0.6),
                        ),
                    ],
                  ),
                ),
                column,
              ],
            ),
          ),
        );
    }
  }

  /// callout kind → (主色, 图标)。对齐 node_factory._calloutConfigFor
  /// 的映射(那边是私有配置,这里编辑壳只需要色 + 图标两项)。
  static (Color, IconData) _calloutStyle(CalloutKind kind) => switch (kind) {
    CalloutKind.note => (Colors.blue, Icons.edit_note_rounded),
    CalloutKind.summary => (Colors.cyan, Icons.subject_rounded),
    CalloutKind.info => (Colors.blue, Icons.info_rounded),
    CalloutKind.todo => (Colors.blue, Icons.check_circle_rounded),
    CalloutKind.tip => (Colors.teal, Icons.tips_and_updates_rounded),
    CalloutKind.success => (Colors.green, Icons.check_circle_rounded),
    CalloutKind.question => (Colors.orange, Icons.help_rounded),
    CalloutKind.warning => (Colors.orange, Icons.warning_amber_rounded),
    CalloutKind.failure => (Colors.red, Icons.close_rounded),
    CalloutKind.danger => (Colors.red, Icons.dangerous_rounded),
    CalloutKind.bug => (Colors.red, Icons.bug_report_rounded),
    CalloutKind.example => (Colors.purple, Icons.list_rounded),
    CalloutKind.quote => (Colors.grey, Icons.format_quote_rounded),
    CalloutKind.unknown => (Colors.grey, Icons.format_quote_rounded),
  };
}

/// 壳标题行:可点(改标题)时加 InkWell 反馈;不可点原样。
class _TitleRow extends StatelessWidget {
  const _TitleRow({
    required this.onTap,
    required this.child,
    this.onContextMenu,
  });

  final VoidCallback? onTap;
  final Widget child;
  final VoidCallback? onContextMenu;

  @override
  Widget build(BuildContext context) {
    if (onTap == null && onContextMenu == null) return child;
    return MetaData(
      metaData: kEditorSelfManagedRegion,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onContextMenu,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: child,
          ),
        ),
      ),
    );
  }
}
