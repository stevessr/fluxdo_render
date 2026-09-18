/// 编辑文档 → raw markdown 序列化(提交/草稿/双模切换用)。
///
/// 目标是产出**能被 Discourse cook 还原为等价 cooked** 的 markdown ——
/// 不追求与原始输入逐字节一致(markdown 表达同一结构有多种写法),
/// 追求 cook 后语义等价。
///
/// 与 doc_converter 的关系:doc_converter 是 doc ↔ BlockNode(结构层),
/// 本文件是 doc → markdown 文本(表示层)。markdown → doc 反方向走
/// cook(JS bundle)→ parse → blockNodesToDoc,不在子包内。
library;

import 'dart:math' as math;
import 'dart:ui' show TextAlign;

import 'island_inline_serializer.dart';
import 'poll_codec.dart';

import '../../node/node.dart';
import 'doc_converter.dart';
import 'editable_text_content.dart';
import 'editor_block.dart';
import 'raw_media_html.dart';

/// 整篇文档 → markdown。
///
/// M5-B:按 [TextBlock.containers] 栈递归分组 —— 相邻块同容器帧 = 同一
/// 容器实例,内层序列化完包上容器语法(`> ` 前缀 / `[quote]` / `[spoiler]`
/// / `[details]` / callout 标记行)。
/// 序列化前先回收未填的逃生口空段(编辑态为让光标有落点而补的顶层
/// 空段),避免发送/草稿里留多余空行。
String docToMarkdown(List<EditorBlock> doc) =>
    _serializeLevel(stripUnusedEscapeGaps(doc), 0);

String _serializeLevel(List<EditorBlock> doc, int level) {
  final chunks = <String>[];
  var i = 0;
  while (i < doc.length) {
    final block = doc[i];

    if (block is IslandBlock) {
      chunks.add(serializeIslandNode(block.node));
      i++;
      continue;
    }
    block as TextBlock;

    if (block.containers.length > level) {
      // 相同容器帧的连续 run → 递归内层后包容器语法
      final frame = block.containers[level];
      final run = <EditorBlock>[];
      while (i < doc.length) {
        final b = doc[i];
        if (b is TextBlock &&
            b.containers.length > level &&
            b.containers[level] == frame) {
          run.add(b);
          i++;
        } else {
          break;
        }
      }
      chunks.add(_serializeFrame(frame, run, level));
      continue;
    }

    if (block.isListItem) {
      // 连续 listItem run 作为一个 chunk(项间单换行,序号连续计算)
      final run = <TextBlock>[];
      while (i < doc.length) {
        final b = doc[i];
        if (b is TextBlock && b.isListItem && b.containers.length <= level) {
          run.add(b);
          i++;
        } else {
          break;
        }
      }
      chunks.add(_serializeListRun(run));
      continue;
    }

    chunks.add(_serializeTextBlock(block));
    i++;
  }
  // 块间空行;过滤全空 chunk(如未知岛)后拼接
  return chunks.where((c) => c.isNotEmpty).join('\n\n');
}

/// 容器帧 → markdown 包装。
///
/// Quote/Callout 的 `>` 前缀规则(cook 实测):同一 blockquote 内的
/// 块间分隔必须是 **`>` 前缀空行**(裸空行劈成两个相邻 blockquote);
/// 内层 join('\n\n') 产生的空行经前缀映射为 `>`,嵌套时外层再叠
/// 一层前缀 —— 深浅交界的分隔行自然是浅侧前缀。
String _serializeFrame(ContainerFrame frame, List<EditorBlock> run, int level) {
  final inner = _serializeLevel(run, level + 1);
  String prefixQuote(String s) =>
      s.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n');

  switch (frame) {
    case QuoteFrame():
      return prefixQuote(inner);
    case CalloutFrame(:final typeRaw, :final title, :final foldable):
      final fold = switch (foldable) { true => '+', false => '-', null => '' };
      final t = (title ?? '').isEmpty ? '' : ' $title';
      final lines = <String>['> [!$typeRaw]$fold$t'];
      if (inner.isNotEmpty) lines.add(prefixQuote(inner));
      return lines.join('\n');
    case QuoteCardFrame(
        :final username,
        :final displayName,
        :final postNumber,
        :final topicId,
        :final full,
      ):
      final parts = <String>[];
      if (displayName != null) {
        parts.add(displayName);
      } else if (username.isNotEmpty) {
        parts.add(username);
      }
      if (postNumber != null) parts.add('post:$postNumber');
      if (topicId != null) parts.add('topic:$topicId');
      if (displayName != null && username.isNotEmpty) {
        parts.add('username:$username');
      }
      if (full) parts.add('full:true');
      final open =
          parts.isEmpty ? '[quote]' : '[quote="${parts.join(', ')}"]';
      return '$open\n$inner\n[/quote]';
    case SpoilerFrame():
      return '[spoiler]\n$inner\n[/spoiler]';
    case DetailsFrame(:final summary, :final open):
      final summaryAttr = summary.isEmpty ? '' : '="$summary"';
      final openAttr = open ? ' open' : '';
      return '[details$summaryAttr$openAttr]\n$inner\n[/details]';
  }
}

String _serializeTextBlock(TextBlock block) {
  var text = _inlineToMarkdown(block.content);

  if (block.isHeading) {
    text = '${'#' * block.headingLevel} $text';
  } else {
    // 段落(块级解析上下文)末尾防 spoiler 块规则吞行,详见
    // [_spoilerBlockGuardSuffix]
    text += _spoilerBlockGuardSuffix(block.content);
  }
  return text;
}

