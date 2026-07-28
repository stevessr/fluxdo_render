/// 可编辑段落的扁平行内模型。
///
/// 编辑操作(插入/删除/切分/合并)在**扁平坐标**上做:一个段落 =
/// 一段纯文本 + 样式区间([MarkSpan]) + 原子表([atoms])。这与
/// ProseMirror 的 inline 表示(text + marks + 原子 node)同构 ——
/// 编辑是 O(区间数) 的简单区间调整,不需要在嵌套树上找路径。
///
/// **原子节点**(M2):emoji/mention 在文本里用 [kAtomChar](U+FFFC,
/// OBJECT REPLACEMENT CHARACTER)占 1 个 code unit,身份存 [atoms]
/// (offset → 原 InlineNode 引用)。选型依据:
/// - FFFC 恰是 Flutter WidgetSpan 的渲染占位字符,渲染/投影层的原子
///   entry 机制已存在;
/// - 与 IME pad(空格)/软换行 ZWSP(U+200B)/codePad NBSP(U+00A0)
///   互不冲突;
/// - grapheme 步长恒 1 → M1 的退格/光标移动逻辑天然把原子当一个单位。
/// 用户输入里的裸 FFFC 由 [sanitizeText] 剥除(防 IME 回显幻造原子)。
///
/// 渲染时通过 [toInlines] 转回 [InlineNode] 树喂现有 InlineFlattener,
/// 保证编辑态与阅读态视觉零差异(行内代码 NBSP 灰底等精调全部复用)。
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../../node/inline_node.dart';
import '../../parser/paragraph_parser.dart' show ParagraphParser;
import 'markdown_serializer.dart'
    show kMarkNestingOrder, markOpeningDelimiter, markClosingDelimiter;

/// 原子哨兵字符(U+FFFC OBJECT REPLACEMENT CHARACTER)。
const String kAtomChar = '\uFFFC';

/// 行内样式种类(编辑模型用)。
enum MarkKind {
  em,
  strong,
  inlineCode,
  underline,
  lineThrough,

  /// 行内剧透 `[spoiler]…[/spoiler]`(SpoilerRun)。编辑态显示淡遮罩
  /// 底纹(内容可见可编辑,对齐官方 rich editor 的 spoiler-blurred
  /// decoration 思路的简化版)。
  spoilerInline,

  /// 链接 `[text](href)`(LinkRun)。带 attr(href)—— 见 [MarkSpan.attr]。
  /// 编辑态蓝色下划线,不可点(编辑器语义)。
  link,

  /// 前景色 `[color=X]…[/color]`(ColoredRun.color)。attr 存 **X 的 CSS
  /// 原文**(`red` / `#F00` / `#ff0000` …,服务端 bbcode-color 插件原样
  /// 透传进 style)—— 序列化逐字写回才能过往返门禁,渲染取色时才 parse。
  ///
  /// 做成 mark 而不是留给 ColoredRun 岛化,是因为岛是**不可编辑**的:
  /// 打完一句带色的话整行会变成只读岛、光标直接消失(实测复现)。
  /// 做成 mark 后文字照常可编辑,颜色只是区间样式。
  textColor,

  /// 背景色 `[bgcolor=#rrggbb]…[/bgcolor]`(ColoredRun.background)。
  bgColor,

  /// 字号 `[size=N]…[/size]`(SizedRun.scale)。attr 存百分比字符串
  /// (`_pct`/`parsePct`,如 `150`)。做成 mark 而非留给 SizedRun 岛化,
  /// 同 textColor 的理由 —— 岛不可编辑,mark 化后一行内可以混多个不同
  /// size 区间,逐字正常编辑。
  size,

  /// 其余 HTML 样式标签(`<small>`/`<big>`/`<mark>`/`<sup>`/`<sub>`/
  /// `<kbd>`)→ StyledRun(InlineStyleKind.X)。同 underline 一样纯样式、
  /// 无 attr,mark 化道理相同。
  smallStyle,
  bigStyle,
  markStyle,
  superscript,
  subscript,
  monospaceStyle,
}

/// [MarkKind] ↔ [InlineStyleKind] 双向映射(纯样式类,无 attr 的那六个)。
InlineStyleKind? _styleKindFor(MarkKind kind) => switch (kind) {
      MarkKind.smallStyle => InlineStyleKind.small,
      MarkKind.bigStyle => InlineStyleKind.big,
      MarkKind.markStyle => InlineStyleKind.mark,
      MarkKind.superscript => InlineStyleKind.superscript,
      MarkKind.subscript => InlineStyleKind.subscript,
      MarkKind.monospaceStyle => InlineStyleKind.monospace,
      _ => null,
    };

MarkKind? _markKindFor(InlineStyleKind kind) => switch (kind) {
      InlineStyleKind.underline => MarkKind.underline,
      InlineStyleKind.lineThrough => MarkKind.lineThrough,
      InlineStyleKind.small => MarkKind.smallStyle,
      InlineStyleKind.big => MarkKind.bigStyle,
      InlineStyleKind.mark => MarkKind.markStyle,
      InlineStyleKind.superscript => MarkKind.superscript,
      InlineStyleKind.subscript => MarkKind.subscript,
      InlineStyleKind.monospace => MarkKind.monospaceStyle,
    };

