/// 自动链接的显示与裸链接判定共用规则。
///
/// 对齐 Markdown 链接的显示解码：只解码 Unicode 和反斜杠，不解码
/// 空格、斜杠、问号等保留字符，否则重新解析时会改变地址或截断链接。
String displayLinkText(String href) =>
    href.replaceAllMapped(RegExp(r'(?:%[0-9a-fA-F]{2})+'), (match) {
      final encoded = match[0]!;
      try {
        final decoded = Uri.decodeComponent(encoded);
        return decoded.runes.every(
              (rune) =>
                  rune == 0x5c ||
                  rune > 0x9f &&
                      rune != 0xfffc &&
                      !_unsafeDisplayCharacters.hasMatch(
                        String.fromCharCode(rune),
                      ),
            )
            ? decoded
            : encoded;
      } on FormatException {
        return encoded;
      }
    });

// 不可见分隔符和方向控制字符不参与 URL 的可读化。
final _unsafeDisplayCharacters = RegExp(
  r'[\s\u00a0\u00ad\u061c\u1680\u180e\u2000-\u200f\u2028-\u202f\u205f\u2060-\u206f\u3000\ufeff]',
  unicode: true,
);

/// 更新裸链接目标时保留已有的百分号编码，不把反斜杠交给 Uri.parse
///（后者会将它规范化成路径分隔符）。
String encodeLinkTarget(String text) {
  final encoded = StringBuffer();
  var start = 0;
  for (final match in RegExp(r'%[0-9a-fA-F]{2}').allMatches(text)) {
    encoded.write(Uri.encodeFull(text.substring(start, match.start)));
    encoded.write(match[0]);
    start = match.end;
  }
  encoded.write(Uri.encodeFull(text.substring(start)));
  return encoded.toString();
}

/// 显示文本对应裸 URL，而不是用户自定义的链接标题。
bool isBareLinkText(String text, String href, {bool allowDecoded = false}) {
  if (text == href || allowDecoded && text == displayLinkText(href)) {
    return true;
  }
  for (final scheme in const ['http://', 'mailto:']) {
    if (href.startsWith(scheme)) {
      final withoutScheme = href.substring(scheme.length);
      if (text == withoutScheme ||
          allowDecoded && text == displayLinkText(withoutScheme)) {
        return true;
      }
    }
  }
  return false;
}