/// 段尾 spoiler 防吞后缀:命中 cook 块规则形态时补两个尾随空格。
///
/// cook bundle 探针实测,spoiler BBCode 的**块规则**命中条件是:
/// 单行内容恰为 `[spoiler]…[/spoiler]` —— 开标签在行首、闭标签紧贴
/// 行尾(行尾连一个空格都不能有)。行内 SpoilerRun 写回后若恰好构成
/// 这一形态,重 cook 会被吞成块级 `<div class="spoiler">`,与原始
/// cooked(`<p><span class="spoiler">…</span></p>`)结构不等 —— 富文本
/// 导入门禁(二次 cook 等价对比)因此拦下整帖,整帖降级源码模式。
/// 用户写 `[spoiler]吃[/spoiler]␠␠`(行尾双空格硬换行)再空行分段时
/// 正中此坑:cook 走行内规则产出 span,而序列化丢掉了行尾空格,
/// 写回变成块规则形态。
///
/// 修复:命中形态的段落行尾补回两个空格 —— 闭标签不再紧贴行尾,
/// 块规则不命中,行内规则接管,与原 cooked 一致。实测对照(仅行尾
/// 两空格之差):
/// - `[spoiler]吃[/spoiler]` → `<div class="spoiler"><p>吃</p></div>`
/// - `[spoiler]吃[/spoiler]␠␠` → `<p><span class="spoiler">吃</span></p>`
///
/// 判据用 mark 模型(而非匹配产物字符串):存在 spoilerInline mark
/// **始于 offset 0**(开标签在行首)且存在 spoilerInline mark**终于
/// text.length**(闭标签在段尾)。两个 mark 可以不是同一个 —— 相邻
/// `[spoiler]吃[/spoiler][spoiler]喝[/spoiler]` 的首开尾合同样命中
/// 块规则(实测:整行被吞进一个 div)。行中开的
/// `参考[spoiler]吃[/spoiler]`、段中闭的 `[spoiler]吃[/spoiler]参考`
/// 都不构成块规则形态,不加空格。
///
/// 适用范围:块级解析上下文 —— 顶层/容器(quote/spoiler/details/quote
/// 卡/callout)内段落与列表项(实测:这些上下文里块规则都会吞,后缀
/// 都能保住行内形态,且不影响子列表挂接与后文分段)。**不适用**于
/// inline-only 上下文:标题(块规则永不命中)与表格单元格/poll 选项
/// 等岛 inline(同理由);岛化列表([_serializeListNode],项内可能挂
/// 块级子节点的续行,后缀会干扰挂接)不加 —— 残余缺口由导入门禁
/// 兜底降级,不丢内容。
String _spoilerBlockGuardSuffix(EditableTextContent content) {
  final text = content.text;
  if (text.isEmpty) return '';
  var opensAtStart = false;
  var closesAtEnd = false;
  for (final m in content.marks) {
    if (m.kind != MarkKind.spoilerInline) continue;
    if (m.start == 0) opensAtStart = true;
    if (m.end == text.length) closesAtEnd = true;
  }
  return (opensAtStart && closesAtEnd) ? '  ' : '';
}

String _serializeListRun(List<TextBlock> run) {
  // 缩进规则(CommonMark):子列表缩进 = 各级祖先 marker 的**实际宽度**
  // 累计(`- ` 2 字符、`12. ` 4 字符)。固定 2 空格在 ol 下不够
  // (`1. ` 宽 3,2 空格缩进的"子项"会被解析回顶层 —— cook 实测)。
  // markerWidth[d] = 当前 depth d 项的 marker 宽;indent(d) = 前 d 级之和。
  final markerWidth = <int>[];
  final looseAtDepth = <int, bool>{};
  int? previousDepth;
  int indentOf(int depth) {
    var sum = 0;
    for (var d = 0; d < depth && d < markerWidth.length; d++) {
      sum += markerWidth[d];
    }
    return sum;
  }

  // 顶层 ul/ol 切换 = 两个独立列表,必须空行分隔(单换行会被解析进
  // 前一个列表的延续上下文)。
  final segments = <List<String>>[];
  var lines = <String>[];
  bool? topOrdered;

  final counters = <(bool, int), int>{};
  for (final b in run) {
    if (b.depth == 0 && topOrdered != null && b.ordered != topOrdered) {
      segments.add(lines);
      lines = <String>[];
      counters.clear();
      markerWidth.clear();
      looseAtDepth.clear();
      previousDepth = null;
    }
    if (b.depth == 0) topOrdered = b.ordered;

    final key = (b.ordered, b.depth);
    final ordinal = counters[key] ?? b.listStart;
    counters[key] = ordinal + 1;
    // 同层 ul/ol 切换也结束旧列表，返回该类型时必须重新取起号。
    counters.removeWhere((k, _) => k.$2 > b.depth ||
        (k.$2 == b.depth && k.$1 != b.ordered));

    // 进入子列表前由父列表决定段落间隔；返回同层则由本列表决定。
    // 非 1 起号的有序子列表尤其不能直接打断父项段落。
    if (lines.isNotEmpty && previousDepth != null &&
        (b.depth > previousDepth
            ? looseAtDepth[previousDepth] == true
            : b.listLoose)) {
      lines.add('');
    }
    looseAtDepth.removeWhere((depth, _) => depth > b.depth);
    looseAtDepth[b.depth] = b.listLoose;
    previousDepth = b.depth;

    final marker = b.ordered ? '$ordinal. ' : '- ';
    // 记录本级 marker 宽,裁掉更深层的过期记录
    if (markerWidth.length > b.depth) {
      markerWidth.removeRange(b.depth, markerWidth.length);
    }
    while (markerWidth.length < b.depth) {
      markerWidth.add(2); // 缺级兜底(悬空深项):按 ul 宽度
    }
    markerWidth.add(marker.length);

    final indent = ' ' * indentOf(b.depth);
    // 列表项内容同样是块级解析上下文(`- [spoiler]x[/spoiler]` 实测
    // 会被块规则吞成 li 内 div),同样补防吞后缀
    lines.add('$indent$marker${_inlineToMarkdown(b.content)}'
        '${_spoilerBlockGuardSuffix(b.content)}');
  }
  segments.add(lines);
  return segments
      .where((s) => s.isNotEmpty)
      .map((s) => s.join('\n'))
      .join('\n\n');
}

