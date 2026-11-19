/// 渲染代码块时主项目要提供的 highlighter 签名。
///
/// 子包不依赖 highlight.js / mermaid / chart 等重量级库,通过这个 typedef
/// 注入。主项目侧用 HighlighterService(highlight.js)+ Mermaid 等真正渲染;
/// 不传时子包用纯 monospace 显示原始 code。
///
/// **mermaid 路由**:主项目在 [CodeBlockBuilder] 内判断
/// `node.language == 'mermaid'` 返回整块 MermaidWidget(独立容器 +
/// 图表/代码切换),其余语言返回 null 走默认代码块外壳 + highlighter。
///
/// 调用方:
/// ```dart
/// FluxdoRender(
///   cookedHtml: ...,
///   codeBlockBuilder: (ctx, node) {
///     if (node.language == 'mermaid') return MermaidBlock(code: node.code);
///     return null;
///   },
///   codeBlockHighlighter: (ctx, code, language) {
///     return HighlightedCodeText(code: code, language: language);
///   },
/// );
/// ```

library;

import 'package:material_ui/material_ui.dart';

import '../node/node.dart' show CodeBlockNode;

/// 代码块 highlighter。返回应该是**只含代码内容**的 widget(monospace
/// text / 高亮后 RichText / mermaid 图),外面的灰底容器 + 顶栏 chip +
/// 复制按钮由子包 NodeFactory 包好,这个 callback 不用管。
typedef CodeBlockHighlighter = Widget Function(
  BuildContext context,
  String code,
  String? language,
);

/// 代码块**整块** override。返回非 null 时直接用作整个代码块 widget
/// (子包不再包灰底容器 / 顶栏 / 行号 / 滚动外壳);返回 null 走默认外壳
/// + [CodeBlockHighlighter]。
///
/// 与 [CodeBlockHighlighter] 的分工:highlighter 只替换"代码内容"这一层,
/// 适合语法高亮;有些语言(如 mermaid)需要的是整块换成另一种形态
/// (独立图表容器 + 图表/代码切换),外壳本身不适用 —— 主项目在这里按
/// `node.language` 判断并整块接管。语言判断在主项目侧,子包不认识 mermaid。
typedef CodeBlockBuilder = Widget? Function(
  BuildContext context,
  CodeBlockNode node,
);

/// 默认 highlighter —— 纯 monospace Text,无颜色。
///
/// 主项目接入时**应该**注入自定义 highlighter(highlight.js + mermaid)。
Widget defaultCodeBlockHighlighter(
  BuildContext context,
  String code,
  String? language,
) {
  return Text(
    code,
    style: const TextStyle(
      fontFamily: 'FiraCode',
      fontFamilyFallback: ['monospace', 'Menlo', 'Courier'],
      fontSize: 13,
      height: 1.4,
    ),
  );
}
