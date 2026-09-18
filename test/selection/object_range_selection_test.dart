import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo_render/src/render/document_order.dart';
import 'package:fluxdo_render/src/selection/hit_tester.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';
import 'package:fluxdo_render/src/selection/selection_exporter.dart';
import 'package:fluxdo_render/src/selection/selection_gesture_layer.dart';
import 'package:fluxdo_render/src/selection/selection_highlight_painter.dart';
import 'package:fluxdo_render/src/selection/selection_range.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';

const photo = ImageRun(
  src: 'https://example.com/photo.png',
  width: 100,
  height: 160,
);
const objects = <BlockNode>[
  ImageGridNode(id: 'grid', images: [photo, photo]),
  ImageGridNode(
    id: 'carousel',
    images: [photo, photo],
    mode: ImageGridMode.carousel,
  ),
  VideoNode(id: 'video', src: 'video.mp4'),
  AudioNode(id: 'audio', src: 'audio.mp3'),
  HorizontalRuleNode(id: 'rule'),
  MathBlockNode(id: 'math', latex: 'x^2'),
  OneboxNode(
    id: 'card',
    kind: OneboxKind.defaultKind,
    url: 'https://example.com',
    title: 'link card',
  ),
  LazyVideoNode(
    id: 'lazy',
    provider: LazyVideoProvider.youtube,
    videoId: 'x',
    url: 'https://example.com/video',
  ),
  IframeNode(id: 'iframe', src: 'https://example.com/embed'),
  SvgNode(id: 'svg', svgSource: '<svg viewBox="0 0 10 10"></svg>'),
  PollNode(id: 'poll', pollName: 'poll', title: 'choose one'),
  CodeBlockNode(id: 'diagram', language: 'mermaid', code: 'graph TD; A-->B'),
  ChatTranscriptNode(
    id: 'chat',
    username: 'user',
    messagesHtml: '<p>message</p>',
  ),
];

NodeFactory factory(List<BlockNode> nodes) => NodeFactory(
  docOrders: assignDocumentOrder(nodes),
  codeBlockBuilder: (_, node) => node.language == "mermaid"
      ? const SizedBox(height: 140, child: ColoredBox(color: Colors.grey))
      : null,
  imageContentBuilder: (_, _, _) => const SizedBox(
    width: 100,
    height: 160,
    child: ColoredBox(color: Colors.grey),
  ),
  imageGridBuilder: (_, _) =>
      const SizedBox(height: 160, child: ColoredBox(color: Colors.grey)),
  videoBuilder: (_, _) =>
      const SizedBox(height: 120, child: ColoredBox(color: Colors.grey)),
  audioBuilder: (_, _) =>
      const SizedBox(height: 64, child: ColoredBox(color: Colors.grey)),
);