// ---------------------------------------------------------------------
// 行内序列化:扁平模型(text + marks + atoms)→ markdown 标记对
// ---------------------------------------------------------------------

/// mark 开/闭标记(嵌套固定序:spoiler > link > strong > em > underline >
/// lineThrough;inlineCode 独占由 toInlines 语义保证,这里同优先级处理即可)。
///
/// **单一真相**:编辑态显形(EditableTextContent.toInlines 的
/// revealMarkdownAt)的定界符排列也用这份序 —— 显形展示与序列化产物
/// 的嵌套形态一致,不维护第二份。
///
/// **只对硬约束 kind 是权威**:同区间的普通样式 mark(strong/em/HTML
/// 标签系)之间嵌套方向语义等价,序列化尊重 marks 列表序(见
/// [compareSameSpanMarkOpen])—— 本表对它们只是无列表序可依时的兜底。
const List<MarkKind> kMarkNestingOrder = [
  MarkKind.spoilerInline,
  // size 包在颜色外层(与 toInlines._wrapPiece 的包裹顺序一致:先套色
  // 再套字号,size 最外)
  MarkKind.size,
  // 颜色包在 link 外层:cook 实测 `[color=…][…](url)[/color]` 可解析,
  // 反过来 link 里嵌 color 会让锚文本被 BBCode 切碎
  MarkKind.bgColor,
  MarkKind.textColor,
  MarkKind.link,
  MarkKind.strong,
  MarkKind.em,
  MarkKind.underline,
  MarkKind.lineThrough,
  MarkKind.smallStyle,
  MarkKind.bigStyle,
  MarkKind.markStyle,
  MarkKind.superscript,
  MarkKind.subscript,
  MarkKind.monospaceStyle,
  MarkKind.inlineCode,
];

/// 嵌套方向有 cook 实测硬约束的 kind(两两之间必须按 [kMarkNestingOrder]
/// 包裹,写反会被 BBCode/onebox 解析切碎)。普通样式标记不在此列 ——
/// `<small>~~x~~</small>` 与 `~~<small>x</small>~~` cook 都认,方向属于
/// 内容本身,必须往返保序。
const Set<MarkKind> _kHardConstrainedKinds = {
  MarkKind.spoilerInline,
  MarkKind.size,
  MarkKind.bgColor,
  MarkKind.textColor,
  MarkKind.link,
};

/// 同区间(start/end 都相同)mark 的**开启**定序,外层在前。
///
/// 背景(真实翻车):`<small>~~旧称~~</small>` 经 parser 摊平成同区间的
/// smallStyle+lineThrough 两个 mark,DOM 嵌套序只剩 marks **列表序**
/// (parser 摊平时外层先入表)在承载。序列化若一律按 [kMarkNestingOrder]
/// 重排,会写出 `~~<small>旧称</small>~~` —— 结构翻转,宿主门禁二次
/// cook 对比不等价,整帖被降级源码模式。
///
/// 规则:任一方是硬约束 kind 时按 [kMarkNestingOrder](包裹方向是解析
/// 正确性/既有 raw 约定问题,列表序不越权);两个普通样式 mark 之间才
/// 尊重列表序(aIndex/bIndex = 在 marks 列表里的下标)。
int compareSameSpanMarkOpen(MarkSpan a, int aIndex, MarkSpan b, int bIndex) {
  if (_kHardConstrainedKinds.contains(a.kind) ||
      _kHardConstrainedKinds.contains(b.kind)) {
    return kMarkNestingOrder
        .indexOf(a.kind)
        .compareTo(kMarkNestingOrder.indexOf(b.kind));
  }
  return aIndex.compareTo(bIndex);
}

/// HTML 样式标签名(小写):`<tag>…</tag>`。
String? _htmlTagNameFor(MarkKind kind) => switch (kind) {
      MarkKind.smallStyle => 'small',
      MarkKind.bigStyle => 'big',
      MarkKind.markStyle => 'mark',
      MarkKind.superscript => 'sup',
      MarkKind.subscript => 'sub',
      MarkKind.monospaceStyle => 'kbd',
      _ => null,
    };

String _openTag(MarkSpan m, {required bool htmlEmphasis}) {
  final tag = _htmlTagNameFor(m.kind);
  if (tag != null) return '<$tag>';
  return switch (m.kind) {
    MarkKind.strong => m.attr == 'b' ? '[b]' : htmlEmphasis ? '<strong>' : '**',
    MarkKind.em => m.attr == 'i' ? '[i]' : htmlEmphasis ? '<em>' : '*',
    MarkKind.inlineCode => '`',
    MarkKind.underline => m.attr == 'u' ? '<u>' : '[u]',
    MarkKind.lineThrough => m.attr == 's' ? '[s]' : '~~',
    MarkKind.spoilerInline => '[spoiler]',
    MarkKind.link => '[',
    MarkKind.textColor => '[color=${m.attr ?? ''}]',
    MarkKind.bgColor => '[bgcolor=${m.attr ?? ''}]',
    MarkKind.size => '[size=${m.attr ?? ''}]',
    _ => '',
  };
}

String _closeTag(MarkSpan m, {required bool htmlEmphasis}) {
  final tag = _htmlTagNameFor(m.kind);
  if (tag != null) return '</$tag>';
  return switch (m.kind) {
    MarkKind.strong => m.attr == 'b' ? '[/b]' : htmlEmphasis ? '</strong>' : '**',
    MarkKind.em => m.attr == 'i' ? '[/i]' : htmlEmphasis ? '</em>' : '*',
    MarkKind.inlineCode => '`',
    MarkKind.underline => m.attr == 'u' ? '</u>' : '[/u]',
    MarkKind.lineThrough => m.attr == 's' ? '[/s]' : '~~',
    MarkKind.spoilerInline => '[/spoiler]',
    MarkKind.link => '](${m.attr ?? ''})',
    MarkKind.textColor => '[/color]',
    MarkKind.bgColor => '[/bgcolor]',
    MarkKind.size => '[/size]',
    _ => '',
  };
}

