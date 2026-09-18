/// 从 InlineNode 树构建 [RenderTextProjection](渲染偏移 ↔ 逻辑投影映射表)。
///
/// **与 InlineFlattener 共享同一份 `inlines` 输入**,但只关心"渲染偏移 +
/// 投影文本",不碰 builder/handler/recognizer。两者必须在**渲染偏移模型**上
/// 保持一致(已探针实测 Flutter 3.44):
/// - TextSpan 贡献其文本长度;
/// - WidgetSpan(emoji/mention/image/spoiler/footnote/localDate/clickCount/math)
///   各贡献 **1** 个 ￼(U+FFFC);
/// - Em/Strong/Link 是 TextSpan children,偏移连续递归。
///
/// 投影规则(对齐主项目 HtmlTextMapper._collectTextNodes 的口径):
/// - TextRun/InlineCodeRun → 原文
/// - LineBreakRun → `\n`
/// - EmojiRun → `:name:`(空名 → `''`)
/// - MentionRun → `@username`
/// - ImageRun → alt(空 → `''`)
/// - SpoilerRun → 子节点投影全文(渲染层占 1 ￼,但投影成真实文本,对齐 cooked)
/// - FootnoteRefRun → number(对齐 cooked `<sup>N`)
/// - LocalDateRun → fallbackText(服务端预渲染文本)
/// - MathInlineRun → latex(= cooked 里 span.math 的 textContent)
/// - ClickCountRun → `''`(注入的,cooked 没有,必须排除)
library;

import '../node/inline_node.dart';
import '../flatten/soft_break.dart';
import 'projection.dart';