Future<SelectionController> mount(
  WidgetTester tester,
  BlockNode object, {
  EditorState? editor,
}) async {
  final c = SelectionController(SelectionRegistry());
  addTearDown(c.dispose);
  final nodes = <BlockNode>[
    const ParagraphNode(id: 'before', inlines: [TextRun('alpha beta gamma')]),
    object,
    const ParagraphNode(id: 'after', inlines: [TextRun('delta epsilon tail')]),
  ];
  final f = factory(nodes);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: editor != null
                  ? FluxdoEditor(
                      state: editor,
                      nodeFactory: f,
                      objectToolbarManaged: true,
                      onCodeBlockEdited: (_, _, _) {},
                      onTableEdited: (_, _) {},
                    )
                  : SelectionScope(
                      controller: c,
                      child: SelectionGestureLayer(
                        controller: c,
                        onSelectionChanged: (_, {fromTouch = false}) {},
                        child: Builder(
                          builder: (context) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final node in nodes) f.build(context, node),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (editor == null) return c;
  return tester
      .widgetList<SelectionScope>(find.byType(SelectionScope))
      .first
      .controller;
}

Offset textPoint(SelectionController c, int index, int offset) {
  final h = c.registry.byId(c.registry.orderedBlocks()[index].id)!;
  final g = h.geometry!;
  final caret = g.caretRectAt(offset);
  return g.renderBox.localToGlobal(Offset(caret.left + 2, caret.center.dy));
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final editing in [false, true]) {
      testWidgets('$platform editing=$editing: 长按选词拖入块，再拖出', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final state = editing
            ? EditorState(
                blocks: [
                  TextBlock(
                    id: 'before',
                    content: EditableTextContent.fromInlines(const [
                      TextRun('alpha beta gamma'),
                    ]),
                  ),
                  IslandBlock(id: 'object', node: objects[2]),
                  TextBlock(
                    id: 'after',
                    content: EditableTextContent.fromInlines(const [
                      TextRun('delta epsilon tail'),
                    ]),
                  ),
                ],
              )
            : null;
        try {
          final c = await mount(tester, objects[2], editor: state);
          final order = c.registry.orderedBlocks();
          final rect = c.registry.byId(order[1].id)!.globalRect()!;
          final touch = await tester.startGesture(textPoint(c, 0, 7));
          await tester.pump(const Duration(milliseconds: 650));
          expect(c.selection?.isCollapsed, isFalse);
          await touch.moveTo(rect.centerRight - const Offset(4, 0));
          await tester.pump();
          expect(c.selection!.extent.blockId, order[1].id);
          expect(c.selection!.extent.renderOffset, 1);
          await touch.moveTo(textPoint(c, 2, 8));
          await tester.pump();
          expect(c.selection!.extent.blockId, order[2].id);
          await touch.up();
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
          state?.dispose();
        }
      });
    }
  }

  for (final rich in [false, true]) {
    for (final object in objects) {
      testWidgets('阅读 rich=$rich ${object.id}: 拖入整选、继续拖出、反向回拖', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        InlineSpanText.debugForceRichText = rich;
        try {
          final c = await mount(tester, object);
          final order = c.registry.orderedBlocks();
          expect(order, hasLength(3));
          final rect = c.registry.byId(order[1].id)!.globalRect()!;
          final start = textPoint(c, 0, 2);
          final drag = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
          );
          await drag.moveTo(start + const Offset(25, 0));
          await tester.pump();
          // Left/top corner used to snap back to preceding text, excluding object.
          await drag.moveTo(rect.topLeft + const Offset(3, 3));
          await tester.pump();
          expect(c.selection!.extent.blockId, order[1].id);
          expect(c.selection!.extent.renderOffset, 1);
          expect(
            expandSelection(c.registry, c.selection!).last.id,
            order[1].id,
          );
          expect(
            SelectionExporter(c.registry).export(c.selection)!.clipboardText,
            isNotEmpty,
          );
          await drag.moveTo(textPoint(c, 2, 8));
          await tester.pump();
          expect(c.selection!.extent.blockId, order[2].id);
          await drag.moveTo(start);
          await tester.pump();
          expect(
            expandSelection(
              c.registry,
              c.selection!,
            ).any((r) => r.id == order[1].id),
            isFalse,
          );
          await drag.up();
          await tester.pump(const Duration(milliseconds: 600));
          final backStart = textPoint(c, 2, 8);
          final back = await tester.startGesture(
            backStart,
            kind: PointerDeviceKind.mouse,
          );
          await back.moveTo(backStart - const Offset(25, 0));
          await tester.pump();
          await back.moveTo(rect.bottomRight - const Offset(3, 3));
          await tester.pump();
          expect(c.selection!.extent.blockId, order[1].id);
          expect(c.selection!.extent.renderOffset, 0);
          await back.up();
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
          InlineSpanText.debugForceRichText = false;
        }
      });
    }
  }

  for (final mode in EditorMode.values) {
    for (final object in [
      objects.first,
      objects[2],
      objects[4],
      const CodeBlockNode(
        id: 'code',
        code: 'line one\nline two',
        language: 'dart',
      ),
      const TableNode(
        id: 'table',
        columnCount: 1,
        rows: [
          [
            TableCellData(
              children: [
                ParagraphNode(id: 'cell', inlines: [TextRun('cell')]),
              ],
            ),
          ],
        ],
      ),
    ]) {
      testWidgets('编辑 $mode ${object.id}: 选区端点可落在块内，跨块替换和撤销完整', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final state = EditorState(
          blocks: [
            TextBlock(
              id: 'before',
              content: EditableTextContent.fromInlines(const [
                TextRun('alpha beta gamma'),
              ]),
            ),
            IslandBlock(id: 'object', node: object),
            TextBlock(
              id: 'after',
              content: EditableTextContent.fromInlines(const [
                TextRun('delta epsilon tail'),
              ]),
            ),
          ],
        );
        state.mode = mode;
        try {
          final c = await mount(tester, object, editor: state);
          expect(c.registry.orderedBlocks(), hasLength(3));
          final id = c.registry.orderedBlocks()[1].id;
          final rect = c.registry.byId(id)!.globalRect()!;
          final start = textPoint(c, 0, 2);
          final drag = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
          );
          await drag.moveTo(start + const Offset(25, 0));
          await tester.pump();
          await drag.moveTo(rect.topLeft + const Offset(3, 3));
          await tester.pump();
          expect(
            state.selection!.extent,
            const EditorPosition(blockId: 'object', offset: 1),
          );
          expect(c.selection!.extent.blockId, id);
          expect(expandSelection(c.registry, c.selection!).last.id, id);
          await drag.up();
          await tester.pump();
          state.insertText('replacement');
          await tester.pump();
          expect(state.blocks.whereType<IslandBlock>(), isEmpty);
          state.undo();
          await tester.pump();
          expect(state.blocks.whereType<IslandBlock>().single.node, object);
          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
          state.dispose();
        }
      });
    }
  }

  for (final rich in [false, true]) {
    testWidgets('行内图片 rich=$rich: 右半边整选、无 alt 可复制、文字背景不被图片撑高', (tester) async {
      InlineSpanText.debugForceRichText = rich;
      try {
        final c = SelectionController(SelectionRegistry());
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SelectionScope(
                controller: c,
                child: SizedBox(
                  width: 360,
                  child: InlineSpanText(
                    documentOrder: 0,
                    baseStyle: const TextStyle(fontSize: 16),
                    inlines: const [
                      TextRun('hello '),
                      photo,
                      TextRun(' world'),
                    ],
                    imageContentBuilder: (_, _, _) =>
                        const SizedBox(width: 100, height: 160),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final h = c.registry.liveHandles.single;
        final g = h.geometry!;
        final imageBox = g
            .getBoxesForSelection(
              const TextSelection(baseOffset: 6, extentOffset: 7),
            )
            .single
            .toRect();
        final right = g.renderBox.localToGlobal(
          imageBox.centerRight - const Offset(2, 0),
        );
        final range = SelectionHitTester(c.registry).atomicRangeAt(right)!;
        expect(range.start.renderOffset, 6);
        expect(range.end.renderOffset, 7);
        c.selection = DocumentSelection(base: range.start, extent: range.end);
        final data = SelectionExporter(c.registry).export(c.selection)!;
        expect(data.plainText, isEmpty);
        expect(data.clipboardText, photo.src);
        expect(
          SelectionExporter(
            c.registry,
          ).endpointAnchors(c.selection)!.endLineHeight,
          lessThanOrEqualTo(32),
        );
        final textRects = selectionHighlightRects(
          g,
          BlockRange(h.id, h.projection, 0, 5),
        );
        expect(textRects.every((r) => r.height < 40), isTrue);
        final allRects = selectionHighlightRects(
          g,
          BlockRange(h.id, h.projection, 0, 13),
        );
        expect(allRects.where((r) => r.height > 100).single, imageBox);
        await tester.pumpWidget(const SizedBox());
      } finally {
        InlineSpanText.debugForceRichText = false;
      }
    });
  }
  testWidgets('阅读图片原有点击仍可执行并清除外层选区', (tester) async {
    final c = SelectionController(SelectionRegistry());
    addTearDown(c.dispose);
    var opened = 0;
    final f = NodeFactory(
      imageContentBuilder: (context, _, _) => GestureDetector(
        onTap: () {
          opened++;
          SelectionScope.clearAt(context);
        },
        child: const SizedBox(
          width: 100,
          height: 120,
          child: ColoredBox(color: Colors.grey),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionScope(
            controller: c,
            child: Builder(
              builder: (context) => f.build(
                context,
                const ImageGridNode(id: 'grid', images: [photo]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final id = c.registry.orderedBlocks().single.id;
    c.selection = DocumentSelection(
      base: DocumentPosition(blockId: id, renderOffset: 0),
      extent: DocumentPosition(blockId: id, renderOffset: 1),
    );
    await tester.tapAt(c.registry.byId(id)!.globalRect()!.center);
    await tester.pump();
    expect(opened, 1);
    expect(c.selection, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