/// 编辑态显形用:mark 的字面开定界符(markdown/BBCode 形态,与序列化
/// [_openTag] 完全同源 —— 显形展示的字面量就是序列化会写出的字面量,
/// attr 类(color/size/link)带原样 attr)。
String markOpeningDelimiter(MarkSpan m) => _openTag(m, htmlEmphasis: false);

/// 编辑态显形用:mark 的字面闭定界符(与 [_closeTag] 同源)。
String markClosingDelimiter(MarkSpan m) => _closeTag(m, htmlEmphasis: false);

/// 是否存在交错区间(a.start < b.start < a.end < b.end)。
///
/// 交错时 LIFO 补闭重开会产生 `***`/`****` 之类的相邻同字符定界符,
/// CommonMark 贪婪匹配会破坏语义(cook 实测)。此时 strong/em 降级为
/// `<strong>/<em>` HTML 标签 —— cook sanitizer 放行且 cooked 结构与
/// markdown 定界符产物完全一致(实测),只是 raw 可读性略降(罕见路径)。
bool _hasCrossingMarks(List<MarkSpan> marks) {
  for (var i = 0; i < marks.length; i++) {
    for (var j = i + 1; j < marks.length; j++) {
      final a = marks[i];
      final b = marks[j];
      if (a.start < b.start && b.start < a.end && a.end < b.end) return true;
      if (b.start < a.start && a.start < b.end && b.end < a.end) return true;
    }
  }
  return false;
}

/// 锚文本是否就是这条链接的裸 URL 形态。
///
/// 精确相等之外还要**忽略 `http://` 差异**:cook 给裸 URL linkify 时会自动
/// 补 scheme(`dl.google.com` → href `http://dl.google.com`),锚文本却还是
/// 没有 scheme 的原样。只认精确相等的话,这种链接会被写成
/// `[dl.google.com](http://dl.google.com)` —— 用户写的裸 URL 被悄悄改写成
/// markdown 链接语法(打开一次帖子就变形)。
///
/// 只放行 `http://`,**不放行 `https://`**:linkify 对无 scheme 裸 URL
/// 一律补 `http://`(cook bundle 实测,域名/www/端口/路径形态无一例外),
/// 所以 `href=https://X` + 锚文本 `X` 只可能是用户手写的 `[X](https://X)`
/// —— 把它裸化的话,重 cook 会补回 `http://`,用户特意写的 https 被静默
/// 降级成 http。
///
/// `mailto:` 同 `http://` 待遇:裸邮箱被 linkify 成
/// `href=mailto:user@example.com` + 无 scheme 锚文本,裸化写回后重 cook
/// 仍产同一个 mailto 链接,往返稳定。
String _inlineToMarkdown(EditableTextContent content) {
  final text = content.text;
  if (text.isEmpty) return '';

  final htmlEmphasis = _hasCrossingMarks(content.marks);

  // 裸链接区间:link mark 覆盖的文本恰等于 href(linkify/onebox 系
  // 链接导入后的形态)→ 不发射 [text](url) 包装,直接吐 URL 本身
  // (raw 保持裸 URL,cook 才会走 onebox/linkify —— `[url](url)` 写法
  // 会固化成普通链接,毁 onebox 语义)。区间内文本不转义(URL 里的
  // `_` 等被转义即断链)。
  final bareLinks = <MarkSpan>{
    for (final m in content.marks)
      if (content.isBareLink(m))
        m,
  };

  // 边界事件表:offset → 该处闭合/开启的 mark 区间
  final opens = <int, List<MarkSpan>>{};
  final closes = <int, List<MarkSpan>>{};
  for (final m in content.marks) {
    opens.putIfAbsent(m.start, () => []).add(m);
    closes.putIfAbsent(m.end, () => []).add(m);
  }

  final buf = StringBuffer();
  // 活动栈(开启顺序);闭合时按 LIFO 补闭到目标再重开(处理交错区间)
  final active = <MarkSpan>[];

  void emitCloses(int offset) {
    final toClose = closes[offset];
    if (toClose == null) return;
    // 需要闭合的集合;从栈顶弹到全部闭完,途中被迫闭合的重开
    final pending = [...toClose];
    final reopen = <MarkSpan>[];
    while (pending.isNotEmpty && active.isNotEmpty) {
      final top = active.removeLast();
      if (!bareLinks.contains(top)) {
        buf.write(_closeTag(top, htmlEmphasis: htmlEmphasis));
      }
      if (!pending.remove(top)) reopen.add(top);
    }
    for (final m in reopen.reversed) {
      if (!bareLinks.contains(m)) {
        buf.write(_openTag(m, htmlEmphasis: htmlEmphasis));
      }
      active.add(m);
    }
  }

  // marks 列表下标(同区间定序用:parser 摊平时外层先入表,列表序即
  // 原 DOM 嵌套方向)。MarkSpan 值相等,重复键取首次出现。
  final markListIndex = <MarkSpan, int>{};
  for (var i = 0; i < content.marks.length; i++) {
    markListIndex.putIfAbsent(content.marks[i], () => i);
  }

  void emitOpens(int offset) {
    final toOpen = opens[offset];
    if (toOpen == null) return;
    // 定序:同区间 mark 尊重列表序(承载原 DOM 嵌套方向,详见
    // compareSameSpanMarkOpen);区间不同(同起不同止)仍按固定嵌套序
    // (spoiler/link 最外)。
    final sorted = [...toOpen]
      ..sort((a, b) {
        if (a.end == b.end) {
          return compareSameSpanMarkOpen(
              a, markListIndex[a] ?? 0, b, markListIndex[b] ?? 0);
        }
        return kMarkNestingOrder
            .indexOf(a.kind)
            .compareTo(kMarkNestingOrder.indexOf(b.kind));
      });
    for (final m in sorted) {
      if (!bareLinks.contains(m)) {
        buf.write(_openTag(m, htmlEmphasis: htmlEmphasis));
      }
      active.add(m);
    }
  }

  bool activeHas(MarkKind kind) => active.any((m) => m.kind == kind);

  var inCode = false;
  for (var i = 0; i <= text.length; i++) {
    emitCloses(i);
    if (i < text.length) {
      // code 状态跟踪(code 内不转义 markdown 元字符)
      inCode = activeHas(MarkKind.inlineCode);
    }
    emitOpens(i);
    if (i >= text.length) break;
    inCode = activeHas(MarkKind.inlineCode);

    final ch = text[i];
    if (ch == kAtomChar) {
      final atom = content.atoms[i];
      buf.write(switch (atom) {
        EmojiRun(:final name) => name.isEmpty ? '' : ':$name:',
        MentionRun(:final username) => '@$username',
        // hashtag 原子:写回 `#ref`(写 URL 会退化成死链接)
        LinkRun(:final hashtagRef) when hashtagRef != null => '#$hashtagRef',
        final LinkRun link => serializeIslandInlines([link]),
        final LocalDateRun d => serializeLocalDate(d),
        // 行内图片原子(裸图):标准图片语法
        final ImageRun img => serializeImageRun(img),
        // `[size=N]` 原子(编辑态固定块):写回 BBCode,连同内部文本
        final SizedRun s => serializeSized(s),
        _ => '',
      });
    } else if (ch == '\n') {
      // 来源软换行原样保留；手动回车/HTML br 仍写行尾双空格。
      buf.write(content.softBreaks.contains(i) ? '\n' : '  \n');
    } else {
      final inBareLink = active.any(bareLinks.contains);
      // 裸 URL 后的闭括号保持字面值；转义用的反斜杠会被 linkify
      // 吞进 URL。其他上下文（例如显式链接的锚文本）仍正常转义。
      final closesBareLink = ch == ']' &&
          !activeHas(MarkKind.link) &&
          (closes[i]?.any(bareLinks.contains) ?? false);
      buf.write(inCode || inBareLink || closesBareLink
          ? ch
          : ch == '\\' && activeHas(MarkKind.link)
              ? r'\\'
              : _escapeInline(ch, i, text));
    }
  }
  // 收尾:未闭合的全部闭合(理论 marks 都有 end,防御)
  while (active.isNotEmpty) {
    buf.write(_closeTag(active.removeLast(), htmlEmphasis: htmlEmphasis));
  }

  return _escapeLineStarts(buf.toString());
}