/// 一段样式区间 `[start, end)`(扁平文本坐标)。
///
/// [attr]:mark 的附加值([MarkKind.link] 的 href、颜色系的色值)。同 kind
/// 不同 attr 的区间**不合并**(两个不同链接相邻仍是两个链接)。
@immutable
class MarkSpan {
  const MarkSpan({
    required this.start,
    required this.end,
    required this.kind,
    this.attr,
  });

  final int start;
  final int end;
  final MarkKind kind;

  /// kind 相关附加值:link=href;其余 null。
  final String? attr;

  bool get isEmpty => start >= end;

  MarkSpan copyWith({int? start, int? end}) => MarkSpan(
        start: start ?? this.start,
        end: end ?? this.end,
        kind: kind,
        attr: attr,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MarkSpan &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end &&
          kind == other.kind &&
          attr == other.attr;

  @override
  int get hashCode => Object.hash(start, end, kind, attr);

  @override
  String toString() =>
      'MarkSpan($kind [$start,$end)${attr == null ? "" : " $attr"})';
}

/// 段落的扁平可编辑内容(不可变;编辑原语返回新实例)。
@immutable
class EditableTextContent {
  EditableTextContent({
    required this.text,
    List<MarkSpan> marks = const [],
    Map<int, InlineNode> atoms = const {},
  })  : marks = List.unmodifiable(
          marks.where((m) => !m.isEmpty).toList()
            ..sort((a, b) {
              final c = a.start.compareTo(b.start);
              return c != 0 ? c : a.end.compareTo(b.end);
            }),
        ),
        atoms = Map.unmodifiable(atoms),
        assert(
          atoms.keys.every(
            (o) => o >= 0 && o < text.length && text[o] == kAtomChar,
          ),
          'atoms 的每个 offset 必须指向文本中的 kAtomChar',
        );

  static final EditableTextContent empty = EditableTextContent(text: '');

  final String text;

  /// 按 start 升序;同 kind 区间不重叠(编辑原语与 [toggleMarkInRange]
  /// 维护该语义,构造器只做排序/去空)。
  final List<MarkSpan> marks;

  /// 原子表:offset(指向 text 中的 [kAtomChar])→ 原 InlineNode
  /// (EmojiRun/MentionRun;M2 白名单,其他类型由 doc_converter 拦在岛外)。
  final Map<int, InlineNode> atoms;

  int get length => text.length;

  /// 剥除文本里的裸 FFFC(用户/IME 输入不允许自带哨兵 —— 只能经
  /// [insertAtom]/fromInlines 建立原子)。
  static String sanitizeText(String input) =>
      input.contains(kAtomChar) ? input.replaceAll(kAtomChar, '') : input;

  /// Color → `#rrggbb`(mark attr 存这个形态,与序列化口径一致)。
  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// 倍数 → 百分比字符串(`1.5` → `150`;整数不写小数点,与 raw 口径一致)。
  ///
  /// `scale * 100` 是浮点乘法,`0.07 * 100` 会算出 `7.000000000000001`
  /// 这类脏值(0-400 里有几十个 N 中招),直接 `'$v'` 就把脏值写进 raw。
  /// 与最近整数差在浮点误差量级(1e-6)内的按整数写。
  static String _pct(double scale) {
    final v = scale * 100;
    final rounded = v.round();
    if ((v - rounded).abs() < 1e-6) return rounded.toString();
    return '$v';
  }

  /// 百分比字符串 → 倍数(`150` → `1.5`);解析不出返回 null。
  static double? parsePct(String? v) {
    if (v == null) return null;
    final n = double.tryParse(v.trim());
    return (n == null || n < 0) ? null : n / 100.0;
  }

  /// `#rgb` / `#rrggbb` → Color;解析不出返回 null。
  static Color? parseHex(String? v) {
    if (v == null) return null;
    var h = v.trim();
    if (!h.startsWith('#')) return null;
    h = h.substring(1);
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    if (h.length != 6) return null;
    final n = int.tryParse(h, radix: 16);
    return n == null ? null : Color(0xFF000000 | n);
  }

  /// [offset] 处(其后)的字符是否原子。
  bool isAtomAt(int offset) => atoms.containsKey(offset);

  // -----------------------------------------------------------------
  // InlineNode 树 ↔ 扁平 双向转换
  // -----------------------------------------------------------------

  /// 从渲染节点树构建扁平模型。
  ///
  /// 支持:TextRun / EmRun / StrongRun / InlineCodeRun /
  /// StyledRun(underline|lineThrough) / LineBreakRun(转 '\n')/
  /// **EmojiRun / MentionRun(原子,M2)/ SpoilerRun / LinkRun(M5)**。
  ///
  /// 其余节点(image/footnote/...)不在编辑白名单 —— 调用方
  /// (doc_converter.isEditableInline)负责拦截整块岛化,此处的降级
  /// 分支仅作纯文本兜底(防御,不应在正常链路走到)。
  factory EditableTextContent.fromInlines(List<InlineNode> inlines) {
    final buf = StringBuffer();
    final marks = <MarkSpan>[];
    final atoms = <int, InlineNode>{};
    _flattenInto(inlines, buf, marks, atoms, const []);
    return EditableTextContent(
      text: buf.toString(),
      marks: marks,
      atoms: atoms,
    );
  }

