/// 颜色 mark(`[color=…]` / `[bgcolor=…]`)测试。
///
/// 核心诉求:带色文字必须**可编辑**。此前 ColoredRun 不在可编辑白名单,
/// 打一句带色的话整行被岛化成只读岛,光标直接消失(实测复现)。
library;

import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

const _red = Color(0xFFFF0000);

ParagraphNode _colored({Color? fg, Color? bg, String text = '红字'}) =>
    ParagraphNode(id: 'p', inlines: [
      ColoredRun(color: fg, background: bg, children: [TextRun(text)]),
    ]);

ParagraphNode _cooked(String html) =>
    ParagraphParser().parse(html).first as ParagraphNode;

String _roundtrip(String html) {
  var n = 0;
  final doc = blockNodesToDoc([_cooked(html)], () => 'e_${n++}');
  return docToMarkdown(doc);
}

void main() {
  group('可编辑性(核心)', () {
    test('ColoredRun 在可编辑白名单里 —— 不再岛化', () {
      expect(
        isEditableInline(
          const ColoredRun(color: _red, children: [TextRun('a')]),
        ),
        isTrue,
      );
    });

    test('带色段落落成 TextBlock 而不是只读岛', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      expect(doc.single, isA<TextBlock>(), reason: '岛化会让光标消失');
      expect((doc.single as TextBlock).content.text, '红字');
    });

    test('带色文字照常可插入编辑', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      final block = doc.single as TextBlock;
      final edited = block.content.insert(block.content.length, '继续打字');
      expect(edited.text, '红字继续打字');
    });
  });

  group('mark 往返', () {
    test('前景色 → mark(带色值 attr)', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      final marks = (doc.single as TextBlock).content.marks;
      final m = marks.singleWhere((m) => m.kind == MarkKind.textColor);
      expect(m.attr, '#ff0000');
      expect(m.start, 0);
      expect(m.end, 2);
    });

    test('背景色走 bgColor', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(bg: _red)], () => 'e_${n++}');
      final marks = (doc.single as TextBlock).content.marks;
      expect(marks.single.kind, MarkKind.bgColor);
      expect(marks.single.attr, '#ff0000');
    });

    test('序列化成 BBCode', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      expect(docToMarkdown(doc), '[color=#ff0000]红字[/color]');
    });

    test('前景+背景同时存在', () {
      var n = 0;
      final doc = blockNodesToDoc(
        [_colored(fg: _red, bg: const Color(0xFF00FF00))],
        () => 'e_${n++}',
      );
      final raw = docToMarkdown(doc);
      expect(raw, contains('[color=#ff0000]'));
      expect(raw, contains('[bgcolor=#00ff00]'));
    });

    test('toInlines 还原出 ColoredRun', () {
      var n = 0;
      final doc = blockNodesToDoc([_colored(fg: _red)], () => 'e_${n++}');
      final inlines = (doc.single as TextBlock).content.toInlines();
      final colored = inlines.whereType<ColoredRun>().single;
      expect(colored.color, _red);
    });
  });

  group('attr 原样保留(往返门禁契约)', () {
    // 服务端 bbcode-color 插件把 [color=X] 的 X 原样放进 style;门禁两侧
    // 都是客户端 bundle(把 [color] 当字面文本)→ 序列化逐字写回 X 即过
    // 门禁,任何规范化(小写化 / red→hex)都会失配整帖降级。
    test('[color=red] 命名色往返字节不变', () {
      expect(
        _roundtrip('<p><span style="color:red">x</span></p>'),
        '[color=red]x[/color]',
      );
    });

    test('[color=#F00] 短 hex 大写往返字节不变', () {
      expect(
        _roundtrip('<p><span style="color:#F00">x</span></p>'),
        '[color=#F00]x[/color]',
      );
    });

    test('[color=#ff0000] 全长 hex 往返字节不变', () {
      expect(
        _roundtrip('<p><span style="color:#ff0000">x</span></p>'),
        '[color=#ff0000]x[/color]',
      );
    });

    test('[bgcolor=yellow] 往返字节不变', () {
      expect(
        _roundtrip('<p><span style="background-color:yellow">x</span></p>'),
        '[bgcolor=yellow]x[/bgcolor]',
      );
    });

    test('命名色渲染仍能取到色(toInlines 出 ColoredRun 带 Color)', () {
      var n = 0;
      final doc = blockNodesToDoc(
        [_cooked('<p><span style="color:red">x</span></p>')],
        () => 'e_${n++}',
      );
      final inlines = (doc.single as TextBlock).content.toInlines();
      final colored = inlines.whereType<ColoredRun>().single;
      expect(colored.color, const Color(0xFFFF0000));
      expect(colored.colorRaw, 'red');
    });

    test('解析不出的色值:渲染降级无色,但原文不丢', () {
      var n = 0;
      final doc = blockNodesToDoc(
        [
          ParagraphNode(id: 'p', inlines: [
            const ColoredRun(
                colorRaw: 'var(--x)', children: [TextRun('x')]),
          ])
        ],
        () => 'e_${n++}',
      );
      final block = doc.single as TextBlock;
      expect(
        block.content.marks
            .singleWhere((m) => m.kind == MarkKind.textColor)
            .attr,
        'var(--x)',
      );
      final colored =
          block.content.toInlines().whereType<ColoredRun>().single;
      expect(colored.color, isNull, reason: '取色失败按降级,不上色');
      expect(docToMarkdown(doc), '[color=var(--x)]x[/color]');
    });
  });

  group('嵌套颜色取内层(CSS 内层胜)', () {
    test('外红内蓝:中段渲染成蓝色', () {
      // [color=red]a[color=blue]b[/color]c[/color] 的 cooked 形态
      var n = 0;
      final doc = blockNodesToDoc(
        [
          _cooked('<p><span style="color:red">a'
              '<span style="color:blue">b</span>c</span></p>')
        ],
        () => 'e_${n++}',
      );
      final inlines = (doc.single as TextBlock).content.toInlines();
      final colored = inlines.whereType<ColoredRun>().toList();
      // a / b / c 三段各自成 ColoredRun
      expect(colored, hasLength(3));
      Color? colorOfText(String t) => colored
          .singleWhere((c) => (c.children.single as TextRun).text == t)
          .color;
      expect(colorOfText('a'), const Color(0xFFFF0000));
      expect(colorOfText('b'), const Color(0xFF0000FF),
          reason: '内层区间最窄,必须胜出(修复前取到外层红)');
      expect(colorOfText('c'), const Color(0xFFFF0000));
    });

    test('嵌套背景色同理取内层', () {
      var n = 0;
      final doc = blockNodesToDoc(
        [
          _cooked('<p><span style="background-color:yellow">a'
              '<span style="background-color:lime">b</span></span></p>')
        ],
        () => 'e_${n++}',
      );
      final inlines = (doc.single as TextBlock).content.toInlines();
      final inner = inlines
          .whereType<ColoredRun>()
          .singleWhere((c) => (c.children.single as TextRun).text == 'b');
      expect(inner.background, const Color(0xFF00FF00));
    });
  });

  group('色值解析', () {
    test('#rgb 与 #rrggbb 都认,非法返回 null', () {
      expect(EditableTextContent.parseHex('#f00'), const Color(0xFFFF0000));
      expect(EditableTextContent.parseHex('#ff0000'), const Color(0xFFFF0000));
      expect(EditableTextContent.parseHex('red'), isNull);
      expect(EditableTextContent.parseHex('#12345'), isNull);
      expect(EditableTextContent.parseHex(null), isNull);
    });
  });

  group('EditorState.applyTextColor', () {
    TextBlock only(EditorState s) => s.blocks.single as TextBlock;

    test('选区施加:mark 带 attr 原文,序列化写回 BBCode', () {
      final s = EditorState(
        blocks: [TextBlock(id: 'e_t', content: EditableTextContent(text: '红字'))],
      );
      addTearDown(s.dispose);
      s.updateSelection(const EditorSelection(
        base: EditorPosition(blockId: 'e_t', offset: 0),
        extent: EditorPosition(blockId: 'e_t', offset: 2),
      ));
      s.applyTextColor('#e45735');
      final c = only(s).content;
      expect(c.text, '红字');
      expect(c.marks.single.kind, MarkKind.textColor);
      expect(c.marks.single.attr, '#e45735', reason: 'attr 逐字透传,不规范化');
      final md = docToMarkdown(s.blocks);
      expect(md, contains('[color=#e45735]'));
      expect(md, contains('红字[/color]'));
    });

    test('改色覆盖旧区间(同 kind 异 attr)', () {
      final s = EditorState(
        blocks: [TextBlock(id: 'e_t', content: EditableTextContent(text: '红字'))],
      );
      addTearDown(s.dispose);
      const sel = EditorSelection(
        base: EditorPosition(blockId: 'e_t', offset: 0),
        extent: EditorPosition(blockId: 'e_t', offset: 2),
      );
      s.updateSelection(sel);
      s.applyTextColor('#ff0000');
      s.updateSelection(sel);
      s.applyTextColor('blue');
      final c = only(s).content;
      expect(c.marks.where((m) => m.kind == MarkKind.textColor), hasLength(1));
      expect(c.marks.single.attr, 'blue');
    });

    test('折叠选区 no-op(视图层走占位符路径)', () {
      final s = EditorState(
        blocks: [TextBlock(id: 'e_t', content: EditableTextContent(text: '红字'))],
      );
      addTearDown(s.dispose);
      s.updateSelection(const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_t', offset: 1)));
      s.applyTextColor('#f00');
      expect(only(s).content.marks, isEmpty);
    });

    test('跨块选区 no-op', () {
      final s = EditorState(blocks: [
        TextBlock(id: 'e_0', content: EditableTextContent(text: 'aa')),
        TextBlock(id: 'e_1', content: EditableTextContent(text: 'bb')),
      ]);
      addTearDown(s.dispose);
      s.updateSelection(EditorSelection(
        base: EditorPosition(blockId: 'e_0', offset: 0),
        extent: EditorPosition(blockId: 'e_1', offset: 2),
      ));
      s.applyTextColor('#f00');
      for (final b in s.blocks) {
        expect((b as TextBlock).content.marks, isEmpty);
      }
    });
  });
}