/// 行内元字符转义(对齐 ProseMirror defaultMarkdownSerializer.escape 口径:
/// 只转义会被 markdown 误解析的字符,不地毯式转义)。
String _escapeInline(String ch, int index, String text) {
  switch (ch) {
    case '[':
      // checklist 例外:`[x]`/`[X]`/`[ ]` 是 Discourse checklist 语法
      // (parser 把 span.chcklst-box 还原成这个字面量),转义会把勾选框
      // 变回纯文本。仅当后面不是 `(`(不会被误认成链接)时保留。
      if (_isChecklistAt(text, index)) return ch;
      // BBCode 例外:手打的 `[size=…]`/`[color=…]` 等被转义后就成了字面
      // 文本,用户在富文本编辑器里根本打不出这些标签(实测:打
      // `[size=1]a[/size]` 存下来是 `\[size=1\]a\[/size\]`)。与 checklist
      // 同理放行 —— 只放行本地 cook 真正会转换的那几个标签。
      if (_bbcodeTagLenAt(text, index) != null) return ch;
      return '\\$ch';
    case ']':
      if (index >= 2 && _isChecklistAt(text, index - 2)) return ch;
      if (_isBbcodeCloseBracketAt(text, index)) return ch;
      return '\\$ch';
    case '*':
    case '_':
    case '`':
      return '\\$ch';
    case '~':
      // 只有连续两个 ~ 才是删除线,单个不转义
      final next = index + 1 < text.length ? text[index + 1] : '';
      final prev = index > 0 ? text[index - 1] : '';
      return (next == '~' || prev == '~') ? '\\$ch' : ch;
    default:
      return ch;
  }
}

/// 本地真正支持往返的 BBCode 标签(开/闭)。范围**刻意收窄**到
/// DiscourseCookService 会在 cook 后补转换、序列化会写回的那几个 ——
/// 放行越多,用户想把 `[foo]` 当字面文本写的场景就越容易被吞。
/// 注意**不要**加 `^`:`matchAsPrefix(text, index)` 本身就锚定在 index,
/// 而 `^` 断言的是整串开头 —— 两者叠加会让 index>0 处的标签(如闭标签)
/// 永远匹配不上(实测:只有位于文首的开标签生效)。
final RegExp _bbcodeTagRe = RegExp(
  r'\[/?(?:size|color|bgcolor|spoiler|u)(?:=[^\]\s]*)?\]',
  caseSensitive: false,
);

/// [index] 处若是已知 BBCode 标签,返回其总长度(含方括号),否则 null。
int? _bbcodeTagLenAt(String text, int index) {
  if (index < 0 || index >= text.length || text[index] != '[') return null;
  final m = _bbcodeTagRe.matchAsPrefix(text, index);
  return m == null ? null : m.end - index;
}

/// [index] 处的 `]` 是否是某个已知 BBCode 标签的收尾方括号。
bool _isBbcodeCloseBracketAt(String text, int index) {
  for (var i = index - 1; i >= 0; i--) {
    final c = text[i];
    if (c == ']') return false; // 中间又出现 ] → 不是同一个标签
    if (c == '[') {
      final len = _bbcodeTagLenAt(text, i);
      return len != null && i + len == index + 1;
    }
  }
  return false;
}

