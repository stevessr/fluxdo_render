import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

void main() {
  Future<(EditorState, FluxdoEditorContentActions)> mount(
    WidgetTester tester, {
    Future<bool> Function(String, EditorSelection?)? markdown,
    Future<bool> Function(EditorSelection?)? rich,
    Future<List<EditorBlock>?> Function(String)? legacy,
    Future<List<EditorBlock>?> Function()? legacyRich,
    Future<Object?> Function(MethodCall)? clipboard,
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return clipboard != null
                ? await clipboard(call)
                : {'text': '**原文**'};
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final state = EditorState.fromTexts(['']);
    addTearDown(state.dispose);
    state.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks.first.id, offset: 0),
      ),
    );
    final actions = FluxdoEditorContentActions();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FluxdoEditor(
            state: state,
            contentActions: actions,
            semanticMarkdownInserter: markdown,
            semanticRichPasteInserter: rich,
            markdownImporter: legacy,
            richPasteImporter: legacyRich,
          ),
        ),
      ),
    );
    return (state, actions);
  }

  testWidgets('语义 Markdown 成功传原文和选区且不重复导入', (tester) async {
    String? received;
    EditorSelection? selected;
    final (state, actions) = await mount(
      tester,
      markdown: (text, selection) async {
        received = text;
        selected = selection;
        return true;
      },
      legacy: (_) async => throw StateError('不应调用'),
    );
    final original = state.selection;
    actions.paste();
    await tester.pump();
    expect(received, '**原文**');
    expect(selected, original);
    expect((state.blocks.single as TextBlock).content.text, '');
  });

  for (final throws in [false, true]) {
    testWidgets('语义 Markdown ${throws ? '异常' : 'false'} 保留原文', (tester) async {
      final (state, actions) = await mount(
        tester,
        markdown: (_, _) async {
          if (throws) throw StateError('模拟导入失败');
          return false;
        },
      );
      actions.paste();
      await tester.pump();
      expect(state.exportMarkdown(), '**原文**');
    });
  }

  testWidgets('false 继续旧块导入器', (tester) async {
    var called = false;
    final (_, actions) = await mount(
      tester,
      markdown: (_, _) async => false,
      legacy: (_) async {
        called = true;
        return null;
      },
    );
    actions.paste();
    await tester.pump();
    expect(called, isTrue);
  });

  testWidgets('富格式原数据入口优先且成功后不再调用 Markdown', (tester) async {
    EditorSelection? received;
    var markdownCalled = false;
    final (state, actions) = await mount(
      tester,
      rich: (selection) async {
        received = selection;
        return true;
      },
      markdown: (_, _) async {
        markdownCalled = true;
        return false;
      },
    );
    actions.paste();
    await tester.pump();
    expect(received, state.selection);
    expect(markdownCalled, isFalse);
    expect((state.blocks.single as TextBlock).content.text, '');
  });

  testWidgets('富格式异常回落 Markdown 原文', (tester) async {
    final (state, actions) = await mount(
      tester,
      rich: (_) async => throw StateError('模拟读取失败'),
    );
    actions.paste();
    await tester.pump();
    expect(state.exportMarkdown(), '**原文**');
  });

  testWidgets('rich 在首个 await 前捕获选区且消费后不读剪贴板', (tester) async {
    final pending = Completer<bool>();
    var called = false;
    var clipboardReads = 0;
    var legacyCalls = 0;
    final (state, actions) = await mount(
      tester,
      rich: (selection) {
        called = true;
        return pending.future;
      },
      clipboard: (_) async {
        clipboardReads++;
        return {'text': '不应读取'};
      },
      legacyRich: () async {
        legacyCalls++;
        return null;
      },
    );
    actions.paste();
    expect(called, isTrue);
    expect(clipboardReads, 0);
    pending.complete(true);
    await tester.pump();
    expect(clipboardReads, 0);
    expect(legacyCalls, 0);
    expect((state.blocks.single as TextBlock).content.text, '');
  });

  for (final richHook in [false, true]) {
    for (final throws in [false, true]) {
      for (final editDocument in [false, true]) {
        testWidgets(
          '${richHook ? 'rich' : 'markdown'} ${throws ? 'throw' : 'false'} 等待中${editDocument ? '文档' : '选区'}变化取消回落',
          (tester) async {
            final pending = Completer<bool>();
            var legacyCalls = 0;
            final (state, actions) = await mount(
              tester,
              markdown: richHook ? null : (_, _) => pending.future,
              rich: richHook ? (_) => pending.future : null,
              legacy: (_) async {
                legacyCalls++;
                return null;
              },
            );
            state.pastePlainText('已有');
            actions.paste();
            await tester.pump();
            if (editDocument) {
              state.pastePlainText('新输入');
            } else {
              state.updateSelection(
                EditorSelection.collapsed(
                  EditorPosition(blockId: state.blocks.first.id, offset: 0),
                ),
              );
            }
            if (throws) {
              pending.completeError(StateError('模拟迟到异常'));
            } else {
              pending.complete(false);
            }
            await tester.pump();
            expect(legacyCalls, 0);
            expect(
              (state.blocks.single as TextBlock).content.text,
              editDocument ? '已有新输入' : '已有',
            );
          },
        );
      }
    }
  }

  for (final editDocument in [false, true]) {
    testWidgets('剪贴板读取等待中${editDocument ? '文档' : '选区'}变化不调用语义入口', (
      tester,
    ) async {
      final pending = Completer<Object?>();
      var semanticCalls = 0;
      var legacyCalls = 0;
      final (state, actions) = await mount(
        tester,
        clipboard: (_) => pending.future,
        markdown: (_, _) async {
          semanticCalls++;
          return false;
        },
        legacy: (_) async {
          legacyCalls++;
          return null;
        },
      );
      state.pastePlainText('已有');
      actions.paste();
      await tester.pump();
      if (editDocument) {
        state.pastePlainText('新输入');
      } else {
        state.updateSelection(
          EditorSelection.collapsed(
            EditorPosition(blockId: state.blocks.first.id, offset: 0),
          ),
        );
      }
      pending.complete({'text': '**迟到剪贴板**'});
      await tester.pump();
      expect(semanticCalls, 0);
      expect(legacyCalls, 0);
      expect(
        (state.blocks.single as TextBlock).content.text,
        editDocument ? '已有新输入' : '已有',
      );
    });
  }

  testWidgets('无语义 hooks 保留旧 rich 到 markdown 导入顺序', (tester) async {
    final calls = <String>[];
    final (state, actions) = await mount(
      tester,
      legacyRich: () async {
        calls.add('rich');
        return null;
      },
      legacy: (_) async {
        calls.add('markdown');
        return null;
      },
    );
    actions.paste();
    await tester.pump();
    expect(calls, ['rich', 'markdown']);
    expect(state.exportMarkdown(), '**原文**');
  });

  testWidgets('异步失败不覆盖等待期间的新输入', (tester) async {
    final pending = Completer<bool>();
    final (state, actions) = await mount(
      tester,
      markdown: (_, _) => pending.future,
    );
    actions.paste();
    await tester.pump();
    state.pastePlainText('新输入');
    pending.complete(false);
    await tester.pump();
    expect((state.blocks.single as TextBlock).content.text, '新输入');
  });
}
