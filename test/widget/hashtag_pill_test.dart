/// hashtag 药丸的**尺寸**回归:它是行内的一颗小胶囊,不许把整段撑成
/// 一大块底色(真机症状:选了个标签,整篇正文变成一个灰方块)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/flatten/inline_flattener.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

void main() {
  testWidgets('药丸尺寸随文字走,不撑满整行', (tester) async {
    const flattener = InlineFlattener();
    final result = flattener.flatten(
      const [
        TextRun('看看 '),
        LinkRun(
          href: '/c/dev/4',
          hashtagRef: 'dev',
          hashtagIcon: 'folder',
          children: [TextRun('#开发调优')],
        ),
        TextRun(' 板块'),
      ],
      const TextStyle(fontSize: 14),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 600, child: Text.rich(result.span)),
      ),
    ));

    final pill = find.byType(Container).first;
    final size = tester.getSize(pill);
    expect(size.height, lessThan(40),
        reason: '药丸高度应当就是行高量级');
    expect(size.width, lessThan(200),
        reason: '药丸宽度应当随文字走,不是整行宽');
  });
}
