// 阅读节点与独立编辑器共用的行内 Markdown 序列化，不依赖整篇文档模型。
import 'dart:ui' show Color;
import '../../node/node.dart';

/// 图片 → `![alt|WxH](src)` / 带缩放 `![alt|WxH, 75%](src)`。upload 图优先
/// 写 origSrc 短链(raw 规范形态);lightbox 缩略图写原图短链/URL 而非
/// `_2_690x52` 优化版。
///
/// 预览形态(scale 非 null)的 width/height 是 cook 乘过缩放的显示尺寸,
/// 写回必须用 origWidth/origHeight(parser ceil 反推)+ `, N%` 后缀 ——
/// 写乘过的尺寸会让缩放语义在往返中塌陷(再 cook 二次相乘)。
/// scale=100(预览态无后缀图的规范档)不写后缀。
String serializeImageRun(ImageRun img) {
  final src =
      img.origSrc ??
      (img.src.startsWith('upload://')
          ? img.src
          : (img.lightboxUrl ?? img.src));
  // origWidth/origHeight 一旦有值就是 raw 声明尺寸(parser 反推或宿主缩放
  // 时固化),优先于(可能乘过 scale 的)显示尺寸。
  final w = img.origWidth ?? img.width;
  final h = img.origHeight ?? img.height;
  final scale = img.scale;
  var size = (w != null && h != null) ? '|${w.round()}x${h.round()}' : '';
  if (scale != null && scale > 0 && scale != 100 && size.isNotEmpty) {
    size = '$size, ${scale.round()}%';
  }
  return '![${img.alt}$size]($src)';
}

/// 岛化段落的 inline 序列化(可能含 LinkRun/ImageRun 等白名单外节点 ——
/// 岛就是因它们而生)。每个类型写回 raw 规范语法(cook 探针实测)。
String serializeIslandInlines(List<InlineNode> inlines) {
  final buf = StringBuffer();
  for (final n in inlines) {
    switch (n) {
      case TextRun(:final text):
        buf.write(text);
      case LineBreakRun(:final soft):
        buf.write(soft ? '\n' : '  \n');
      case EmRun(:final children):
        buf.write(
          n.editorSyntax == 'i'
              ? '[i]${serializeIslandInlines(children)}[/i]'
              : '*${serializeIslandInlines(children)}*',
        );
      case StrongRun(:final children):
        buf.write(
          n.editorSyntax == 'b'
              ? '[b]${serializeIslandInlines(children)}[/b]'
              : '**${serializeIslandInlines(children)}**',
        );
      case InlineCodeRun(:final text):
        buf.write('`$text`');
      case LinkRun(
        :final href,
        :final children,
        :final isAttachment,
        :final filename,
        :final origHref,
        :final hashtagRef,
        :final isOneboxLink,
        :final editorLinkTitle,
        :final editorAngleLink,
      ):
        final target = origHref ?? href;
        final title = editorLinkTitle == null
            ? ''
            : ' "${editorLinkTitle.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
        if (hashtagRef != null) {
          // hashtag 写回 `#{ref}`(写 URL 会退化成死链接)
          buf.write('#$hashtagRef');
        } else if (isAttachment) {
          // `[name.pdf|attachment](upload://…)`;origHref 是预览形态的
          // 短链,baked 形态 href 本身可能就是 /uploads 路径 —— 保持原样
          final name = filename.isNotEmpty
              ? serializeIslandInlines([TextRun(filename)])
              : serializeIslandInlines(children);
          buf.write('[$name|attachment]($target$title)');
        } else if (editorAngleLink) {
          buf.write(
            '<${target.startsWith('mailto:') ? target.substring(7) : target}>',
          );
        } else if (isOneboxLink) {
          // onebox 系:raw 是裸 URL(行内标题动态取,不能固化)
          buf.write(href);
        } else {
          buf.write('[${serializeIslandInlines(children)}]($target$title)');
        }
      case ImageRun():
        buf.write(serializeImageRun(n));
      case EmojiRun(:final name):
        buf.write(name.isEmpty ? '' : ':$name:');
      case MentionRun(:final username):
        buf.write('@$username');
      case SpoilerRun(:final children):
        buf.write('[spoiler]${serializeIslandInlines(children)}[/spoiler]');
      case MathInlineRun(:final latex):
        buf.write('\$$latex\$');
      case FootnoteRefRun(:final number, :final markdownLabel):
        // 引用标签与定义一致，显示编号不受用户命名影响。
        buf.write('[^${markdownLabel ?? number}]');
      case LocalDateRun():
        buf.write(serializeLocalDate(n));
      case ColoredRun():
        // [color]/[bgcolor]:服务端装了 discourse-bbcode-color 插件(认这
        // 个语法),客户端预览 bundle 没打包它(cook 原样输出字面文本)。
        // 门禁两侧都用客户端 bundle → attr 原样写回即可两侧一致。
        buf.write(_serializeColored(n));
      case SizedRun():
        buf.write(serializeSized(n));
      case StyledRun(:final kind, :final children):
        final inner = serializeIslandInlines(children);
        buf.write(switch (kind) {
          InlineStyleKind.underline =>
            n.editorSyntax == 'u' ? '<u>$inner</u>' : '[u]$inner[/u]',
          InlineStyleKind.lineThrough =>
            n.editorSyntax == 's' ? '[s]$inner[/s]' : '~~$inner~~',
          InlineStyleKind.superscript => '<sup>$inner</sup>',
          InlineStyleKind.subscript => '<sub>$inner</sub>',
          InlineStyleKind.small => '<small>$inner</small>',
          InlineStyleKind.big => '<big>$inner</big>',
          InlineStyleKind.mark => '<mark>$inner</mark>',
          InlineStyleKind.monospace => '<kbd>$inner</kbd>',
        });
      case ClickCountRun():
        break; // 服务端注入的展示节点,raw 里不存在
    }
  }
  return buf.toString();
}

