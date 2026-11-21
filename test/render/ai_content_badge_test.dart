import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('标识只出现于对应的块，折叠与展开保持同一个标识', (tester) async {
    const badge = '<span class="ai-badge" data-ai-label="AI"></span>';
    final nodes = ParagraphParser().parse('''
<pre data-code-ai="true">$badge<code>marked</code></pre>
<pre><code>unmarked</code></pre>
<blockquote data-ai-generated="true">$badge<p>marked</p></blockquote>
<aside class="quote"><blockquote data-ai-generated="true">$badge<p>quoted</p></blockquote></aside>
<details class="ai-quote"><summary><span>Summary</span><span class="ai-details-label">AI</span></summary><p>hidden</p></details>
''');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: Builder(
        builder: (context) => Column(children: [
          for (final node in nodes) NodeFactory().build(context, node),
        ]),
      ))),
    ));
    expect(find.text('AI'), findsNWidgets(4));
    await tester.tap(find.text('Summary'));
    await tester.pumpAndSettle();
    expect(find.text('AI'), findsNWidgets(4));
  });

  test('新版图片预览元数据仍可还原缩放与序号', () {
    final paragraph = ParagraphParser().parse(
      '<p><img src="image.png" width="320" height="240" data-image-index="0" data-scale="50"></p>',
    ).single as ParagraphNode;
    final image = paragraph.inlines.single as ImageRun;
    expect(image.previewImageIndex, 0);
    expect(image.scale, 50);
    expect(image.origWidth, 640);
  });
}
