import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/src/editor/semantic_editor/semantic_editor.dart';

SemanticNode _source() => SemanticNode(
  'doc',
  attrs: {'version': 7},
  content: [
    SemanticNode(
      'paragraph',
      attrs: {'plugin': '保留'},
      content: [
        SemanticNode(
          'text',
          text: '链接文字',
          attrs: {'textMeta': 8},
          marks: [
            SemanticMark('link', {
              'href': '/local',
              'title': '未显示的标题',
              'unknown': {'enabled': true},
            }),
          ],
        ),
      ],
    ),
    SemanticNode(
      'quote',
      attrs: {'username': '用户', 'unknown': 9},
      content: [
        SemanticNode(
          'ordered_list',
          attrs: {'order': 3, 'tight': false, 'unknown': 5},
          content: [
            SemanticNode(
              'list_item',
              attrs: {'key': '来源'},
              content: [
                SemanticNode(
                  'paragraph',
                  content: [SemanticNode('text', text: '列表正文')],
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ],
);

/// 与既有 editor_widget_test 一样模拟平台 TextInput，而非直接调用状态编辑。
/// 保留编辑器下发的 pad，并在每次事件后接受 setEditingState 纠偏。
class _Platform {
  _Platform(this.tester);
  final WidgetTester tester;
  TextEditingValue value = TextEditingValue.empty;

  void absorb() {
    for (final call in tester.testTextInput.log) {
      if (call.method == 'TextInput.setEditingState') {
        value = TextEditingValue.fromJSON(
          (call.arguments as Map).cast<String, dynamic>(),
        );
      }
    }
    tester.testTextInput.log.clear();
  }

  Future<void> send(TextEditingValue next) async {
    expect(tester.testTextInput.hasAnyClients, isTrue);
    value = next;
    tester.testTextInput.updateEditingValue(value);
    await tester.pump();
    await tester.pump();
    absorb();
  }

  Future<void> type(String text) async {
    absorb();
    final selection = value.selection;
    expect(selection.isValid, isTrue);
    await send(
      TextEditingValue(
        text: value.text.replaceRange(selection.start, selection.end, text),
        selection: TextSelection.collapsed(
          offset: selection.start + text.length,
        ),
      ),
    );
  }
}

Future<_Platform> _mount(
  WidgetTester tester,
  SemanticEditorSession session,
) async {
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: FluxdoEditor(state: session.editor, autofocus: true),
        ),
      ),
    ),
  );
  await tester.pump();
  final rect = tester.getRect(find.byType(FluxdoEditor));
  await tester.tapAt(rect.topLeft + const Offset(2, 10));
  await tester.pump();
  expect(tester.testTextInput.hasAnyClients, isTrue);
  return _Platform(tester)..absorb();
}

Future<void> _undo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void _expectAttrs(SemanticNode actual, SemanticNode source) {
  expect(actual.attrs, source.attrs);
  expect(actual.content.first.attrs, source.content.first.attrs);
  expect(
    actual.content.first.content.first.attrs,
    source.content.first.content.first.attrs,
  );
  expect(
    actual.content.first.content.first.marks.single.toJson(),
    source.content.first.content.first.marks.single.toJson(),
  );
  expect(actual.content[1], same(source.content[1]), reason: '未编辑的引用/列表保留来源身份');
}

void main() {
  testWidgets('真实系统剪贴板多段粘贴及键盘撤销保留原尾来源', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': '一\n\n二'} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'paragraph',
          content: [
            SemanticNode('text', text: '甲乙', attrs: {'来源': '原文'}),
          ],
        ),
      ],
    );
    final session = SemanticEditorSession(source);
    await _mount(tester, session);
    session.editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: session.editor.blocks.first.id, offset: 1),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(session.tree.content.map((n) => n.textContent), ['甲一', '二乙']);
    expect(session.tree.content.last.content.last.attrs, {'来源': '原文'});
    await _undo(tester);
    expect(session.tree, same(source));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('真实键盘列表Enter和Backspace可撤销', (tester) async {
    final source = SemanticNode(
      'doc',
      content: [
        SemanticNode(
          'bullet_list',
          attrs: {'plugin': '列表'},
          content: [
            SemanticNode(
              'list_item',
              content: [
                SemanticNode(
                  'paragraph',
                  attrs: {'plugin': '段落'},
                  content: [SemanticNode('text', text: '甲乙')],
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final session = SemanticEditorSession(source);
    await _mount(tester, session);
    session.editor.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: session.editor.blocks.first.id, offset: 1),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(session.editor.blocks.length, 2);
    expect(tester.takeException(), isNull);
    await _undo(tester);
    expect(session.tree, same(source));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('真实点击、键盘选区、平台替换与键盘撤销保留语义树及所有来源属性', (tester) async {
    final source = _source();
    final session = SemanticEditorSession(source);
    final platform = await _mount(tester, session);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(session.editor.selection!.base.offset, 1);
    expect(session.editor.selection!.extent.offset, 2);
    expect(session.tree.toJson(), source.toJson());
    await platform.type('新');
    expect(session.tree.content.first.textContent, '链新文字');
    _expectAttrs(session.tree, source);
    await _undo(tester);
    expect(session.tree.toJson(), source.toJson());
    expect((session.editor.blocks.first as TextBlock).content.text, '链接文字');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('IR 显式链接光标物化后经真实输入仍保留 title，键盘撤销还原', (tester) async {
    final source = _source();
    final session = SemanticEditorSession(source)..editor.mode = EditorMode.ir;
    final platform = await _mount(tester, session);
    final literal = (session.editor.blocks.first as TextBlock).content.text;
    final target = literal.indexOf('链接文字') + 1;
    while (session.editor.selection!.extent.offset < target) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
    }
    expect(
      (session.editor.blocks.first as TextBlock).content.text,
      contains('[链接文字]'),
    );
    expect(session.tree.toJson(), source.toJson(), reason: '物化只改变表示');
    expect(session.editor.selection!.extent.offset, target);
    await platform.type('新');
    expect(session.tree.content.first.textContent, '链新接文字');
    _expectAttrs(session.tree, source);
    await _undo(tester);
    expect(session.tree.toJson(), source.toJson());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('真实 Enter 在链接 offset 2 拆分，来源属性与相邻链接引用列表不丢失', (tester) async {
    final original = _source();
    final source = SemanticNode(
      'doc',
      attrs: original.attrs,
      content: [
        SemanticNode(
          'paragraph',
          attrs: {'plugin': '拆分来源'},
          content: [
            SemanticNode(
              'text',
              text: '链接文字',
              attrs: {'textMeta': 9},
              marks: original.content.first.content.first.marks,
            ),
          ],
        ),
        ...original.content,
      ],
    );
    final session = SemanticEditorSession(source);
    await _mount(tester, session);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(session.editor.selection!.extent.offset, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(session.tree.content, hasLength(4));
    expect(session.tree.content[0].textContent, '链接');
    expect(session.tree.content[1].textContent, '文字');
    for (final paragraph in session.tree.content.take(2)) {
      expect(paragraph.attrs, source.content.first.attrs);
      expect(
        paragraph.content.single.attrs,
        source.content.first.content.single.attrs,
      );
      expect(
        paragraph.content.single.marks,
        source.content.first.content.single.marks,
      );
    }
    expect(session.tree.attrs, source.attrs);
    expect(session.tree.content[2], same(original.content[0]));
    expect(session.tree.content[3], same(original.content[1]));
    await _undo(tester);
    expect(session.tree.toJson(), source.toJson());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