/// `[date=… time=… timezone="…"]` BBCode 重建(cook 探针实测属性名)。
String serializeLocalDate(LocalDateRun n) {
  final buf = StringBuffer(
    n.endDate == null
        ? '[date=${n.date}'
        : '[date-range from=${n.date}${n.time == null ? '' : 'T${n.time}'} to=${n.endDate}${n.endTime == null ? '' : 'T${n.endTime}'}',
  );
  if (n.endDate == null && n.time != null) buf.write(' time=${n.time}');
  if (n.recurring != null) buf.write(' recurring="${n.recurring}"');
  if (n.timezone != null) buf.write(' timezone="${n.timezone}"');
  if (n.format != null) buf.write(' format="${n.format}"');
  if (n.timezones.isNotEmpty) {
    buf.write(' timezones="${n.timezones.join('|')}"');
  }
  if (n.displayedTimezone != null) {
    buf.write(' displayedTimezone="${n.displayedTimezone}"');
  }
  if (n.countdownRaw != null) {
    buf.write(' countdown="${n.countdownRaw}"');
  } else if (n.countdown) {
    buf.write(' countdown="true"');
  }
  buf.write(']');
  return buf.toString();
}

/// 着色重建 → **BBCode**(`[color=…]` / `[bgcolor=…]`)。
///
/// 事实链(cook bundle 探针 + 站内官方教程帖):
/// - **服务端**装了 discourse-bbcode-color 插件,`[color=X]` 被认并把 X
///   **原样**放进 `style="color:X"`(`red`/`#F00` 逐字透传);
/// - **客户端预览 bundle** 没打包该插件,cook 把 `[color=X]` 当字面文本;
/// - 往返门禁 = cook(原 raw) vs cook(docToRaw(导入)),两侧都是客户端
///   bundle → 两侧都把 [color] 当字面文本,**attr 原样写回即字节一致**。
///   任何规范化(小写化 / `#F00`→`#ff0000` / `red`→hex)都会失配,
///   整帖降级源码模式。
///
/// 所以优先写 colorRaw/backgroundRaw(cooked 里的 CSS 原文 = 用户在
/// [color=X] 里写的 X);程序化构造(raw 为 null)才按 Color 值写 hex。
String _serializeColored(ColoredRun n) {
  String hex(Color c) {
    final v = c.toARGB32() & 0xFFFFFF;
    return '#${v.toRadixString(16).padLeft(6, '0')}';
  }

  var out = serializeIslandInlines(n.children);
  // 前景包在里层、背景在外层(与解析侧的嵌套顺序一致)
  if (n.color != null || n.colorRaw != null) {
    final v = n.colorRaw ?? hex(n.color!);
    out = '[color=$v]$out[/color]';
  }
  if (n.background != null || n.backgroundRaw != null) {
    final v = n.backgroundRaw ?? hex(n.background!);
    out = '[bgcolor=$v]$out[/bgcolor]';
  }
  return out;
}

/// 字号 → `[size=N]`。
///
/// 与 [_serializeColored] 同一条理由:N 的原文(pctRaw)原样写回才能过
/// 往返门禁;程序化构造(pctRaw=null)才按 scale 计算(整数化防浮点
/// 脏值,见下)。
String serializeSized(SizedRun n) {
  if (n.pctRaw != null) {
    return '[size=${n.pctRaw}]${serializeIslandInlines(n.children)}[/size]';
  }
  // scale 由 `font-size:N%` / 100 而来,乘回 100 会带浮点脏值
  // (`0.07 * 100 == 7.000000000000001`)—— 与最近整数差在浮点误差
  // 量级(1e-6)内的按整数写,防止 raw 里出现 `[size=7.000000000000001]`。
  final pct = n.scale * 100;
  final rounded = pct.round();
  final v = (pct - rounded).abs() < 1e-6 ? rounded.toString() : '$pct';
  return '[size=$v]${serializeIslandInlines(n.children)}[/size]';
}
