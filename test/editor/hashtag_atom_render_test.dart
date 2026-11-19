/// 编辑器里 hashtag 原子的**渲染**回归:它是行内一颗小药丸,不能把
/// 整个编辑区糊成一块底色(真机症状:选了个标签,正文变成一大块灰)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/widget/editable_paragraph.dart';
import 'package:fluxdo_render/src/node/node.dart';

void main() {
  testWidgets('药丸原子不撑爆编辑段', (tester) async {
    final content = EditableTextContent.fromInlines(const [
      TextRun('看看 '),
      LinkRun(
        href: '/c/dev/4',
        hashtagRef: 'dev',
        hashtagIcon: 'folder',
        children: [TextRun('#开发调优')],
      ),
      TextRun(' 板块'),
    ]);
    final state = EditorState(blocks: [TextBlock(id: 'e_0', content: content)]);
    addTearDown(state.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          child: FluxdoEditor(
            state: state,
            baseTextStyle: const TextStyle(fontSize: 16, height: 1.6),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    final para = tester.getSize(find.byType(EditableParagraph).first);
    expect(para.height, lessThan(80), reason: '一行文字的段落不该几百像素高');
  });
}