  /// 活动 mark 帧:kind + 可选 attr(link 的 href)。
  static void _flattenInto(
    List<InlineNode> nodes,
    StringBuffer buf,
    List<MarkSpan> marks,
    Map<int, InlineNode> atoms,
    List<(MarkKind, String?)> activeKinds,
  ) {
    for (final node in nodes) {
      switch (node) {
        // 防御:显形虚拟定界符只存在于编辑渲染产物,不该被喂回模型;
        // 不拦的话会落进下面的 TextRun 分支(子类),把 `**` 字面量写进
        // 文档 —— 显形泄漏成真字符。
        case EditingDelimiterRun():
          break;
        case TextRun(:final text):
          _appendText(buf, marks, activeKinds, sanitizeText(text));
        case LineBreakRun():
          _appendText(buf, marks, activeKinds, '\n');
        case EmRun(:final children):
          _flattenInto(children, buf, marks, atoms,
              [...activeKinds, (MarkKind.em, null)]);
        case StrongRun(:final children):
          _flattenInto(children, buf, marks, atoms,
              [...activeKinds, (MarkKind.strong, null)]);
        case InlineCodeRun(:final text):
          _appendText(
            buf,
            marks,
            [...activeKinds, (MarkKind.inlineCode, null)],
            sanitizeText(text),
          );
        case StyledRun(:final kind, :final children):
          final mapped = _markKindFor(kind);
          _flattenInto(
            children,
            buf,
            marks,
            atoms,
            mapped == null ? activeKinds : [...activeKinds, (mapped, null)],
          );
        // ---- M5 白名单:行内剧透 / 链接(mark 化,内容可编辑) ----
        case SpoilerRun(:final children):
          _flattenInto(children, buf, marks, atoms,
              [...activeKinds, (MarkKind.spoilerInline, null)]);
        case LinkRun(:final href, :final children, :final isOneboxLink):
          if (isOneboxLink) {
            // 裸 URL 的 linkify 链接:编辑器显示 URL 本身(锚文本可能
            // 是 cook 种子取回的页面标题,但 raw 是裸 URL —— 显示 href
            // 才能让序列化的 text==attr 裸 URL 规则保住往返)
            _appendText(buf, marks,
                [...activeKinds, (MarkKind.link, href)], sanitizeText(href));
          } else {
            _flattenInto(children, buf, marks, atoms,
                [...activeKinds, (MarkKind.link, href)]);
          }
        // ---- 原子(一等公民):哨兵占位 + 身份入表 ----
        case EmojiRun():
          atoms[buf.length] = node;
          _appendText(buf, marks, activeKinds, kAtomChar);
        case MentionRun():
          atoms[buf.length] = node;
          _appendText(buf, marks, activeKinds, kAtomChar);
        case LocalDateRun():
          // 时间 chip:行内原子(M5;序列化写回 [date=…])
          atoms[buf.length] = node;
          _appendText(buf, marks, activeKinds, kAtomChar);
        case ImageRun():
          // 图片:行内原子,无条件(isEditableInline 同判据 —— 官方
          // ProseMirror image 是 inline:true 一等行内节点)
          atoms[buf.length] = node;
          _appendText(buf, marks, activeKinds, kAtomChar);
        case SizedRun(:final scale, :final pctRaw, :final children):
          // 字号 → 带 attr 的 mark(见 MarkKind.size 注释:岛化不可编辑,
          // mark 化后一行内可以混多个不同 size 区间)。attr 优先存 cooked
          // 里的原文(pctRaw),程序化构造(pctRaw=null)才按 scale 计算。
          _flattenInto(children, buf, marks, atoms,
              [...activeKinds, (MarkKind.size, pctRaw ?? _pct(scale))]);
        case ColoredRun(
            :final color,
            :final background,
            :final colorRaw,
            :final backgroundRaw,
            :final children
          ):
          // 颜色 → 带 attr 的 mark(见 MarkKind.textColor 注释:岛化会
          // 让整行变只读、光标消失)。attr 优先存 CSS 原文(colorRaw/
          // backgroundRaw,`red`/`#F00` 等逐字保留),程序化构造才写 hex。
          // 只有原文没有 Color(取色失败)也照样成 mark —— 渲染降级无色,
          // 但序列化必须把原文写回。
          _flattenInto(children, buf, marks, atoms, [
            ...activeKinds,
            if (background != null || backgroundRaw != null)
              (MarkKind.bgColor, backgroundRaw ?? _hex(background!)),
            if (color != null || colorRaw != null)
              (MarkKind.textColor, colorRaw ?? _hex(color!)),
          ]);
        // ---- 白名单外(防御降级,正常链路由 doc_converter 拦截岛化) ----
        case FootnoteRefRun():
        case ClickCountRun():
        case MathInlineRun():
          break;
      }
    }
  }

  static void _appendText(
    StringBuffer buf,
    List<MarkSpan> marks,
    List<(MarkKind, String?)> activeKinds,
    String text,
  ) {
    if (text.isEmpty) return;
    final start = buf.length;
    buf.write(text);
    final end = buf.length;
    // 去重:嵌套同类标签(<em><strong><em>)会让 kind 重复出现,
    // 重复处理会产出重叠区间(破坏"同 kind 不重叠"语义与往返不动点)。
    // link 按 (kind, attr) 去重 —— 不同 href 的嵌套链接理论不存在
    // (HTML 不允许 a 嵌 a),同帧只会有一个 href。
    for (final frame in {...activeKinds}) {
      final (kind, attr) = frame;
      // 与紧邻的同 kind 同 attr 区间合并(嵌套展开会产生相邻碎段)。
      final lastIdx =
          marks.lastIndexWhere((m) => m.kind == kind && m.attr == attr);
      if (lastIdx >= 0 && marks[lastIdx].end == start) {
        marks[lastIdx] = marks[lastIdx].copyWith(end: end);
      } else {
        marks.add(MarkSpan(start: start, end: end, kind: kind, attr: attr));
      }
    }
  }

