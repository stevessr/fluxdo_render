/// 阅读端 hashtag 药丸的整链路回归(cooked → 解析 → flatten → 渲染)。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

const _cooked =
    '<p>看看 <a class="hashtag-cooked" href="/c/dev/4" data-type="category" '
    'data-slug="dev" data-ref="dev"><svg class="fa d-icon d-icon-folder svg-icon">'
    '<use href="#folder"></use></svg><span>开发调优</span></a> 板块</p>';

void main() {
  testWidgets('选区开启时也不会把整段涂成一大块', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 400,
          child: FluxdoRender(cookedHtml: _cooked),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final pill = find.byType(Container).evaluate().isEmpty
        ? null
        : tester.getSize(find.byType(Container).first);
    if (pill != null) {
      expect(pill.height, lessThan(60));
      expect(pill.width, lessThan(240));
    }
  });
}
