import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/widget/fluxdo_editor.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

/// 单击表格 cell 必须立即建立 IME 输入连接并保持。
///
/// 回归:cell 编辑框随格切换在槽位间重建(共享 controller/focusNode),
/// 新 EditableText 挂载时焦点已在 —— 无焦点事件、键盘令牌已被上一格
/// 消费,不会自动 attach(键盘看着在,打字全无效果,再点一下才恢复)。
/// 修复后 _startEdit 帧末主动 requestKeyboard 补连接。
void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform 单击单元格直接建立输入连接,切格后仍可输入', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      EditorState? state;
      try {
        var id = 0;
        state = EditorState(
          blocks: blockNodesToDoc(
            ParagraphParser().parse(
              '<p>正文</p><table><tr><td>A</td><td>B</td></tr></table>',
            ),
            () => 'e_${id++}',
          ),
        );
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FluxdoEditor(
                state: state,
                autofocus: true,
                onTableEdited: (_, _) {},
              ),
            ),
          ),
        ));
        // 光标闪烁常驻帧,不能 pumpAndSettle
        await tester.pump();
        await tester.pump();
        await tester.tap(find.textContaining('正文', findRichText: true));
        await tester.pump();
        await tester.pump();
        final bodySelection = state.selection;
        for (final label in ['A', 'B']) {
          await tester.tap(find.text(label));
          await tester.pump();
          await tester.pump();
          final field = tester.widget<EditableText>(find.byType(EditableText));
          expect(field.focusNode.hasPrimaryFocus, isTrue);
          expect(tester.testTextInput.hasAnyClients, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          // 触屏进编辑态:折叠光标落在文末 —— 有光标可见、打字追加而非
          // 替换;不能是程序化全选态(无光标、不带选择手柄、首字覆盖整格)。
          expect(field.controller.selection.isCollapsed, isTrue);
          expect(
            field.controller.selection.extentOffset,
            field.controller.text.length,
          );
          // 不用 tester.enterText:它会主动 showKeyboard,掩盖首击未接通 IME。
          tester.testTextInput.updateEditingValue(const TextEditingValue(
            text: '新内容',
            selection: TextSelection.collapsed(offset: 3),
          ));
          await tester.pump();
          expect(field.controller.text, '新内容');
          expect(state.selection, bodySelection);
        }
        // 长按:平台语义不同 —— Android 选词,iOS 聚焦态落光标+放大镜
        // (选词靠双击)。均属标准 TextField 行为。
        await tester.longPressAt(
          tester.getTopLeft(find.byType(EditableText)) + const Offset(4, 14),
        );
        await tester.pump();
        await tester.pump();
        final selAfterLongPress = tester
            .widget<EditableText>(find.byType(EditableText))
            .controller.selection;
        if (platform == TargetPlatform.android) {
          expect(selAfterLongPress.isCollapsed, isFalse,
              reason: 'Android 长按应选出词段');
        } else {
          expect(selAfterLongPress.isCollapsed, isTrue,
              reason: 'iOS 聚焦态长按落光标');
        }
        // 双击选词:同一识别器连续 tap 计数到 2 → onDoubleTapDown。
        // 先点文末空白收起长按遗留的选区/手柄（避免按点落在手柄热区），
        // 再双击首字（文本后的空白处无词可选）。
        final fieldTopLeft = tester.getTopLeft(find.byType(EditableText));
        final fieldSize = tester.getSize(find.byType(EditableText));
        await tester.tapAt(
          fieldTopLeft + Offset(fieldSize.width - 8, 14),
        );
        await tester.pump(const Duration(milliseconds: 400));
        final firstChar = fieldTopLeft + const Offset(4, 14);
        await tester.tapAt(firstChar);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(firstChar);
        await tester.pump();
        await tester.pump();
        expect(
          tester.widget<EditableText>(find.byType(EditableText))
              .controller.selection.isCollapsed,
          isFalse,
          reason: '双击应选出词段',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
        state?.dispose();
      }
    });
  }

  testWidgets('键盘遮挡编辑格时自动滚回可见区', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    EditorState? state;
    try {
      var id = 0;
      state = EditorState(
        blocks: blockNodesToDoc(
          ParagraphParser().parse(
            '<p>正文</p><table><tr><td>A</td><td>B</td></tr></table>',
          ),
          () => 'e_${id++}',
        ),
      );
      Widget harness(double keyboard) => MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 600),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: SizedBox(
              height: 600,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 400),
                    FluxdoEditor(
                      state: state!,
                      onTableEdited: (_, _) {},
                    ),
                    // 撑出滚动余量(maxScrollExtent > 0),否则键盘遮
                    // 挡时无路可滚
                    const SizedBox(height: 400),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(harness(0));
      await tester.pump();
      await tester.pump();
      // 无键盘时格子本就可见,不应有多余滚动
      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final field = find.byType(EditableText);
      final before = tester.getRect(field);
      expect(before.bottom, lessThan(600));
      expect(before.top, greaterThanOrEqualTo(0));
      // 弹出 300 高的键盘后可见区只剩 [0, 300],格子(≈400+)被遮住;
      // 点切到另一格 → 自动定位把编辑格滚回可见区。
      await tester.pumpWidget(harness(300));
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pump(); // postFrame: requestKeyboard + reveal 注册
      // 测试绑定 ticker 首个 tick 锚定 elapsed=0，animateTo 的位移从
      // 第二个 tick 起生效 —— 逐帧 pump 至动画收敛。
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 150));
      final after = tester.getRect(field);
      expect(after.bottom, lessThan(300), reason: '编辑格不得被键盘遮住');
      expect(after.top, greaterThanOrEqualTo(0));
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
      state?.dispose();
    }
  });
}
