import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

  testWidgets('无 svgBuilder → fallback 占位框(不崩,不引 jovial_svg)',
      (tester) async {
    final factory = NodeFactory();
    const node = SvgNode(
      id: 'b_0',
      svgSource: '<svg viewBox="0 0 10 10"><rect/></svg>',
    );
    await pump(tester, Builder(builder: (c) => factory.buildSvg(c, node)));
    expect(find.text('SVG'), findsOneWidget);
  });

  testWidgets('有 svgBuilder → 用主项目 widget', (tester) async {
    final factory = NodeFactory(
      svgBuilder: (ctx, node) => const Text('CUSTOM_SVG'),
    );
    const node = SvgNode(id: 'b_0', svgSource: '<svg viewBox="0 0 1 1"/>');
    await pump(tester, Builder(builder: (c) => factory.buildSvg(c, node)));
    expect(find.text('CUSTOM_SVG'), findsOneWidget);
  });

  testWidgets('空源串 → SizedBox.shrink(不画占位)', (tester) async {
    final factory = NodeFactory();
    const node = SvgNode(id: 'b_0', svgSource: '   ');
    await pump(tester, Builder(builder: (c) => factory.buildSvg(c, node)));
    expect(find.text('SVG'), findsNothing);
  });
}