/// [index] 处是否是 checklist 方框(`[x]`/`[X]`/`[ ]`,且其后非 `(`)。
bool _isChecklistAt(String text, int index) {
  if (index < 0 || index + 3 > text.length) return false;
  if (text[index] != '[' || text[index + 2] != ']') return false;
  final mid = text[index + 1];
  if (mid != 'x' && mid != 'X' && mid != ' ') return false;
  return index + 3 >= text.length || text[index + 3] != '(';
}

/// 行首元字符转义(#/>/-/+/数字. 在行首会被解析为块语法)。
String _escapeLineStarts(String text) {
  return text.split('\n').map((line) {
    final m = RegExp(r'^(\s*)([#>+-]|\d+[.)])(\s|$)').firstMatch(line);
    if (m == null) return line;
    final lead = m.group(1)!;
    final mark = m.group(2)!;
    return '$lead\\$mark${line.substring(lead.length + mark.length)}';
  }).join('\n');
}

// ---------------------------------------------------------------------
// 孤岛序列化(阅读端 BlockNode → markdown)
// ---------------------------------------------------------------------

/// 岛节点是否可无损序列化回 markdown。
///
/// false 的类型(chat 客户端 cook 不支持 / policy 属性名不定):序列化
/// 输出空串。**这不是静默丢内容**——编辑已有帖子的导入门禁(二次 cook
/// 等价校验,见主项目 semantic_composer_codec)会因 cooked 不等而拦下整帖,
/// 降级源码模式;编辑器内新建内容不会产生这些岛。
///
/// poll:cooked 里选项(li[data-poll-option-id])/属性(data-poll-*)/
/// 标题(.poll-title)俱全,可从 [PollNode.rawHtml] 重建 `[poll]` BBCode
/// (语法经 cook 探针实测)—— rawHtml 非空即可序列化。
bool islandSerializable(BlockNode node) => switch (node) {
      PollNode(:final rawHtml) => rawHtml.isNotEmpty,
      ChatTranscriptNode() || PolicyNode() => false,
      _ => true,
    };

/// 单个岛节点 → markdown。
///
/// 目标形态 = **raw 的规范写法**(bbcode / markdown / 白名单 HTML),使
/// 「serialize 产物再 cook」与「原 raw 的 cook」等价。语法均经 cook bundle
/// 探针实测(details/spoiler/grid/quote/date/footnote/…)。
///
/// 公开 API:岛源码编辑(双击岛 → 对话框初值)与测试都用。
String serializeIslandNode(BlockNode node) {
  switch (node) {
    case ParagraphNode(:final inlines):
      return serializeIslandInlines(inlines);
    case HeadingNode(:final level, :final inlines):
      return '${'#' * level} ${serializeIslandInlines(inlines)}';
    case CodeBlockNode(:final code, :final language, :final rawHtml, :final rawMarkdown):
      if (rawHtml || rawMarkdown) return code;
      // 围栏必须长于正文中任意反引号 run，而不只是固定加一枚。
      final longest = RegExp(r'`+').allMatches(code).fold<int>(2,
          (length, match) => math.max(length, match.end - match.start));
      final fence = '`' * (longest + 1);
      return '$fence${language ?? ''}\n$code\n$fence';
    case HorizontalRuleNode():
      return '---';
    case BlankLineNode():
      return '';
    case MathBlockNode(:final latex):
      return '\$\$\n$latex\n\$\$';
    case OneboxNode(:final url):
      return url ?? '';
    case LazyVideoNode(:final url):
      // onebox 语义:裸 URL 独行(服务端重 cook 时自然 onebox 化)
      return url;
    case TableNode(:final rows, :final columnCount, :final hasHeader):
      return _serializeTable(rows, columnCount, hasHeader);
    case ListNode():
      return _serializeListNode(node, 0);
    case BlockquoteNode(:final children):
      final inner = children
          .map(serializeIslandNode)
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      return inner.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n');
    case QuoteCardNode():
      // onebox 展开物(编辑器预览 cook 标记):raw 是裸 URL,写回
      // [quote] 块即毁帖(静态引用不跟随原帖)
      if (node.oneboxUrl != null && node.oneboxUrl!.isNotEmpty) {
        return node.oneboxUrl!;
      }
      return _serializeQuoteCard(node);
    case SpoilerBlockNode(:final children):
      final inner = children
          .map(serializeIslandNode)
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      return '[spoiler]\n$inner\n[/spoiler]';
    case DetailsNode(:final summary, :final children, :final initiallyOpen):
      final inner = children
          .map(serializeIslandNode)
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      final summaryAttr = summary.isEmpty ? '' : '="$summary"';
      final openAttr = initiallyOpen ? ' open' : '';
      return '[details$summaryAttr$openAttr]\n$inner\n[/details]';
    case CalloutNode():
      return _serializeCallout(node);
    case ImageGridNode(:final images, :final mode):
      final body = images
          .map((img) => serializeImageRun(img))
          .join('\n');
      final modeAttr =
          mode == ImageGridMode.carousel ? ' mode=carousel' : '';
      return '[grid$modeAttr]\n$body\n[/grid]';
    case FootnotesSectionNode(:final entries):
      return entries
          .map((e) =>
              '[^${e.markdownLabel ?? e.number}]: ${serializeIslandInlines(e.inlines).replaceAll('\n', '\n    ')}')
          .join('\n\n');
    case VideoNode(
        :final src,
        :final origSrc,
        :final mime,
        :final width,
        :final height,
      ):
      final rawMedia = serializeRawMediaHtml(node);
      if (rawMedia != null) return rawMedia;
      // upload:// 上传 → `![|video](短链)`;短链路径/直链 = raw 手写
      // <video> 标签帖(媒体改名上传),写回标签本身(cook 原样保留,
      // 二次 cook 等价)—— 回裸 URL 会被 cook 成链接,毁形态。
      final upload = origSrc ??
          (src.startsWith('upload://') ? src : null);
      if (upload != null) return '![|video]($upload)';
      // 站内相对路径(/uploads/short-url/…,媒体改名上传的手写标签帖)
      // → 写回标签本身(裸相对路径 cook 不成 onebox,回 URL 即毁形态);
      // http(s) 直链维持裸 URL(onebox 语义,原 raw 就是链接)。
      if (src.startsWith('/')) {
        final sizeAttr = (width != null && height != null)
            ? ' width="${width.round()}" height="${height.round()}"'
            : '';
        final typeAttr = mime == null ? '' : ' type="$mime"';
        return '<video$sizeAttr controls>\n'
            '  <source src="$src"$typeAttr>\n'
            '</video>';
      }
      return src;
    case AudioNode(:final src, :final origSrc, :final mime, :final voice):
      final rawMedia = serializeRawMediaHtml(node);
      if (rawMedia != null) return rawMedia;
      final upload = origSrc ??
          (src.startsWith('upload://') ? src : null);
      if (upload != null) return '![|audio]($upload)';
      // 站内相对路径/语音消息 → 写回标签(voice 恒标签:录音上传必是
      // 短链路径,壳内直链是防御分支);http(s) 直链维持裸 URL。
      if (src.startsWith('/') || voice) {
        final typeAttr = mime == null ? '' : ' type="$mime"';
        final tag = '<audio controls>\n'
            '  <source src="$src"$typeAttr>\n'
            '</audio>';
        // 语音消息:带回 [wrap=voice] 壳(cook 产 d-wrap div,本 app
        // 渲染语音条;网页端无样式影响)
        return voice ? '[wrap=voice]\n$tag\n[/wrap]' : tag;
      }
      return src;
    case IframeNode():
      return _serializeIframe(node);
    case SvgNode(:final svgSource):
      // raw 里就是裸 svg HTML(服务端白名单放行;客户端 cook 会剥属性,
      // 编辑导入门禁自然拦下 —— 这里保真输出服务端形态)
      return svgSource;
    case DefinitionListNode(:final items):
      return _serializeDefinitionList(items);
    case PollNode():
      // 从 rawHtml(div.poll cooked 片段)重建 [poll] BBCode:data-poll-*
      // → 属性串;.poll-title → `# 标题` 行;li[data-poll-option-id] →
      // `* 选项` 行(number 型选项由 min/max/step 生成,不写选项行)。
      // rawHtml 缺失(手工构造的节点)时输出空串,islandSerializable
      // 同口径为 false,导入门禁拦整帖。
      return serializePollNode(node);
    case ChatTranscriptNode() || PolicyNode():
      // 已知不可序列化(islandSerializable=false):chat 客户端 cook 不
      // 支持 / policy 属性名不定。空串 —— 导入门禁负责拦整帖(编辑器内
      // 也不可能新建这些岛)。
      return '';
  }
}