  /// 转回 InlineNode 树(渲染用)。
  ///
  /// 策略:按所有区间边界 + 原子位置切文本为片段;原子片段直接吐回
  /// [atoms] 里的原节点(样式区间对原子不生效 —— emoji 图片没有粗体;
  /// 但 spoiler/link 包装保留,原子也在剧透/链接里)。
  /// 嵌套顺序固定:spoiler > link > strong > em > underline > lineThrough;
  /// inlineCode 独占。
  ///
  /// [forEditing]:编辑段落渲染模式。spoilerInline/link **不包装**为
  /// SpoilerRun/LinkRun(前者是 WidgetSpan 粒子遮罩会破坏文本编辑,
  /// 后者的 TapGestureRecognizer 会抢编辑器手势),改用纯 TextSpan 视觉
  /// 替代:spoiler=淡灰底纹(内容可见可编辑,对齐官方 rich editor 的
  /// spoiler-blurred decoration 思路的简化),link=[editingLinkColor]
  /// 字色 + 下划线。
  ///
  /// [revealMarkdownAt]:显形位置(内容偏移;仅 [forEditing] 生效)。
  /// 光标命中的 mark 区间(含边界)两端插 [EditingDelimiterRun] 虚拟
  /// 定界符(零逻辑宽,纯渲染投影);null = 不显形。
  /// [editingDelimiterColor]:定界符淡色(主题 outline)。
  List<InlineNode> toInlines({
    bool forEditing = false,
    Color? editingLinkColor,
    Color? editingDelimiterColor,
    int? revealMarkdownAt,
  }) {
    if (text.isEmpty) return const [];

    final revealedMarks = forEditing && revealMarkdownAt != null
        ? revealableMarksAt(revealMarkdownAt)
        : const <MarkSpan>[];

    // 1. 收集切点
    final cuts = <int>{0, text.length};
    for (final m in marks) {
      cuts.add(m.start.clamp(0, text.length));
      cuts.add(m.end.clamp(0, text.length));
    }
    // '\n' 与原子单独成段
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\n' || text[i] == kAtomChar) {
        cuts.add(i);
        cuts.add(i + 1);
      }
    }
    final points = cuts.toList()..sort();

    // 2. 逐片段构建
    final out = <InlineNode>[];

    // 显形定界符:片段边界处按嵌套序发射(开定界符外层先、闭定界符
    // 内层先 —— 与序列化 kMarkNestingOrder 单一真相,显示形态 = raw 形态)。
    void appendDelimiters(int offset, {required bool opening}) {
      if (revealedMarks.isEmpty) return;
      final atOffset = <MarkSpan>[
        for (final mark in revealedMarks)
          if ((opening ? mark.start : mark.end) == offset) mark,
      ];
      if (atOffset.isEmpty) return;
      int order(MarkSpan m) => kMarkNestingOrder.indexOf(m.kind);
      atOffset.sort((a, b) {
        if (opening) {
          // 外层先开:覆盖更长(end 更大)在前;同界按固定嵌套序。
          final byEnd = b.end.compareTo(a.end);
          if (byEnd != 0) return byEnd;
          return order(a).compareTo(order(b));
        }
        // 内层先闭:start 更大在前;同界按固定嵌套序反向。
        final byStart = b.start.compareTo(a.start);
        if (byStart != 0) return byStart;
        return order(b).compareTo(order(a));
      });
      for (final mark in atOffset) {
        final delimiter = opening
            ? markOpeningDelimiter(mark)
            : markClosingDelimiter(mark);
        if (delimiter.isEmpty) continue; // 覆盖不了的 kind:宁缺毋错
        out.add(EditingDelimiterRun(delimiter, color: editingDelimiterColor));
      }
    }

