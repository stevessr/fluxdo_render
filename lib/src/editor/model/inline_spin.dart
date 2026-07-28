/// ir spin:整块扫描「完整合法的行内标记对」并折叠为 mark。
///
/// Vditor ir 语义的核心一环:任何删改(退格/前删/选区删/IME 退格)落地
/// 后整块重扫,**不存在「语法合法但不渲染」的滞留态** —— 用户删出
/// `**bold**` 字面的那一刻它就折叠回 strong。
///
/// 定位与分工:
/// - **只做字面→mark**;mark→字面的反向由物化
///   ([EditorState.materializeMarkAt] / 复合退格)负责;
/// - 与 input rules(打字触发器,input_rules.dart)共享
///   inline_pair_defs.dart 的定界符表 —— 「什么算一对完整合法标记」
///   单一真相,约束完全同源:内容非空、不含 '\n'、BBCode 内容不含
///   `[`、HTML 内容不含 `<`、首尾非空格(inlineCode 例外,反引号内
///   允许空格,与 input rules 同款)、命中区不与 inlineCode mark 重叠;
/// - **不折叠** link `[text](href)` 与图片 `![alt](src)`(第一期取舍:
///   它们折叠产物不是纯 mark —— 图片是原子、链接带 href 语义,滞留
///   字面可由用户按 `)` 经 input rules 触发,风险收益比不划算);
/// - 原子哨兵(U+FFFC)与 ASCII 定界符无重叠,内容含原子照折。
///
/// 纯函数:不碰 EditorState/历史,调用方(EditorState._maybeSpin)在
/// 既有事务 _commit 前对新 content 施加 = 同一 undo 步。
library;

import '../input/inline_pair_defs.dart';
import 'editable_text_content.dart';

/// spin 结果:折叠后的内容 + 重映射后的 caret。
/// 无命中时 content 与入参 **identical**(调用方可据此免拷贝)。
typedef SpinResult = ({EditableTextContent content, int caret});

/// 单轮命中:`[start, start+openLen+contentLen+closeLen)` 是一对完整
/// 合法标记,折叠为 [kind](attr 进 mark)。
typedef _PairHit = ({
  int start,
  int openLen,
  int contentLen,
  int closeLen,
  MarkKind kind,
  String? attr,
});

/// BBCode 属性标记完整对(非锚定扫描版;group 1 = attr,group 2 = 内容)。
final List<(RegExp, MarkKind, String)> _bbcodeAttrScanRules = [
  for (final (open, kind, close) in kBbcodeAttrSpecs)
    (
      RegExp('$open$kBbcodeContentPattern${RegExp.escape(close)}'),
      kind,
      close,
    ),
];

/// 快退探针:任一定界符族的首字符。text 一个都不含时 spin 必然无命中,
/// O(n) 一趟直接返回(删改主路径绝大多数是纯文本,别让它们扫全表)。
bool _hasDelimiterStart(String text) {
  for (var i = 0; i < text.length; i++) {
    switch (text.codeUnitAt(i)) {
      case 0x2A: // *
      case 0x7E: // ~
      case 0x60: // `
      case 0x5F: // _
      case 0x5B: // [
      case 0x3C: // <
        return true;
    }
  }
  return false;
}

/// 命中区是否与既有 inlineCode mark 重叠(代码字面量区,不折叠)。
bool _overlapsInlineCode(EditableTextContent c, int start, int end) {
  for (final m in c.marks) {
    if (m.kind == MarkKind.inlineCode && m.start < end && start < m.end) {
      return true;
    }
  }
  return false;
}

