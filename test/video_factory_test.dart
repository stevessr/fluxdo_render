// buildVideo/buildAudio:注入 builder 时用 builder,否则占位卡。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  testWidgets('注入 videoBuilder → 用主项目 widget', (tester) async {
    const node = VideoNode(id: 'b_0', src: '/v.mp4', poster: '/p.png');
    final factory = NodeFactory(
      videoBuilder: (ctx, n) => const Text('CUSTOM_VIDEO'),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (c) => factory.build(c, node))),
    ));
    expect(find.text('CUSTOM_VIDEO'), findsOneWidget);
  });

  testWidgets('未注入 audioBuilder → 占位卡显示文件名 + 可点', (tester) async {
    var tapped = '';
    const node = AudioNode(id: 'b_0', src: '/x.mp3', title: '/x.mp3');
    final factory = NodeFactory(linkHandler: (ctx, href) => tapped = href);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (c) => factory.build(c, node))),
    ));
    expect(find.text('/x.mp3'), findsOneWidget);
    await tester.tap(find.byType(InkWell));
    expect(tapped, '/x.mp3');
  });
}
