/// richPasteImporter(富粘贴注入点)优先/回落链:
/// 有富产物 → 直接插块(不再读纯文本);null / 空 / 抛异常 → 回落
/// kTextPlain 纯文本路径,内容不丢。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

Future<EditorState> pumpEditor(
  WidgetTester tester, {
  Future<List<EditorBlock>?> Function()? richPasteImporter,
  String clipboardText = 'PLAIN',
}) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.getData') {
        return {'text': clipboardText};
      }
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  final state = EditorState.fromTexts(['start']);
  addTearDown(state.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: FluxdoEditor(
        state: state,
        autofocus: true,
        richPasteImporter: richPasteImporter,
      ),
    ),
  ));
  await tester.pump();
  // 落光标(粘贴需要选区)
  await tester.tapAt(tester.getCenter(find.byType(FluxdoEditor)));
  await tester.pump();
  return state;
}

/// 测试环境 defaultTargetPlatform = android → primary 修饰键 = Ctrl。
Future<void> pressPaste(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  // 异步链:richPasteImporter → (回落)Clipboard.getData → 插入
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

String docText(EditorState s) => s.blocks
    .whereType<TextBlock>()
    .map((b) => b.content.text)
    .join('\n');

void main() {
  testWidgets('富产物优先:importer 返回块 → 直接插入,不读纯文本',
      (tester) async {
    final state = await pumpEditor(
      tester,
      richPasteImporter: () async => [
        TextBlock(id: 'r_0', content: EditableTextContent(text: 'RICH')),
      ],
    );
    await pressPaste(tester);
    expect(docText(state), contains('RICH'));
    expect(docText(state), isNot(contains('PLAIN')));
  });

  testWidgets('importer 返回 null → 回落纯文本粘贴', (tester) async {
    final state = await pumpEditor(
      tester,
      richPasteImporter: () async => null,
    );
    await pressPaste(tester);
    expect(docText(state), contains('PLAIN'));
  });

  testWidgets('importer 返回空列表 → 回落纯文本粘贴', (tester) async {
    final state = await pumpEditor(
      tester,
      richPasteImporter: () async => const <EditorBlock>[],
    );
    await pressPaste(tester);
    expect(docText(state), contains('PLAIN'));
  });

  testWidgets('importer 抛异常 → 回落纯文本粘贴(不炸)', (tester) async {
    final state = await pumpEditor(
      tester,
      richPasteImporter: () async => throw StateError('boom'),
    );
    await pressPaste(tester);
    expect(docText(state), contains('PLAIN'));
  });

  testWidgets('未注入 importer → 原纯文本路径不受影响', (tester) async {
    final state = await pumpEditor(tester);
    await pressPaste(tester);
    expect(docText(state), contains('PLAIN'));
  });
}
