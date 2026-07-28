/// 行内标记对的定界符表(单一真相)。
///
/// input rules(打字触发,input_rules.dart)与 ir spin(删改后整块重扫,
/// model/inline_spin.dart)共享同一批模式 —— 两个引擎对「什么算一对
/// 完整合法的行内标记」永远同源,不会出现"打字能折叠、删出来不折叠"
/// 的语义分叉。
///
/// 表分三族:
/// - markdown 对称定界符([kInlinePairSpecs] → [kInlineRules]);
/// - BBCode 属性标记([kBbcodeAttrSpecs] → attr/open 三种派生形态)
///   与无 attr 标记([kBbcodeMarkTags]);
/// - HTML 样式标签([kHtmlMarkTags])。
///
/// spec(pattern 源串)与派生 RegExp 用推导式同源生成,不维护第二份
/// 正则文本。
library;

import '../model/editable_text_content.dart';

// ---------------------------------------------------------------------
// markdown 对称定界符
// ---------------------------------------------------------------------

/// (完整对 pattern【非锚定】, mark, 定界符)。按特异性排序:长定界符
/// 优先(`**` 先于 `*`)。内容组(group 1)不允许含定界字符本身(官方
/// [^*]+ 同款),且首尾非空格(`** x**` 不触发 —— CommonMark 语义)。
const List<(String, MarkKind, String)> kInlinePairSpecs = [
  (r'\*\*([^*\s](?:[^*]*[^*\s])?)\*\*', MarkKind.strong, '**'),
  (r'__([^_\s](?:[^_]*[^_\s])?)__', MarkKind.strong, '__'),
  (r'~~([^~\s](?:[^~]*[^~\s])?)~~', MarkKind.lineThrough, '~~'),
  (r'`([^`]+)`', MarkKind.inlineCode, '`'),
  // 单 * 斜体:前面不能还是 *(否则和 ** 混淆)
  (r'(?<!\*)\*([^*\s](?:[^*]*[^*\s])?)\*', MarkKind.em, '*'),
  (r'(?<!_)_([^_\s](?:[^_]*[^_\s])?)_', MarkKind.em, '_'),
];

/// 收尾定界符触发版(`$` 锚定;input rules 的主形态)。
final List<(RegExp, MarkKind, String)> kInlineRules = [
  for (final (p, kind, delim) in kInlinePairSpecs)
    (RegExp('$p\$'), kind, delim),
];

/// 整块扫描版(非锚定;spin 用 allMatches 找任意位置的完整对)。
final List<(RegExp, MarkKind, String)> kInlineScanRules = [
  for (final (p, kind, delim) in kInlinePairSpecs) (RegExp(p), kind, delim),
];

// ---------------------------------------------------------------------
// BBCode 属性标记(size/color/bgcolor —— 开/闭标记不等长,attr 进 mark)
// ---------------------------------------------------------------------

/// BBCode 标记的内容组 pattern:非空、不含 `[`(不支持嵌套 BBCode/链接,
/// 同 markdown 表的简化取舍)、首尾非空格。
const String kBbcodeContentPattern = r'([^\[\s](?:[^\[]*[^\[\s])?)';

/// (开标记 pattern【group 1 = attr 值】, mark, 闭标记字面)。
const List<(String, MarkKind, String)> kBbcodeAttrSpecs = [
  (r'\[size=(\d{1,4})\]', MarkKind.size, '[/size]'),
  (r'\[color=(#?[0-9a-fA-F]{3,8})\]', MarkKind.textColor, '[/color]'),
  (r'\[bgcolor=(#?[0-9a-fA-F]{3,8})\]', MarkKind.bgColor, '[/bgcolor]'),
];

/// 完整对收尾触发版(`$` 锚定;group 1 = attr,group 2 = 内容)。
final List<(RegExp, MarkKind, String)> kBbcodeAttrRules = [
  for (final (open, kind, close) in kBbcodeAttrSpecs)
    (
      RegExp('$open$kBbcodeContentPattern${RegExp.escape(close)}\$'),
      kind,
      close,
    ),
];

/// 开标记锚定版(`$` 锚定)—— "先打闭标记、光标挪回来补开标记"场景。
final List<(RegExp, MarkKind, String)> kBbcodeOpenRules = [
  for (final (open, kind, close) in kBbcodeAttrSpecs)
    (RegExp('$open\$'), kind, close),
];

/// 开标记非锚定版 —— 在串**中间**找开标记(inside-pair 兜底、spin
/// 整块扫描)用,锚定版只能匹配到串尾。
final List<(RegExp, MarkKind, String)> kBbcodeOpenPatterns = [
  for (final (open, kind, close) in kBbcodeAttrSpecs)
    (RegExp(open), kind, close),
];

// ---------------------------------------------------------------------
// BBCode 无 attr 标记 / HTML 样式标签(开闭都是字面串)
// ---------------------------------------------------------------------

/// (开标记, mark, 闭标记)。无 attr 的 BBCode 标记 —— `[u]`/`[spoiler]`
/// 早就是 mark 类型([MarkKind.underline]/[MarkKind.spoilerInline]),但
/// 此前只有工具栏按钮能插入,手打字面标记不会即时渲染。
const List<(String, MarkKind, String)> kBbcodeMarkTags = [
  ('[u]', MarkKind.underline, '[/u]'),
  ('[spoiler]', MarkKind.spoilerInline, '[/spoiler]'),
  // b/i/s 真实 Discourse 支持(cook 出 strong/em/s,在消毒白名单里),
  // 复用已有 MarkKind,同 markdown ** 定界符殊途同归。
  ('[b]', MarkKind.strong, '[/b]'),
  ('[i]', MarkKind.em, '[/i]'),
  ('[s]', MarkKind.lineThrough, '[/s]'),
];

/// (开标签, mark, 闭标签)。HTML 样式标签 —— 读端早就支持
/// (InlineStyleKind.small/big/mark/superscript/subscript/monospace),
/// 编辑态此前没有触发规则,手打字面标签不会即时渲染。
const List<(String, MarkKind, String)> kHtmlMarkTags = [
  ('<small>', MarkKind.smallStyle, '</small>'),
  ('<big>', MarkKind.bigStyle, '</big>'),
  ('<mark>', MarkKind.markStyle, '</mark>'),
  ('<sup>', MarkKind.superscript, '</sup>'),
  ('<sub>', MarkKind.subscript, '</sub>'),
  ('<kbd>', MarkKind.monospaceStyle, '</kbd>'),
  // 读端(paragraph_parser.dart)已有的简化映射,同 ins→underline /
  // del→lineThrough / samp|tt→monospace(对齐 kbd)/ cite|dfn|var→em
  // (浏览器默认都是斜体)保持一致——复用既有 MarkKind,不新增渲染类型。
  ('<ins>', MarkKind.underline, '</ins>'),
  ('<del>', MarkKind.lineThrough, '</del>'),
  ('<samp>', MarkKind.monospaceStyle, '</samp>'),
  ('<tt>', MarkKind.monospaceStyle, '</tt>'),
  ('<cite>', MarkKind.em, '</cite>'),
  ('<dfn>', MarkKind.em, '</dfn>'),
  ('<var>', MarkKind.em, '</var>'),
];