/// 对 [content] 整块扫描折叠,循环至不动点。
///
/// [caret] 重映射:命中区前不动;命中区后左移(两段定界符长度);开
/// 定界符内 clamp 到折叠区起点;闭定界符内 clamp 到折叠后内容尾;内容
/// 内减开定界符长。每轮取**最靠前**命中(同起点按表序 —— 长定界符
/// 特异性优先,与 input rules 表序同源);嵌套对(`***x***`)由多轮
/// 自然收敛:外对先折,内对下一轮再折。
///
/// [maxPasses]:不动点防御上限(每轮至少删 1 个定界符字符,文本单调
/// 变短,理论必然终止;上限只防未知病态)。
SpinResult spinInlineMarks(
  EditableTextContent content, {
  required int caret,
  int maxPasses = 32,
}) {
  if (!_hasDelimiterStart(content.text)) {
    return (content: content, caret: caret);
  }
  var cur = content;
  var pos = caret.clamp(0, content.text.length);
  for (var pass = 0; pass < maxPasses; pass++) {
    final hit = _findEarliestPair(cur);
    if (hit == null) break;
    final openEnd = hit.start + hit.openLen;
    final contentEnd = openEnd + hit.contentLen;
    final matchEnd = contentEnd + hit.closeLen;
    cur = cur
        .delete(contentEnd, matchEnd)
        .delete(hit.start, openEnd)
        .applyMark(hit.start, hit.start + hit.contentLen, hit.kind,
            attr: hit.attr);
    pos = _remapCaret(pos, hit.start, openEnd, contentEnd, matchEnd);
  }
  return (content: cur, caret: pos);
}

int _remapCaret(int p, int start, int openEnd, int contentEnd, int matchEnd) {
  final openLen = openEnd - start;
  final closeLen = matchEnd - contentEnd;
  if (p <= start) return p;
  if (p < openEnd) return start; // 开定界符内 → 折叠区起点
  if (p <= contentEnd) return p - openLen; // 内容内(含边界)
  if (p < matchEnd) return contentEnd - openLen; // 闭定界符内 → 内容尾
  return p - openLen - closeLen; // 命中区后 → 整体左移
}

/// 全表扫一轮,取最靠前的合法命中;无命中返回 null。
_PairHit? _findEarliestPair(EditableTextContent content) {
  final text = content.text;
  _PairHit? best;

  void consider(_PairHit h) {
    if (best == null || h.start < best!.start) best = h;
  }

  bool valid(int start, int end, String inner) =>
      !inner.contains('\n') && !_overlapsInlineCode(content, start, end);

  // markdown 对称定界符(首尾非空格/内容非空由正则编码,lookbehind 零宽
  // 不计入 m.start)
  for (final (re, kind, delim) in kInlineScanRules) {
    for (final m in re.allMatches(text)) {
      if (best != null && m.start >= best!.start) break;
      final inner = m.group(1)!;
      if (!valid(m.start, m.end, inner)) continue;
      consider((
        start: m.start,
        openLen: delim.length,
        contentLen: inner.length,
        closeLen: delim.length,
        kind: kind,
        attr: null,
      ));
      break;
    }
  }

  // BBCode 属性标记(group 1 = attr,group 2 = 内容)
  for (final (re, kind, close) in _bbcodeAttrScanRules) {
    for (final m in re.allMatches(text)) {
      if (best != null && m.start >= best!.start) break;
      final inner = m.group(2)!;
      if (!valid(m.start, m.end, inner)) continue;
      consider((
        start: m.start,
        openLen: m.group(0)!.length - inner.length - close.length,
        contentLen: inner.length,
        closeLen: close.length,
        kind: kind,
        attr: m.group(1),
      ));
      break;
    }
  }

  // BBCode 无 attr 标记 / HTML 样式标签(字面标签对;内容禁字符 =
  // 各自闭标签的首字符,与 input rules 同款)
  void scanLiteral(
    List<(String, MarkKind, String)> tags, {
    required String forbidden,
  }) {
    for (final (open, kind, close) in tags) {
      var from = 0;
      while (true) {
        final o = text.indexOf(open, from);
        if (o < 0 || (best != null && o >= best!.start)) break;
        final cs = o + open.length;
        final ce = text.indexOf(close, cs);
        if (ce < 0) break; // 右侧再无闭标记,后续 open 也无望
        final inner = text.substring(cs, ce);
        final end = ce + close.length;
        if (inner.isNotEmpty &&
            !inner.contains(forbidden) &&
            !inner.startsWith(' ') &&
            !inner.endsWith(' ') &&
            valid(o, end, inner)) {
          consider((
            start: o,
            openLen: open.length,
            contentLen: inner.length,
            closeLen: close.length,
            kind: kind,
            attr: null,
          ));
          break;
        }
        from = o + 1; // 本 open 不合法,试下一个
      }
    }
  }

  scanLiteral(kBbcodeMarkTags, forbidden: '[');
  scanLiteral(kHtmlMarkTags, forbidden: '<');

  return best;
}
