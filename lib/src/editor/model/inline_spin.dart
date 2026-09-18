/// ir spin:整块「物化 → 重折叠」到不动点(Vditor 整块重解析的等价物)。
///
/// Vditor ir 语义的核心一环:任何编辑落地后整块重解析,**不存在
/// 「语法合法但不渲染」的滞留态**。v1 只折叠纯字面标记对,盲区是
/// **字面与既有 mark 的混合形态**:`*1*` 折叠成 em 后,用户在前后各补
/// 一个 `*` —— 文档是 字面`*` + em(1) + 字面`*`,序列化明明是 `**1**`
/// 却永远不会变粗体(纯字面扫描看不见 mark)。
///
/// v2 两阶段:
/// 1. **全量物化**:把块内所有**可安全往返**的 mark 展开回字面定界符,
///    与用户新打的字面汇成一份纯 markdown 源文本;
/// 2. **重折叠**:对源文本跑完整对扫描循环,按 CommonMark 语义重新
///    成 mark —— `*` + em(1) + `*` → `**1**` → strong(1)。
///
/// **可安全往返**(_refoldableMark)是物化的准入门槛:mark 的字面形态
/// `open+content+close` 必须能被折叠规则原样折回(探针实折验证)。
/// 折不回的(内容含定界字符/首尾空格 —— cook 导入的 `<strong> x</strong>`
/// 等合法形态)**不物化**,连同 link/inlineCode 一起作为**排除区**:
/// 折叠命中不得跨其边界(可整体包住 —— `**a`x`b**` 字面星号包住 code
/// mark 折成嵌套是合法的;不可切进去 —— 防止 mark 内容里的字面 `*` 与
/// 外部字面配对撕裂区间)。
///
/// 不动点契约:结果与入参等价(text/marks/atoms 逐项)时返回
/// **identical** 入参 —— 调用方免拷贝、渲染缓存不失效;文本无任何
/// 字面定界符时 O(n) 快退(普通打字/删改零正则开销)。
///
/// 回归防线:重折叠折不回输入已有的结构(如 em 前打 `*` 得 `**1*`,
/// em 规则 lookbehind 拒绝)时放弃本轮 spin —— 结构只增不减,中间态
/// 保持「字面 + mark」混合(与 CommonMark 对 `**1*` 的解析视觉一致),
/// 等后续编辑补全再折。
///
/// 纯函数:不碰 EditorState/历史,调用方(EditorState._maybeSpin)在
/// 既有事务 _commit 前对新 content 施加 = 同一 undo 步。
library;

import 'package:flutter/foundation.dart' show listEquals, mapEquals;

import '../input/inline_pair_defs.dart';
import 'editable_text_content.dart';
import 'markdown_serializer.dart'
    show compareSameSpanMarkOpen, markOpeningDelimiter, markClosingDelimiter;

/// spin 结果:折叠后的内容 + 重映射后的 caret。
/// 无变化时 content 与入参 **identical**(调用方可据此免拷贝)。
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
    (RegExp('$open$kBbcodeContentPattern${RegExp.escape(close)}'), kind, close),
];