/// `[quote="user, post:N, topic:M, username:real, full:true"]` 重建。
///
/// raw 参数顺序对齐 Discourse composer 的 buildQuote:显示名在首位、
/// username: 只在有独立显示名时出现。cooked 属性由 cook 探针实测:
/// data-username / data-display-name / data-post / data-topic / data-full。
String _serializeQuoteCard(QuoteCardNode node) {
  final parts = <String>[];
  if (node.displayName != null) {
    parts.add(node.displayName!);
  } else if (node.username.isNotEmpty) {
    parts.add(node.username);
  }
  if (node.postNumber != null) parts.add('post:${node.postNumber}');
  if (node.topicId != null) parts.add('topic:${node.topicId}');
  if (node.displayName != null && node.username.isNotEmpty) {
    parts.add('username:${node.username}');
  }
  if (node.full) parts.add('full:true');

  final open = parts.isEmpty ? '[quote]' : '[quote="${parts.join(', ')}"]';
  final inner = node.children
      .map(serializeIslandNode)
      .where((s) => s.isNotEmpty)
      .join('\n\n');
  return '$open\n$inner\n[/quote]';
}

/// Obsidian callout:`> [!type](+|-)? 标题` + 正文各行 `> ` 前缀。
String _serializeCallout(CalloutNode node) {
  final fold = switch (node.foldable) {
    true => '+',
    false => '-',
    null => '',
  };
  final title = (node.title ?? '').isEmpty ? '' : ' ${node.title}';
  final lines = <String>['> [!${node.typeRaw}]$fold$title'];
  final inner = node.children
      .map(serializeIslandNode)
      .where((s) => s.isNotEmpty)
      .join('\n\n');
  if (inner.isNotEmpty) {
    for (final l in inner.split('\n')) {
      lines.add(l.isEmpty ? '>' : '> $l');
    }
  }
  return lines.join('\n');
}

/// iframe 白名单 HTML 重建(raw 里就是裸 `<iframe>`;allowed_iframes
/// 命中才被 cook 放行,不命中的门禁自然拦)。
String _serializeIframe(IframeNode node) {
  final buf = StringBuffer('<iframe src="${node.src}"');
  if (node.width != null) {
    buf.write(' width="${_fmtNum(node.width!)}"');
  }
  if (node.height != null) {
    buf.write(' height="${_fmtNum(node.height!)}"');
  }
  if (node.title != null && node.title!.isNotEmpty) {
    buf.write(' title="${node.title}"');
  }
  if (node.allowFullscreen) buf.write(' allowfullscreen');
  if (node.allowFlags.isNotEmpty) {
    buf.write(' allow="${node.allowFlags.join('; ')}"');
  }
  if (node.sandboxFlags.isNotEmpty) {
    buf.write(' sandbox="${node.sandboxFlags.join(' ')}"');
  }
  if (node.referrerPolicy != null) {
    buf.write(' referrerpolicy="${node.referrerPolicy}"');
  }
  if (node.lazyLoad) buf.write(' loading="lazy"');
  buf.write('></iframe>');
  return buf.toString();
}