/// 把 inline 节点列表构建成映射表。根 span 的渲染偏移从 0 开始。
RenderTextProjection buildInlineProjection(List<InlineNode> inlines) {
  final entries = <ProjectionEntry>[];
  var cursor = 0;

  void addText(String text, ProjectionKind kind) {
    if (text.isEmpty) return;
    entries.add(
      ProjectionEntry(
        renderStart: cursor,
        renderLen: text.length,
        logicalText: text,
        kind: kind,
      ),
    );
    cursor += text.length;
  }

  // 占位符:渲染层占 1 个 ￼,逻辑投影为 [logical](可空)。
  void addPlaceholder(String logical, ProjectionKind kind, {String? copyText}) {
    entries.add(
      ProjectionEntry(
        renderStart: cursor,
        renderLen: 1,
        logicalText: logical,
        copyText: copyText,
        kind: kind,
      ),
    );
    cursor += 1;
  }

  // 把一组子节点投影拼成单串(给 spoiler 原子投影用)。
  String concatLogical(List<InlineNode> nodes) =>
      buildInlineProjection(nodes).projectAll();

  void walk(List<InlineNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        // 必须排在 TextRun 之前(子类,switch 按序匹配):渲染占
        // text.length 个字符、逻辑投影空串(零内容宽,同 codePad ——
        // 复制/编辑坐标不带出,光标进不了定界符内部)。
        case EditingDelimiterRun(:final text):
          entries.add(
            ProjectionEntry(
              renderStart: cursor,
              renderLen: text.length,
              logicalText: '',
              kind: ProjectionKind.editingDelimiter,
            ),
          );
          cursor += text.length;
        case TextRun(:final text):
          addText(insertSoftBreaks(text), ProjectionKind.text);
        case LineBreakRun():
          addText('\n', ProjectionKind.lineBreak);
        case InlineCodeRun(:final text):
          // 与 flattener _buildInlineCodeSpan 同构:NBSP + code + NBSP。
          // NBSP 是注入的粘性内边距,渲染占 1 字符但不属于内容 →
          // 空投影(同 clickCount,复制/引用不带出)。
          addPlaceholder('', ProjectionKind.codePad);
          addText(insertSoftBreaks(text), ProjectionKind.inlineCode);
          addPlaceholder('', ProjectionKind.codePad);
        case EmRun(:final children):
          walk(children);
        case StrongRun(:final children):
          walk(children);
        case StyledRun(:final kind, :final children):
          // TextSpan 渲染类(下划/删除/small/big/mark/monospace)偏移连续 → 递归;
          // WidgetSpan 渲染类(上/下标)渲染层占 1 ￼ → 原子投影(子文本)。
          // kind 必须是 styledAtom 而非 text:text 契约是「renderLen ==
          // logicalText 渲染长,可按字符切」,1 ￼ 配 n 字符投影破坏契约,
          // 编辑坐标换算按字符走位溢出到邻接条目(光标错位)、复制部分
          // 选区截半丢字。
          switch (kind) {
            case InlineStyleKind.superscript:
            case InlineStyleKind.subscript:
              addPlaceholder(
                concatLogical(children),
                ProjectionKind.styledAtom,
              );
            default:
              walk(children);
          }
        case LinkRun(:final children, :final hashtagRef, :final isAttachment):
          // hashtag 渲染成 1 个 WidgetSpan 药丸 → 原子投影(投影文本用
          // `#ref`,与 cooked 里的锚文本一致,引用/复制能匹配上)。
          if (hashtagRef != null) {
            final label = concatLogical(children).trim();
            addPlaceholder(
              label.startsWith('#') ? label : '#$label',
              ProjectionKind.hashtag,
            );
          } else {
            // 附件链接:flattener 在文件名前注入 1 个下载图标 WidgetSpan
            // (占 1 ￼),是渲染注入物、cooked 里没有 → 空投影占位
            // (同 clickCount)。漏登记会让图标之后的全部渲染偏移错一位。
            if (isAttachment) {
              addPlaceholder('', ProjectionKind.attachmentIcon);
            }
            walk(children);
          }
        case ColoredRun(:final children):
          // 纯 TextSpan 着色,偏移连续 → 递归(同 Em/Strong)。
          walk(children);
        case SizedRun(:final children):
          // 纯 TextSpan 字号缩放,偏移连续 → 递归(同 ColoredRun)。
          walk(children);
        case EmojiRun(:final name):
          addPlaceholder(name.isEmpty ? '' : ':$name:', ProjectionKind.emoji);
        case MentionRun(:final username, :final statusEmoji):
          if (statusEmoji == null) {
            // 与 flattener _buildMentionTextSpan 同构:NBSP + @user + NBSP
            // (行内代码三件套同款;药丸底色由 painter 按 mentionText
            // 区间自绘)。带状态 emoji 的仍走 WidgetSpan 原子路径。
            addPlaceholder('', ProjectionKind.mentionPad);
            addText('@$username', ProjectionKind.mentionText);
            addPlaceholder('', ProjectionKind.mentionPad);
          } else {
            addPlaceholder('@$username', ProjectionKind.mention);
          }
        case ImageRun(:final alt, :final src):
          addPlaceholder(
            alt,
            ProjectionKind.image,
            copyText: alt.isEmpty ? src : null,
          );
        case SpoilerRun(:final children):
          // 渲染层是 1 个 WidgetSpan(￼),投影成子文本全文(对齐 cooked)。
          addPlaceholder(concatLogical(children), ProjectionKind.spoiler);
        case FootnoteRefRun(:final number):
          addPlaceholder(number, ProjectionKind.footnote);
        case LocalDateRun(:final fallbackText):
          addPlaceholder(fallbackText, ProjectionKind.localDate);
        case ClickCountRun():
          // 注入的,原始 cooked 没有 → 排除(空投影)。
          addPlaceholder('', ProjectionKind.clickCount);
        case MathInlineRun(:final latex):
          // 投影 = latex(= cooked 里 span.math 的 textContent,parser 用
          // el.text.trim() 取的)。这样选区含行内公式时,投影文本能在原始
          // cooked 里被 HtmlTextMapper 匹配上(空投影会断裂导致引用降级)。
          addPlaceholder(latex, ProjectionKind.mathInline);
      }
    }
  }

  walk(inlines);
  return RenderTextProjection(entries);
}
