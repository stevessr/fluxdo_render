/// D1 守护:行内代码圆角灰底自绘。
/// - 含 `<code>` 的段落在文字下层挂 InlineCodeBackgroundPainter(圆角灰底);
/// - 代码**块** `<pre><code>`(整块自带背景)不挂该 painter(避免双重背景)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/render/inline_code_painter.dart';
import 'package:fluxdo_render/src/widget/fluxdo_render.dart';

void main() {
  Finder codeBgPainter() => find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is InlineCodeBackgroundPainter,
      );

  testWidgets('行内 <code> 段落挂 InlineCodeBackgroundPainter(圆角灰底)',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FluxdoRender(
            cookedHtml: '<p>前 <code>inline code</code> 后</p>',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(codeBgPainter(), findsWidgets,
        reason: '含行内 code 的段落应挂背景 painter');
  });

  testWidgets('代码块 <pre><code> 不挂行内代码背景 painter(整块自带背景)',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FluxdoRender(
            cookedHtml:
                '<pre><code class="lang-dart">void main() {}</code></pre>',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(codeBgPainter(), findsNothing,
        reason: '代码块 codeLanguage != null → 不挂行内代码背景 painter');
  });
}