/// `<dl>` 白名单 HTML 重建(markdown 无 dl 语法,raw 里就是裸 HTML;
/// cook 探针实测原样放行)。
String _serializeDefinitionList(List<DefinitionItem> items) {
  final buf = StringBuffer('<dl>');
  for (final item in items) {
    if (item.term.isNotEmpty) {
      buf.write('<dt>${serializeIslandInlines(item.term)}</dt>');
    }
    for (final dd in item.definitions) {
      final inner = dd
          .map(serializeIslandNode)
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      buf.write('<dd>$inner</dd>');
    }
  }
  buf.write('</dl>');
  return buf.toString();
}

/// 数字属性:整数值不带小数点(690.0 → "690",与 raw 习惯一致)。
String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toString();

String _serializeListNode(ListNode list, int depth) {
  final lines = <String>[];
  for (var i = 0; i < list.items.length; i++) {
    final item = list.items[i];
    final indent = ' ' * depth;
    final marker = list.ordered ? '${list.start + i}. ' : '- ';
    if (i > 0 && list.loose) lines.add('');
    lines.add('$indent$marker${serializeIslandInlines(item.inlines)}');
    for (final sub in item.children ?? const <ListNode>[]) {
      if (list.loose) lines.add('');
      lines.add(_serializeListNode(sub, depth + marker.length));
    }
    // 块级子节点(岛化列表可能含):缩进后原样接
    for (final b in item.blocks ?? const <BlockNode>[]) {
      final s = serializeIslandNode(b);
      if (s.isNotEmpty) {
        if (list.loose) lines.add('');
        final continuation = '$indent${' ' * marker.length}';
        lines.add(s.split('\n').map((l) => '$continuation$l').join('\n'));
      }
    }
  }
  return lines.join('\n');
}

/// 表格 cell → 单行 markdown 文本(公开:表格结构化编辑器的初值也用)。
/// 多块 cell 拼空格;换行/管道符转义(markdown 表格 cell 单行约束)。
String tableCellToMarkdown(TableCellData cell) => cell.children
    .map(serializeIslandNode)
    .where((s) => s.isNotEmpty)
    .join(' ')
    .replaceAll('\n', ' ')
    .replaceAll('|', r'\|');

/// 纯文本网格 → markdown 表格(表格结构化编辑器确认后重建 raw 用)。
/// [cells] 行×列;[hasHeader] 首行作表头。cell 内管道转义。
String tableGridToMarkdown(List<List<String>> cells, {
  bool hasHeader = true,
  List<TextAlign?> alignments = const [],
}) {
  if (cells.isEmpty) return '';
  final cols = cells.map((r) => r.length).reduce(math.max);
  String esc(String s) =>
      s.replaceAll('\n', ' ').replaceAll('|', r'\|').trim();
  String rowLine(List<String> row) => '| ${[
        for (var c = 0; c < cols; c++) c < row.length ? esc(row[c]) : '',
      ].join(' | ')} |';

  final divider = '| ${List.generate(cols, (c) => _tableSeparator(c < alignments.length ? alignments[c] : null)).join(' | ')} |';
  final lines = <String>[];
  if (hasHeader) {
    lines.add(rowLine(cells.first));
    lines.add(divider);
    for (final row in cells.skip(1)) {
      lines.add(rowLine(row));
    }
  } else {
    lines.add('| ${List.filled(cols, ' ').join(' | ')} |');
    lines.add(divider);
    for (final row in cells) {
      lines.add(rowLine(row));
    }
  }
  return lines.join('\n');
}

String _tableSeparator(TextAlign? alignment) => switch (alignment) {
  TextAlign.left => ':---',
  TextAlign.center => ':---:',
  TextAlign.right => '---:',
  _ => '---',
};

String _serializeTable(
  List<List<TableCellData>> rows,
  int columnCount,
  bool hasHeader,
) {
  if (rows.isEmpty) return '';

  String rowLine(List<TableCellData> row) {
    final cells = [
      for (var c = 0; c < columnCount; c++)
        c < row.length ? tableCellToMarkdown(row[c]) : '',
    ];
    return '| ${cells.join(' | ')} |';
  }

  final lines = <String>[];
  final divider = '| ${List.generate(columnCount, (c) => _tableSeparator(c < rows.first.length ? rows.first[c].alignment : null)).join(' | ')} |';
  if (hasHeader) {
    lines.add(rowLine(rows.first));
    lines.add(divider);
    for (final row in rows.skip(1)) {
      lines.add(rowLine(row));
    }
  } else {
    // markdown 表格必须有 header 行;无 header 时补空头
    lines.add('| ${List.filled(columnCount, ' ').join(' | ')} |');
    lines.add(divider);
    for (final row in rows) {
      lines.add(rowLine(row));
    }
  }
  return lines.join('\n');
}

// ---------------------------------------------------------------------
// 字面 markdown → 原子(input rules / 粘贴降级解析用)
// ---------------------------------------------------------------------

final RegExp _imageMdRe =
    RegExp(r'^!\[([^\]]*?)(?:\|(\d+)x(\d+)(?:,\s*(\d+)%)?)?\]\(([^)]*)\)$');

/// 字面图片语法 → [ImageRun];不匹配返回 null。
///
/// `upload://` 短链同时写进 origSrc —— 那是 raw 的规范形态,序列化必须
/// 写回短链(见 [serializeImageRun])。
ImageRun? parseImageMarkdown(String literal) {
  final m = _imageMdRe.firstMatch(literal);
  if (m == null) return null;
  final src = m.group(5)!;
  final w = double.tryParse(m.group(2) ?? '');
  final h = double.tryParse(m.group(3) ?? '');
  final scale = double.tryParse(m.group(4) ?? '');
  return ImageRun(
    src: src,
    alt: m.group(1) ?? '',
    origSrc: src.startsWith('upload://') ? src : null,
    width: w,
    height: h,
    origWidth: w,
    origHeight: h,
    scale: scale,
  );
}