/// 快退/触发探针:任一定界符族的首字符。text 一个都不含时字面折叠必然
/// 无命中(物化-重折叠恒等),O(n) 一趟直接返回。也供编辑事务判断
/// 「插入的是格式符还是普通内容」—— 含定界符字符的插入不做 inclusive
/// 延伸(格式符是语法,归字面平面重解析,不该被吸进 mark 当内容)。
bool hasInlineDelimiterChar(String text) {
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

/// link 完整字面对:`[label](href)`(label 非空不含 `]`,href 不含
/// `)`/空白;`!` 前缀是图片,lookbehind 排除)。折叠带 **caret 守卫**:
/// caret 还停在字面区间内(正在编辑 href/label)不折,离开才折 ——
/// 否则打完 `(` 的瞬间就被折走,URL 没法输入(Vditor 同款语义:光标
/// 所在节点保持展开态)。
final RegExp kLinkPairRe = RegExp(r'(?<!!)\[([^\]\n]+)\]\(([^)\s]*)\)');

/// 对 [content] 做「物化 → 重折叠」,返回等价重排后的内容与 caret。
///
/// [caret] 两阶段重映射:物化阶段随字面插入平移(边界落**内侧** ——
/// 恰在 mark.start 停开定界符后、恰在 mark.end 停闭定界符前:编辑事务
/// 后的 caret 贴边 = 刚在格式内编辑完,留在格式内;点击进入的外侧语义
/// 见 [materializeMarksToLiteral]),折叠阶段按 [_remapCaret] 回收 ——
/// 纯 mark 内容往返后 caret 不变。
///
/// [guardAtCaret]:光标守卫 —— true(默认)时光标驻留的字面对跳过
/// 不折(光标所在节点保持展开态,字面区内编辑不被折走 —— Vditor
/// 同款);false = 全折(光标离开收口/序列化安全口)。
///
/// [guardInclusive]:守卫口径 —— false(默认,编辑事务后)严格内部
/// (打完闭定界符立即折叠);true(光标移动收口)闭区间(贴字面区
/// 边界也算驻留,防「折叠→贴边→重物化」振荡与提前折叠打断补字符)。
///
/// [maxPasses]:折叠循环防御上限(每轮至少消掉一对定界符,文本单调
/// 变短,理论必然终止;上限只防未知病态)。
SpinResult spinInlineMarks(
  EditableTextContent content, {
  required int caret,
  bool guardAtCaret = true,
  bool guardInclusive = false,
  int maxPasses = 32,
}) {
  // 快退:无字面定界符 = 折叠必无命中、物化-重折叠恒等。普通打字/
  // 删改(含带 mark 的块)零正则开销。
  if (!hasInlineDelimiterChar(content.text)) {
    return (content: content, caret: caret);
  }

  // 阶段一:物化可安全往返的 mark;折不回的留作排除区。
  final m9n = _materializeAll(content, caret.clamp(0, content.length));
  var cur = m9n.content;
  var pos = m9n.caret;
  var exclusions = m9n.exclusions;

  // 阶段二:重折叠,循环至不动点。守卫跳过过的命中说明光标驻留在某
  // 字面对内部(进入态),记录下来供回归防线放行。
  var guardSkipped = false;
  for (var pass = 0; pass < maxPasses; pass++) {
    final (hit, skipped) = _findEarliestPair(
      cur,
      exclusions,
      guardCaret: guardAtCaret ? pos : null,
      guardInclusive: guardInclusive,
    );
    guardSkipped = guardSkipped || skipped;
    if (hit == null) break;
    final openEnd = hit.start + hit.openLen;
    final contentEnd = openEnd + hit.contentLen;
    final matchEnd = contentEnd + hit.closeLen;
    cur = cur
        .delete(contentEnd, matchEnd)
        .delete(hit.start, openEnd)
        .applyMark(
          hit.start,
          hit.start + hit.contentLen,
          hit.kind,
          attr: hit.attr,
          isAutoLink: hit.kind == MarkKind.link ? false : null,
        );
    pos = _remapCaret(pos, hit.start, openEnd, contentEnd, matchEnd);
    exclusions = [
      for (final (s, e) in exclusions)
        if (s >= matchEnd)
          (s - hit.openLen - hit.closeLen, e - hit.openLen - hit.closeLen)
        else if (s >= openEnd)
          (s - hit.openLen, e - hit.openLen) // 命中内容区里(被整体包住)
        else
          (s, e),
    ];
  }

  // 回归防线:折不回输入已有的结构 → 放弃本轮(结构只增不减)。
  // 例外:守卫跳过过命中 = 光标驻留在字面对内部,物化态是**有意保持**
  // 的(进入即物化的架构主路径),放行 —— 这正是「光标进入 mark 展开
  // 为可编辑字面」的实现本体。
  if (cur.marks.length < content.marks.length && !guardSkipped) {
    return (content: content, caret: caret);
  }

  // 不动点:与入参等价 → identical 返回。
  if (cur.text == content.text &&
      listEquals(cur.marks, content.marks) &&
      mapEquals(cur.atoms, content.atoms)) {
    return (content: content, caret: caret);
  }
  return (content: cur, caret: pos);
}

/// [m] 能否安全物化:字面形态 `open+content+close` 经折叠规则**原样折
/// 回同 kind/attr/区间**(探针实折)。link 含原子哨兵/嵌套破坏形态与
/// inlineCode(物化后内容里的 `*` 等会裸奔与外部配对)排除。
///
/// 公开给状态层做「进入物化」的簇判定(materializeClusterAt)——
/// 物化准入与 spin 折叠能力必须同口径,否则展开了折不回去。
bool isRefoldableMark(EditableTextContent c, MarkSpan m) {
  if (m.kind == MarkKind.inlineCode || c.isBareLink(m)) return false;
  final inner = c.text.substring(m.start, m.end);
  if (m.kind == MarkKind.link) {
    // link 可物化(点击进入改 href 的主路径),但 label 含原子哨兵的
    // 嵌套图片链接不拆(物化再折叠会丢原子)。
    if ((m.attr ?? '').isEmpty) return false;
    if (inner.contains(kAtomChar)) return false;
    if (inner.isEmpty || inner.contains(']') || inner.contains('\n')) {
      return false;
    }
    final href = m.attr!;
    if (href.contains(')') || href.contains(' ')) return false;
    return true;
  }
  final open = markOpeningDelimiter(m);
  final close = markClosingDelimiter(m);
  if (open.isEmpty || close.isEmpty) return false;
  if (inner.isEmpty) return false;
  final probe = EditableTextContent(text: '$open$inner$close');
  final (hit, _) = _findEarliestPair(probe, const []);
  return hit != null &&
      hit.start == 0 &&
      hit.kind == m.kind &&
      hit.attr == m.attr &&
      hit.openLen == open.length &&
      hit.closeLen == close.length &&
      hit.contentLen == inner.length;
}

/// [cluster] 中的 mark 展开为字面(状态层「进入物化」用;与 spin 内部
/// 物化阶段同一事件排序)。link 的字面 = `[label](href)`(开 `[`、闭
/// `](href)`,定界符文案本就如此)。
///
/// caret 边界语义 = **外侧**(boundaryOutside):点击折叠 mark 边界进入
/// 时,光标视觉在格式外,物化后应停定界符外 —— 打字落格式外。与 spin
/// 物化阶段(内侧)相反:那边 caret 贴 mark.end 是「刚在格式内打完字」,
/// 必须留在闭定界符前继续写。
({EditableTextContent content, int caret}) materializeMarksToLiteral(
  EditableTextContent c,
  Set<MarkSpan> cluster, {
  required int caret,
}) {
  final r = _materializeSet(
    c,
    cluster,
    caret.clamp(0, c.length),
    boundaryOutside: true,
  );
  return (content: r.content, caret: r.caret);
}

/// 兼容旧名(spin 内部物化判定;link/inlineCode 恒 false 的严格版 ——
/// spin 的**自动**物化不含 link,link 只在光标进入时显式物化,避免
/// 每次编辑都把无关 link 展开又折回)。
bool _refoldableMark(EditableTextContent c, MarkSpan m) =>
    m.kind != MarkKind.link && isRefoldableMark(c, m);

/// 阶段一产物:物化后内容 + caret + 排除区(未物化 mark 的新坐标区间)。
typedef _Materialized = ({
  EditableTextContent content,
  int caret,
  List<(int, int)> exclusions,
});

/// 把所有可安全往返的 mark 展开回字面定界符。
///
/// 插入事件按 offset 从尾向头统一施加(偏移互不污染);同 offset 排序:
/// 闭定界符先于开定界符(相邻 mark A.end==B.start 的字面应为 …A闭B开…),
/// 开定界符之间外层在前、闭定界符之间内层在前(同区间尊重 marks 列表
/// 序 [compareSameSpanMarkOpen] —— 与显形/序列化发射序同源,嵌套方向
/// 不翻转)。未物化 mark(link/inlineCode/折不回的)与 atoms 的区间由
/// [EditableTextContent.insert] 现有语义平移,其新坐标作为排除区返回。
///
/// caret 平移:严格在 caret 前的插入推右移;边界并列时 caret 留在字面
/// 区**外侧**——恰在 mark.start 的开定界符不推(caret 停开定界符前),
/// 恰在 mark.end 的闭定界符推(caret 停闭定界符后)。折叠态光标贴 mark
/// 边界 = Vditor 源码坐标里光标在定界符外侧:物化后打字落格式外、退格/
/// 前删吃的是定界符字符(破坏格式,符合预期),而不是钻进内容区。
_Materialized _materializeAll(EditableTextContent c, int caret) {
  final materialize = <MarkSpan>{
    for (final m in c.marks)
      if (_refoldableMark(c, m)) m,
  };
  return _materializeSet(c, materialize, caret);
}

/// [materialize] 集合展开为字面的通用实现(spin 阶段一与状态层
/// materializeMarksToLiteral 共用)。
///
/// [boundaryOutside]:caret 恰在 mark 边界时的落位 —— false(spin 物化,
/// 默认)落**内侧**(贴 mark.end = 刚在格式内编辑完,停闭定界符前继续
/// 写;贴 mark.start 停开定界符后);true(点击进入物化)落**外侧**
/// (光标视觉在格式外,物化后停定界符外,打字落格式外)。
_Materialized _materializeSet(
  EditableTextContent c,
  Set<MarkSpan> materialize,
  int caret, {
  bool boundaryOutside = false,
}) {
  final marks = c.marks;
  final kept = [
    for (final m in marks)
      if (!materialize.contains(m)) m,
  ];
  if (materialize.isEmpty) {
    return (
      content: c,
      caret: caret,
      exclusions: [for (final m in kept) (m.start, m.end)],
    );
  }

  final listIndex = <MarkSpan, int>{};
  for (var i = 0; i < marks.length; i++) {
    listIndex.putIfAbsent(marks[i], () => i);
  }
  int openCompare(MarkSpan a, MarkSpan b) {
    if (a.start == b.start && a.end == b.end) {
      return compareSameSpanMarkOpen(
        a,
        listIndex[a] ?? 0,
        b,
        listIndex[b] ?? 0,
      );
    }
    return (b.end - b.start).compareTo(a.end - a.start); // 覆盖长的在外
  }

  final events =
      <({int offset, String literal, bool opening, MarkSpan mark})>[
        for (final m in materialize) ...[
          (
            offset: m.start,
            literal: markOpeningDelimiter(m),
            opening: true,
            mark: m,
          ),
          (
            offset: m.end,
            literal: markClosingDelimiter(m),
            opening: false,
            mark: m,
          ),
        ],
      ]..sort((x, y) {
        final byOffset = x.offset.compareTo(y.offset);
        if (byOffset != 0) return byOffset;
        if (x.opening != y.opening) return x.opening ? 1 : -1; // 闭先于开
        if (x.opening) return openCompare(x.mark, y.mark); // 开:外层先
        return openCompare(y.mark, x.mark); // 闭:内层先
      });

  var out = EditableTextContent(
    text: c.text,
    marks: kept,
    atoms: c.atoms,
    softBreaks: c.softBreaks,
  );
  var newCaret = caret;
  for (final e in events.reversed) {
    out = out.insert(e.offset, e.literal);
    // 边界落位([boundaryOutside] 两档):
    // - 内侧(spin 物化):恰在 caret 的开定界符推(caret 停开后 = 原
    //   内容位置)、闭不推(停闭前 = 内容尾)—— 刚编辑完的光标留在
    //   格式内,工具栏 pending 打字后连续输入不被挤出包装;
    // - 外侧(点击进入):开不推、闭推 —— 折叠态光标贴边 = 视觉在
    //   格式外,物化后打字落格式外(「光标在末尾输入却进里面」的修法)。
    final pushAtCaret = boundaryOutside ? !e.opening : e.opening;
    if (e.offset < newCaret || (pushAtCaret && e.offset == newCaret)) {
      newCaret += e.literal.length;
    }
  }
  // 排除区 = 未物化 mark 在插入后的新区间(insert 已平移,直接读)。
  return (
    content: out,
    caret: newCaret,
    exclusions: [for (final m in out.marks) (m.start, m.end)],
  );
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
///
/// [exclusions]:未物化 mark 的区间。命中不得**切进**排除区(部分重叠
/// 会撕裂 mark 内容与外部字面的配对);允许命中的**内容区**整体包住
/// 排除区(字面对包住 link/code mark 折成嵌套是合法结构 —— 定界符段
/// 本身不得触碰排除区)。
///
/// [guardCaret]:caret 守卫(所有 kind 统一)—— caret 严格在字面对区间
/// 内部时该命中跳过(返回值第二项 = 是否发生过守卫跳过,回归防线据此
/// 识别「光标驻留物化态」),光标移到边界/外部才折。
// 即使调用方传入含空行的单块，也不得把两个段落的定界符配成一对。
// 先分段再扫描，而非命中后拒绝，避免无效跨段命中吞掉后段的开符。
final RegExp _paragraphBoundary = RegExp(r'\r?\n[ \t\r]*\n');

(_PairHit?, bool) _findEarliestPair(
  EditableTextContent content,
  List<(int, int)> exclusions, {
  int? guardCaret,
  bool guardInclusive = false,
}) {
  final boundaries = _paragraphBoundary.allMatches(content.text).toList();
  if (boundaries.isEmpty) {
    return _findPairInParagraph(
      content,
      exclusions,
      guardCaret: guardCaret,
      guardInclusive: guardInclusive,
    );
  }
  var start = 0;
  var skipped = false;
  for (final end in [...boundaries.map((m) => m.start), content.length]) {
    final (hit, guarded) = _findPairInParagraph(
      content.slice(start, end),
      [
        for (final (s, e) in exclusions)
          if (s < end && e > start) (s - start, e - start),
      ],
      guardCaret: guardCaret == null ? null : guardCaret - start,
      guardInclusive: guardInclusive,
    );
    skipped = skipped || guarded;
    if (hit != null) {
      return (
        (
          start: hit.start + start,
          openLen: hit.openLen,
          contentLen: hit.contentLen,
          closeLen: hit.closeLen,
          kind: hit.kind,
          attr: hit.attr,
        ),
        skipped,
      );
    }
    // 分隔符包含空行；跳过它后继续找下一段。
    final boundary = _paragraphBoundary.matchAsPrefix(content.text, end);
    start = boundary?.end ?? end;
  }
  return (null, skipped);
}

(_PairHit?, bool) _findPairInParagraph(
  EditableTextContent content,
  List<(int, int)> exclusions, {
  int? guardCaret,
  bool guardInclusive = false,
}) {
  final text = content.text;
  _PairHit? best;
  var guardSkipped = false;

  void consider(_PairHit h) {
    if (best == null || h.start < best!.start) best = h;
  }

  bool allowed(int start, int openLen, int contentLen, int closeLen) {
    final openEnd = start + openLen;
    final contentEnd = openEnd + contentLen;
    final matchEnd = contentEnd + closeLen;
    for (final (s, e) in exclusions) {
      final intersects = start < e && s < matchEnd;
      if (!intersects) continue;
      // 仅允许「内容区整体包住排除区」(定界符段不触碰)
      if (!(openEnd <= s && e <= contentEnd)) return false;
    }
    return true;
  }

  // caret 守卫(所有 kind 统一):光标驻留的字面对跳过不折。
  // 两档口径([guardInclusive]):
  // - 严格内部(默认,编辑事务后的 spin):caret 在区间内部才算驻留
  //   —— 打完闭定界符(caret == matchEnd)立即折叠,input rules 的
  //   即时成型语义;
  // - 闭区间(光标移动收口):贴边界(== start / == matchEnd)也算
  //   驻留 —— 移动到字面区头尾不折,否则折叠后光标又贴回 mark 边界
  //   被重物化(振荡),且「在开定界符前补字符」会被提前折叠打断。
  bool guarded(int start, int matchEnd) {
    final c = guardCaret;
    if (c == null) return false;
    final inside = guardInclusive
        ? (c >= start && c <= matchEnd)
        : (c > start && c < matchEnd);
    if (inside) {
      guardSkipped = true;
      return true;
    }
    return false;
  }

  bool valid(
    int start,
    int openLen,
    int contentLen,
    int closeLen,
    String inner,
  ) {
    // 单个换行属于块内 inline 内容；段落边界已在外层隔离。
    if (guarded(start, start + openLen + contentLen + closeLen)) return false;
    return allowed(start, openLen, contentLen, closeLen);
  }

  // link `[label](href)` → link mark(href 进 attr)
  for (final m in kLinkPairRe.allMatches(text)) {
    if (best != null && m.start >= best!.start) break;
    final label = m.group(1)!;
    final href = m.group(2)!;
    // label 含原子哨兵不拆(嵌套图片链接交给 cook)
    if (label.contains(kAtomChar)) continue;
    final openLen = 1; // `[`
    final closeLen = m.end - (m.start + 1 + label.length); // `](href)`
    if (!valid(m.start, openLen, label.length, closeLen, label)) continue;
    consider((
      start: m.start,
      openLen: openLen,
      contentLen: label.length,
      closeLen: closeLen,
      kind: MarkKind.link,
      attr: href,
    ));
    break;
  }

  // markdown 对称定界符
  for (final (re, kind, delim) in kInlineScanRules) {
    for (final m in re.allMatches(text)) {
      if (best != null && m.start >= best!.start) break;
      final inner = m.group(1)!;
      // 行内代码仍遵守原有单行契约，不借强调修复扩大语法范围。
      if (kind == MarkKind.inlineCode && inner.contains('\n')) continue;
      if (!valid(m.start, delim.length, inner.length, delim.length, inner)) {
        continue;
      }
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
      final openLen = m.group(0)!.length - inner.length - close.length;
      if (!valid(m.start, openLen, inner.length, close.length, inner)) {
        continue;
      }
      consider((
        start: m.start,
        openLen: openLen,
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
        if (inner.isNotEmpty &&
            !inner.contains(forbidden) &&
            !inner.startsWith(' ') &&
            !inner.endsWith(' ') &&
            valid(o, open.length, inner.length, close.length, inner)) {
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

  return (best, guardSkipped);
}

/// 字面语法命中(展示着色用,只读):`[start, end)` 是一对完整合法
/// 标记,open/close 段是定界符,中间是内容。
typedef InlineSyntaxHit = ({
  int start,
  int openLen,
  int contentLen,
  int closeLen,
  MarkKind kind,
  String? attr,
});

/// 只读扫描 [content] 里的全部完整字面标记对(ir 编辑态语法着色用:
/// 内容段按 kind 上样式、定界符段淡色 —— Vditor「符号可见 + 格式
/// 保持」)。**不折叠不改模型**,坐标全是 content.text 真实坐标。
///
/// 嵌套:命中后对**内容段**递归扫描(`**a*b*c**` → strong 对 + 内层
/// em 对),深度上限防病态;交错/不完整形态只出外层或不出,展示宁缺
/// 毋错。排除区语义与折叠扫描一致(不切进未物化 mark)。
List<InlineSyntaxHit> scanInlineSyntax(EditableTextContent content) {
  if (!hasInlineDelimiterChar(content.text)) return const [];
  final out = <InlineSyntaxHit>[];

  // [exclusions] 为**当前切片坐标**;递归内容段时外层已保证不切进
  // 排除区(allowed 检查),子切片传其内部残留的排除区(通常为空)。
  void scanRange(
    String text,
    int base,
    List<(int, int)> exclusions,
    int depth,
  ) {
    if (depth > 4) return;
    var slice = text;
    var offset = base;
    var ex = exclusions;
    for (var pass = 0; pass < 32; pass++) {
      final (hit, _) = _findEarliestPair(EditableTextContent(text: slice), ex);
      if (hit == null) break;
      out.add((
        start: offset + hit.start,
        openLen: hit.openLen,
        contentLen: hit.contentLen,
        closeLen: hit.closeLen,
        kind: hit.kind,
        attr: hit.attr,
      ));
      // 内容段递归(嵌套着色;内容包住的排除区换算进子坐标)
      final innerStart = hit.start + hit.openLen;
      final innerEnd = innerStart + hit.contentLen;
      final inner = slice.substring(innerStart, innerEnd);
      if (hasInlineDelimiterChar(inner)) {
        scanRange(inner, offset + innerStart, [
          for (final (s, e) in ex)
            if (s >= innerStart && e <= innerEnd)
              (s - innerStart, e - innerStart),
        ], depth + 1);
      }
      // 跳过本命中继续扫尾部
      final matchEnd = innerEnd + hit.closeLen;
      if (matchEnd >= slice.length) break;
      ex = [
        for (final (s, e) in ex)
          if (s >= matchEnd) (s - matchEnd, e - matchEnd),
      ];
      offset += matchEnd;
      slice = slice.substring(matchEnd);
    }
  }

  scanRange(content.text, 0, [
    for (final m in content.marks) (m.start, m.end),
  ], 0);
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}
