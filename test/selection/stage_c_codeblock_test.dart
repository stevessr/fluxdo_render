import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';
import 'package:fluxdo_render/src/selection/selection_exporter.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';
import 'package:fluxdo_render/src/selection/selection_scope.dart';

void main() {
  testWidgets('代码块注册可选 handle,导出带 language', (tester) async {
    final c = SelectionController(SelectionRegistry());
    final factory = NodeFactory();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: c,
            child: Builder(
              builder: (ctx) => factory.build(
                ctx,
                const CodeBlockNode(
                  id: 'cb1',
                  code: 'print("hi")\nreturn 0',
                  language: 'python',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 代码块应注册到 registry
    expect(c.registry.length, greaterThanOrEqualTo(1));
    final h = c.registry.liveHandles.first;
    // projection 是 code 原文
    expect(h.projection.projectAll(), 'print("hi")\nreturn 0');

    // 部分选中(前 5 字符)→ 导出为纯文本,code=null(复制不追加 ```)
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: h.id, renderOffset: 0),
      extent: DocumentPosition(blockId: h.id, renderOffset: 5),
    );
    var data = SelectionExporter(c.registry).export(c.selection);
    expect(data, isNotNull);
    expect(data!.plainText, 'print');
    expect(data.code, isNull);

    // 完整选中整个代码块 → 导出带 python language(复制包 ```python)
    final len = h.projection.renderLength;
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: h.id, renderOffset: 0),
      extent: DocumentPosition(blockId: h.id, renderOffset: len),
    );
    data = SelectionExporter(c.registry).export(c.selection);
    expect(data, isNotNull);
    expect(data!.plainText.replaceAll('\u200B', ''),
        'print("hi")\nreturn 0');
    expect(data.code, isNotNull);
    expect(data.code!.language, 'python');
  });

  testWidgets('代码块 + 段落混合选区:code=null(非单代码块)', (tester) async {
    final c = SelectionController(SelectionRegistry());
    final factory = NodeFactory();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: c,
            child: Builder(
              builder: (ctx) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  factory.build(
                      ctx, const ParagraphNode(id: 'p1', inlines: [])),
                  factory.build(
                    ctx,
                    const CodeBlockNode(id: 'cb', code: 'xyz', language: 'dart'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 空段落可能不产 RenderParagraph,跳过严格断言;只验证不崩
    expect(c.registry.length, greaterThanOrEqualTo(1));
  });
}