    for (var i = 0; i + 1 < points.length; i++) {
      final s = points[i];
      final e = points[i + 1];
      if (s >= e) continue;
      appendDelimiters(s, opening: false);
      appendDelimiters(s, opening: true);
      final piece = text.substring(s, e);
      if (piece == '\n') {
        out.add(const LineBreakRun());
        continue;
      }
      final kinds = <MarkKind>{
        for (final m in marks)
          if (m.start <= s && m.end >= e) m.kind,
      };
      // link href:覆盖片段的 link mark 的 attr(同帧唯一)
      String? href;
      // 颜色/字号:同 kind 多个区间覆盖同一片段时(嵌套
      // `[color=red]a[color=blue]b[/color]c[/color]`),取**最窄**覆盖
      // 区间的 attr —— CSS 内层胜语义(内层 span 的 style 覆盖外层)。
      String? fgHex;
      String? bgHex;
      String? sizePct;
      var fgW = -1, bgW = -1, szW = -1;
      for (final m in marks) {
        if (m.start > s || m.end < e) continue;
        final w = m.end - m.start;
        switch (m.kind) {
          case MarkKind.link:
            href ??= m.attr;
          case MarkKind.textColor:
            if (fgW < 0 || w < fgW) {
              fgW = w;
              fgHex = m.attr;
            }
          case MarkKind.bgColor:
            if (bgW < 0 || w < bgW) {
              bgW = w;
              bgHex = m.attr;
            }
          case MarkKind.size:
            if (szW < 0 || w < szW) {
              szW = w;
              sizePct = m.attr;
            }
          default:
            break;
        }
      }
      if (piece == kAtomChar) {
        final atom = atoms[s];
        if (atom != null) {
          // 原子保留 spoiler/link 包装(基础样式对原子不生效)
          out.add(_wrapAtom(atom, kinds, href, forEditing: forEditing));
        }
        // 无身份的孤儿哨兵(不变量破坏,构造器断言防):静默丢弃。
        continue;
      }
      out.add(_wrapPiece(piece, kinds, href,
          forEditing: forEditing,
          editingLinkColor: editingLinkColor,
          fgHex: fgHex,
          bgHex: bgHex,
          sizePct: sizePct));
    }
    appendDelimiters(text.length, opening: false);
    return _applyOnlyEmoji(out);
  }

  /// 显形探测:光标(collapsed)在 [offset] 时需要展开定界符的 mark
  /// 集合 —— 区间**含边界**命中(`start <= caret <= end`,官方
  /// getMarkRange 的 inclusive 语义:贴着 mark 两端也显形)。
  List<MarkSpan> revealableMarksAt(int offset) {
    final caret = offset.clamp(0, text.length);
    return [
      for (final mark in marks)
        if (mark.start <= caret && caret <= mark.end) mark,
    ];
  }

  /// Discourse 大表情语义:整段**只有** emoji(空白不算内容)且不超过
  /// [_maxOnlyEmoji] 个 → 全部标 isOnlyEmoji(渲染 32dp);超了则全部
  /// 普通尺寸。规则与 cook 引擎实测一致:
  /// `:a:`→1 大 / `:a: :a: :a:`→3 全大 / 4 个→全不大。
  ///
  /// 放在 [toInlines] 里而不是只放导出路径,是因为编辑器实时渲染
  /// (editable_paragraph)和导出(doc_converter)走的是同一个出口 ——
  /// 只在导出侧标记会导致"刚插入的 emoji 是小的,切到源码再切回来才
  /// 变大"(实测复现)。
  static List<InlineNode> _applyOnlyEmoji(List<InlineNode> out) {
    var emojiCount = 0;
    for (final n in out) {
      if (n is EmojiRun) {
        emojiCount++;
        continue;
      }
      // 显形虚拟定界符不算内容(零逻辑宽,纯渲染投影)—— 否则光标进入
      // 覆盖纯 emoji 段的 mark 时,大表情会因定界符出现而突然缩小。
      if (n is EditingDelimiterRun) continue;
      // 纯空白的文本片段不算内容;其余任何节点都让本段不再是"只有表情"
      if (n is TextRun && n.text.trim().isEmpty) continue;
      return out;
    }
    if (emojiCount == 0) return out;
    final large = emojiCount <= _maxOnlyEmoji;
    var changed = false;
    final result = [
      for (final n in out)
        if (n is EmojiRun && n.isOnlyEmoji != large)
          () {
            changed = true;
            return EmojiRun(name: n.name, url: n.url, isOnlyEmoji: large);
          }()
        else
          n,
    ];
    return changed ? result : out;
  }

  /// 超过这个数量就不再算大表情(对齐 Discourse)。
  static const int _maxOnlyEmoji = 3;

  static InlineNode _wrapAtom(
    InlineNode atom,
    Set<MarkKind> kinds,
    String? href, {
    required bool forEditing,
  }) {
    if (forEditing) return atom; // 编辑态原子裸渲染(遮罩/链接壳都不加)
    InlineNode node = atom;
    if (kinds.contains(MarkKind.link)) {
      node = LinkRun(href: href ?? '', children: [node]);
    }
    if (kinds.contains(MarkKind.spoilerInline)) {
      node = SpoilerRun(children: [node]);
    }
    return node;
  }

  static InlineNode _wrapPiece(
    String piece,
    Set<MarkKind> kinds,
    String? href, {
    required bool forEditing,
    Color? editingLinkColor,
    String? fgHex,
    String? bgHex,
    String? sizePct,
  }) {
    InlineNode node;
    if (kinds.contains(MarkKind.inlineCode)) {
      node = InlineCodeRun(piece);
    } else {
      node = TextRun(piece);
      if (kinds.contains(MarkKind.lineThrough)) {
        node = StyledRun(kind: InlineStyleKind.lineThrough, children: [node]);
      }
      if (kinds.contains(MarkKind.underline) ||
          (forEditing && kinds.contains(MarkKind.link))) {
        // 编辑态 link 借下划线样式(真 LinkRun 的 recognizer 会抢手势)
        node = StyledRun(kind: InlineStyleKind.underline, children: [node]);
      }
      for (final k in const [
        MarkKind.smallStyle,
        MarkKind.bigStyle,
        MarkKind.markStyle,
        MarkKind.superscript,
        MarkKind.subscript,
        MarkKind.monospaceStyle,
      ]) {
        if (kinds.contains(k)) {
          node = StyledRun(kind: _styleKindFor(k)!, children: [node]);
        }
      }
      if (kinds.contains(MarkKind.em)) {
        node = EmRun(children: [node]);
      }
      if (kinds.contains(MarkKind.strong)) {
        node = StrongRun(children: [node]);
      }
    }
    if (forEditing) {
      // 编辑态视觉替代:link 字色经 ColoredRun(纯 TextSpan,投影透明,
      // 选区/光标/IME 全不受扰)。spoiler 的底纹+虚线框由
      // EditableParagraph._SpoilerDecorPainter 按 mark 区间自绘
      // (这里不加底纹 —— painter 的圆角框视觉更完整)。
      if (kinds.contains(MarkKind.link)) {
        node = ColoredRun(
          color: editingLinkColor ?? const Color(0xFF1F7AED),
          children: [node],
        );
      }
      node = _applyColorMarks(node, kinds, fgHex, bgHex);
      if (kinds.contains(MarkKind.size)) {
        node = _applySizeMark(node, sizePct, forEditing: forEditing);
      }
      return node;
    }
    node = _applyColorMarks(node, kinds, fgHex, bgHex);
    if (kinds.contains(MarkKind.size)) {
      node = _applySizeMark(node, sizePct, forEditing: forEditing);
    }
    // link/spoiler 包最外(阅读端 <a>/<span class=spoiler> 里嵌样式的形态)
    if (kinds.contains(MarkKind.link)) {
      node = LinkRun(href: href ?? '', children: [node]);
    }
    if (kinds.contains(MarkKind.spoilerInline)) {
      node = SpoilerRun(children: [node]);
    }
    return node;
  }

  /// 字号极小(< [hiddenSizeThreshold])时编辑态视为"隐藏标记":夹到
  /// 一个仍可读的小尺寸(而不是变全透明/宽度塌陷),配合
  /// [EditableParagraph] 的 badge 描边框,让用户看得出"这段有隐藏内容"
  /// 且能点进去编辑,不是无提示地变成一段视觉正常的文字。
  static const double hiddenSizeThreshold = 0.15;

  /// 隐藏标记态的编辑态可读尺寸(小于正常字号但不到不可读程度)。
  static const double hiddenSizeEditingScale = 0.6;

  /// 字号 mark → SizedRun。
  ///
  /// **编辑态夹下限**:`[size=0]`(或极小值)真按原值画在编辑器里就是
  /// 隐形/挤成一条缝的,根本没法编辑。夹到 [hiddenSizeEditingScale] 而
  /// 非直接钳成 1 倍 —— 视觉上明显偏小,加上 badge 描边框,一眼能看出
  /// 这是"隐藏内容"而不是普通文字。非隐藏范围(≥ 阈值)的缩放不夹 ——
  /// **判定是严格小于**:`[size=15]` 恰为 0.15 倍,是用户合法设置的
  /// 15% 字号,不是隐藏内容,不能误伤。
  /// 用户设的正常倍数(哪怕 <1)照原样画。
  /// 阅读端([forEditing] = false)不夹,原样对齐网页端。
  /// 注意夹的只是**渲染**;raw 由 mark 的 attr(原文)决定,发出去仍是原值。
  static InlineNode _applySizeMark(
    InlineNode node,
    String? pct, {
    required bool forEditing,
  }) {
    final scale = parsePct(pct);
    if (scale == null) return node;
    final effective =
        forEditing && scale < hiddenSizeThreshold ? hiddenSizeEditingScale : scale;
    return SizedRun(scale: effective, pctRaw: pct, children: [node]);
  }

  /// 颜色 mark → ColoredRun(前景/背景可同时存在,合成一个节点)。
  ///
  /// attr 是 CSS 原文(`red`/`#F00`…)—— 渲染取色走 parser 的完整 CSS
  /// 色解析;解析失败时不上色(渲染降级),但原文仍带在 Run 上,
  /// 序列化写回不丢。
  static InlineNode _applyColorMarks(
    InlineNode node,
    Set<MarkKind> kinds,
    String? fgHex,
    String? bgHex,
  ) {
    final fgRaw = kinds.contains(MarkKind.textColor) ? fgHex : null;
    final bgRaw = kinds.contains(MarkKind.bgColor) ? bgHex : null;
    if (fgRaw == null && bgRaw == null) return node;
    return ColoredRun(
      color: ParagraphParser.parseCssColor(fgRaw),
      background: ParagraphParser.parseCssColor(bgRaw),
      colorRaw: fgRaw,
      backgroundRaw: bgRaw,
      children: [node],
    );
  }

  // -----------------------------------------------------------------
  // 编辑原语(全部返回新实例;atoms 表随区间同步平移)
  // -----------------------------------------------------------------

  /// 在 [offset] 处插入 [inserted]。样式区间调整规则:
  /// - 区间完全在插入点前/后:不变/整体右移;
  /// - 插入点在区间内部(start < offset < end):区间拉长(延续样式,
  ///   对齐主流编辑器"在粗体中间打字仍是粗体");
  /// - 插入点恰在区间边界:不延续(在粗体结尾打字回到正常)。
  ///
  /// 注意:[inserted] 未经 [sanitizeText] —— 调用方(EditorState/
  /// insertAtom)负责;insertAtom 恰要插入哨兵本体,不能在这里一刀切剥。
  EditableTextContent insert(int offset, String inserted) {
    assert(offset >= 0 && offset <= text.length);
    if (inserted.isEmpty) return this;
    final len = inserted.length;
    final newMarks = <MarkSpan>[];
    for (final m in marks) {
      if (m.end <= offset) {
        newMarks.add(m);
      } else if (m.start >= offset) {
        newMarks.add(m.copyWith(start: m.start + len, end: m.end + len));
      } else {
        newMarks.add(m.copyWith(end: m.end + len));
      }
    }
    return EditableTextContent(
      text: text.replaceRange(offset, offset, inserted),
      marks: newMarks,
      atoms: {
        for (final e in atoms.entries)
          (e.key >= offset ? e.key + len : e.key): e.value,
      },
    );
  }

  /// 在 [offset] 处插入一个原子(哨兵 + 身份)。
  EditableTextContent insertAtom(int offset, InlineNode atom) {
    assert(offset >= 0 && offset <= text.length);
    final withChar = insert(offset, kAtomChar);
    return EditableTextContent(
      text: withChar.text,
      marks: withChar.marks,
      atoms: {...withChar.atoms, offset: atom},
    );
  }

  /// 删除 `[start, end)` 区间(区间内的原子随之消失)。
  EditableTextContent delete(int start, int end) {
    assert(start >= 0 && end <= text.length && start <= end);
    if (start == end) return this;
    final len = end - start;
    final newMarks = <MarkSpan>[];
    for (final m in marks) {
      // 区间平移/收缩:与删除区间求差。
      final ns = m.start <= start
          ? m.start
          : (m.start >= end ? m.start - len : start);
      final ne = m.end <= start ? m.end : (m.end >= end ? m.end - len : start);
      final span = m.copyWith(start: ns, end: ne);
      if (!span.isEmpty) newMarks.add(span);
    }
    return EditableTextContent(
      text: text.replaceRange(start, end, ''),
      marks: newMarks,
      atoms: {
        for (final e in atoms.entries)
          if (e.key < start)
            e.key: e.value
          else if (e.key >= end)
            e.key - len: e.value,
      },
    );
  }

  /// 取 `[start, end)` 子区间(复制/选区片段提取)。
  /// marks/atoms 随区间裁剪平移(delete 组合,先尾后头保偏移正确)。
  EditableTextContent slice(int start, int end) {
    assert(start >= 0 && end <= text.length && start <= end);
    return delete(end, text.length).delete(0, start);
  }

  /// 替换 `[start, end)` 为 [replacement](IME composing 更新的主路径)。
  /// 替换 `[start, end)` 为 [replacement]。
  ///
  /// **覆盖整个被替换区间的 mark 延续到替换文本**(主流编辑器语义:
  /// 全选一段粗体后打字仍是粗体)。没有这条,「插入剧透 → 占位文字被
  /// 整选 → 直接打字」会因 delete+insert 在区间边界不延续样式而把
  /// spoiler mark 丢掉,打出来的是普通文字。用原始 span(含 attr)
  /// 重建而非只记 kind,链接 href/颜色值不丢。
  EditableTextContent replace(int start, int end, String replacement) {
    final carried = (start < end && replacement.isNotEmpty)
        ? [
            for (final m in marks)
              if (m.start <= start && m.end >= end) m,
          ]
        : const <MarkSpan>[];
    var out = delete(start, end).insert(start, replacement);
    for (final m in carried) {
      out = out.applyMark(start, start + replacement.length, m.kind,
          attr: m.attr);
    }
    return out;
  }

  /// 在 [offset] 处切成两半(回车分段)。
  (EditableTextContent before, EditableTextContent after) split(int offset) {
    assert(offset >= 0 && offset <= text.length);
    final before = delete(offset, text.length);
    final after = delete(0, offset);
    return (before, after);
  }

  /// 与 [other] 拼接(段首退格合并)。
  EditableTextContent concat(EditableTextContent other) {
    final base = text.length;
    return EditableTextContent(
      text: text + other.text,
      marks: [
        ...marks,
        for (final m in other.marks)
          m.copyWith(start: m.start + base, end: m.end + base),
      ],
      atoms: {
        ...atoms,
        for (final e in other.atoms.entries) e.key + base: e.value,
      },
    );
  }

  // -----------------------------------------------------------------
  // mark 区间代数(格式命令用)
  // -----------------------------------------------------------------

  /// `[start, end)` 是否被 [kind] 完全覆盖(toggle 语义判定)。
  ///
  /// 覆盖判定容许多个同 kind 区间**无缝拼接**;区间之间有任何未覆盖
  /// 字符即 false。原子字符也计入(选中含 emoji 的一段"全是粗体"时,
  /// emoji 位置上的 mark 虽不影响渲染,但参与覆盖判定 —— 保证 toggle
  /// 幂等:两次 toggle 回到原状)。
  bool isRangeFullyMarked(int start, int end, MarkKind kind) {
    assert(start >= 0 && end <= text.length && start <= end);
    if (start == end) return false;
    var cursor = start;
    // marks 按 start 升序;同 kind 区间不重叠
    for (final m in marks) {
      if (m.kind != kind) continue;
      if (m.end <= cursor) continue;
      if (m.start > cursor) return false; // 缝隙
      cursor = m.end;
      if (cursor >= end) return true;
    }
    return cursor >= end;
  }

  /// 对 `[start, end)` 应用 [kind](幂等;与既有区间合并归一)。
  ///
  /// [attr]:link 的 href。合并只发生在**同 kind 同 attr** 之间 ——
  /// 相邻两个不同 href 的链接不吞并。施加带 attr 的 mark 前先移除
  /// 区间上同 kind 异 attr 的旧区间(改链接 = 覆盖旧链接)。
  EditableTextContent applyMark(int start, int end, MarkKind kind,
      {String? attr}) {
    assert(start >= 0 && end <= text.length && start <= end);
    if (start == end) return this;
    // 先清区间上同 kind 异 attr 的部分(removeMark 全清后重加同 attr 的)
    var base = this;
    if (kind == MarkKind.link) {
      base = base.removeMark(start, end, kind);
    }
    final same = <MarkSpan>[];
    final others = <MarkSpan>[];
    for (final m in base.marks) {
      (m.kind == kind && m.attr == attr ? same : others).add(m);
    }
    // 与 [start,end) 相交/相邻的同 kind 同 attr 区间合并成一条
    var ns = start;
    var ne = end;
    final keep = <MarkSpan>[];
    for (final m in same) {
      if (m.end < ns || m.start > ne) {
        keep.add(m);
      } else {
        if (m.start < ns) ns = m.start;
        if (m.end > ne) ne = m.end;
      }
    }
    return EditableTextContent(
      text: text,
      marks: [
        ...others,
        ...keep,
        MarkSpan(start: ns, end: ne, kind: kind, attr: attr),
      ],
      atoms: atoms,
    );
  }

  /// 从 `[start, end)` 移除 [kind](区间切分)。
  EditableTextContent removeMark(int start, int end, MarkKind kind) {
    assert(start >= 0 && end <= text.length && start <= end);
    if (start == end) return this;
    final newMarks = <MarkSpan>[];
    for (final m in marks) {
      if (m.kind != kind || m.end <= start || m.start >= end) {
        newMarks.add(m);
        continue;
      }
      // 相交:留两侧残段
      if (m.start < start) {
        newMarks.add(m.copyWith(end: start));
      }
      if (m.end > end) {
        newMarks.add(m.copyWith(start: end));
      }
    }
    return EditableTextContent(text: text, marks: newMarks, atoms: atoms);
  }

  /// toggle:全覆盖 → 移除;否则 → 补齐(主流编辑器语义)。
  EditableTextContent toggleMarkInRange(int start, int end, MarkKind kind) =>
      isRangeFullyMarked(start, end, kind)
          ? removeMark(start, end, kind)
          : applyMark(start, end, kind);

  /// 对 `[start, end)` 精确设置 marks 集合(pending style 应用:
  /// 先清区间上全部 kind,再施加 [kinds])。
  ///
  /// **link 不参与**:pending 机制不带 attr,applyMark(link) 会产
  /// href=null 的坏链接;链接中间打字的延续由 [insert] 的区间拉伸
  /// 天然保证,边界打字不延续(主流编辑器语义)。
  EditableTextContent applyExactMarks(int start, int end, Set<MarkKind> kinds) {
    var c = this;
    for (final kind in MarkKind.values) {
      if (kind == MarkKind.link) continue;
      c = kinds.contains(kind)
          ? c.applyMark(start, end, kind)
          : c.removeMark(start, end, kind);
    }
    return c;
  }

  /// [offset] 光标处的"当前样式集"(pending 初值/工具栏高亮):
  /// 取光标**前一个字符**上的 marks(行首取后一个);原子字符视为无样式。
  /// link 不计入(不参与 pending,见 [applyExactMarks])。
  Set<MarkKind> marksAt(int offset) {
    assert(offset >= 0 && offset <= text.length);
    if (text.isEmpty) return const {};
    final probe = offset > 0 ? offset - 1 : 0;
    if (isAtomAt(probe)) return const {};
    return {
      for (final m in marks)
        if (m.kind != MarkKind.link && m.start <= probe && probe < m.end)
          m.kind,
    };
  }

  /// [offset] 光标处覆盖的 link mark 完整区间(链接工具条定位/原位
  /// 编辑用)。返回 (start, end, href);无 → null。
  /// 探测口径与 [linkHrefAt] 一致:光标"贴着链接尾"也算在内(probe =
  /// offset-1,与官方 getMarkRange 的 inclusive 语义对齐)。
  (int, int, String?)? linkRangeAt(int offset) {
    assert(offset >= 0 && offset <= text.length);
    if (text.isEmpty) return null;
    final probe = offset > 0 ? offset - 1 : 0;
    for (final m in marks) {
      if (m.kind == MarkKind.link && m.start <= probe && probe < m.end) {
        return (m.start, m.end, m.attr);
      }
    }
    return null;
  }

  /// [offset] 光标处覆盖的 link href(工具栏"编辑链接"预填用);无 → null。
  String? linkHrefAt(int offset) {
    assert(offset >= 0 && offset <= text.length);
    if (text.isEmpty) return null;
    final probe = offset > 0 ? offset - 1 : 0;
    for (final m in marks) {
      if (m.kind == MarkKind.link && m.start <= probe && probe < m.end) {
        return m.attr;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditableTextContent &&
          runtimeType == other.runtimeType &&
          text == other.text &&
          listEquals(marks, other.marks) &&
          mapEquals(atoms, other.atoms);

  @override
  int get hashCode => Object.hash(
        text,
        Object.hashAll(marks),
        Object.hashAll(atoms.entries.map((e) => Object.hash(e.key, e.value))),
      );

  @override
  String toString() => 'EditableTextContent(${text.length} chars, '
      '${marks.length} marks, ${atoms.length} atoms)';
}
