/// 行内图片原子化(裸图):白名单判据分流、flatten 原子入表、序列化
/// 写回、投影宽 1(图后打字光标坐标正确)、行高不被 strut 压制。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:fluxdo_render/src/editor/widget/editable_paragraph.dart';
import 'package:fluxdo_render/src/selection/projection_builder.dart';

const _bare = ImageRun(
    src: 'https://idcflare.com/uploads/x.png', alt: 'doge.png',
    width: 28, height: 28);
const _scaled = ImageRun(
    src: 'upload://a.jpeg', width: 345, height: 194, scale: 50,
    origWidth: 690, origHeight: 388, previewImageIndex: 0);
const _lightbox = ImageRun(
    src: 'upload://b.jpeg', width: 690, height: 388,
    lightboxUrl: 'https://x/orig.jpeg');

String Function() _idGen() {
  var n = 0;
  return () => 'e_${n++}';
}

void main() {
  test('白名单:全部图片可编辑(官方 inline:true,无图片岛)', () {
    expect(isEditableInline(_bare), isTrue);
    expect(isEditableInline(_scaled), isTrue);
    expect(isEditableInline(_lightbox), isTrue);

    final doc = blockNodesToDoc([
      const ParagraphNode(id: 'b_0', inlines: [
        TextRun('看这个 '), _bare, TextRun(' 表情'),
      ]),
      const ParagraphNode(id: 'b_1', inlines: [_scaled]),
      const ParagraphNode(id: 'b_2', inlines: [_lightbox]),
    ], _idGen());
    expect(doc, everyElement(isA<TextBlock>()), reason: '全图原子化');
    // scaled/lightbox 图入原子表,身份保持
    expect((doc[1] as TextBlock).content.atoms[0], _scaled);
    expect((doc[2] as TextBlock).content.atoms[0], _lightbox);
    // 序列化产物与旧岛路径逐字节一致(两路径同源 _serializeImageRun)
    expect(docToMarkdown([doc[1]]),
        '![|690x388, 50%](upload://a.jpeg)');
    expect(docToMarkdown([doc[2]]),
        '![|690x388](upload://b.jpeg)');
  });

  test('flatten:裸图 FFFC 原子入表,toInlines 原样吐回', () {
    final content = EditableTextContent.fromInlines(const [
      TextRun('前'), _bare, TextRun('后'),
    ]);
    expect(content.text, '前￼后');
    expect(content.atoms[1], _bare);
    final back = content.toInlines();
    expect(back, hasLength(3));
    expect(back[1], _bare);
  });

  test('序列化写回标准图片语法(尺寸保留)', () {
    final doc = blockNodesToDoc([
      const ParagraphNode(id: 'b_0', inlines: [
        TextRun('看 '), _bare, TextRun(' 后文'),
      ]),
    ], _idGen());
    expect(docToMarkdown(doc),
        '看 ![doge.png|28x28](https://idcflare.com/uploads/x.png) 后文');
  });

  test('图后打字:光标在原子后插入文本,原子身份不动', () {
    final s = EditorState(blocks: [
      TextBlock(
        id: 'e_0',
        content: EditableTextContent.fromInlines(const [
          TextRun('a'), _bare,
        ]),
      ),
    ]);
    addTearDown(s.dispose);
    // 光标落原子后(offset 2 = 'a' + FFFC 之后)
    s.updateSelection(const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: 2)));
    s.insertText('文字');
    final b = s.blocks.single as TextBlock;
    expect(b.content.text, 'a￼文字');
    expect(b.content.atoms[1], _bare, reason: '原子偏移/身份不变');
    // 序列化完整
    expect(docToMarkdown(s.blocks),
        'a![doge.png|28x28](https://idcflare.com/uploads/x.png)文字');
  });

  test('退格删原子:整删(行内原子语义,localDate 同款)', () {
    final s = EditorState(blocks: [
      TextBlock(
        id: 'e_0',
        content: EditableTextContent.fromInlines(const [
          TextRun('a'), _bare, TextRun('b'),
        ]),
      ),
    ]);
    addTearDown(s.dispose);
    s.updateSelection(const EditorSelection.collapsed(
        EditorPosition(blockId: 'e_0', offset: 2)));
    s.backspace();
    final b = s.blocks.single as TextBlock;
    expect(b.content.text, 'ab');
    expect(b.content.atoms, isEmpty);
  });

  test('投影:image 原子内容宽 1(图后光标坐标正确)', () {
    final content = EditableTextContent.fromInlines(const [
      TextRun('a'), _bare, TextRun('b'),
    ]);
    final proj = buildInlineProjection(content.toInlines(forEditing: true));
    // 内容空间: a(1) + 原子(1) + b(1) = 3
    expect(proj.contentLength, 3);
    // 原子后位置(内容 2)= 渲染坐标也在 FFFC 之后
    final render = proj.renderOffsetForContent(2);
    expect(proj.contentOffsetForRender(render), 2, reason: '双射');
  });

  testWidgets('段高被图撑起(strut 强制是双向钳制,含图段必须放开)',
      (tester) async {
    // 153x153 大图(用户实测形态:heart webp 表情)
    const big = ImageRun(
        src: 'https://cdn3.ldstatic.com/x.webp', alt: '❤️_20.webp',
        width: 153, height: 153);
    final s = EditorState(blocks: [
      TextBlock(
        id: 'e_0',
        content: EditableTextContent.fromInlines(const [
          TextRun('a'), big, TextRun('b'),
        ]),
      ),
    ]);
    addTearDown(s.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FluxdoEditor(
            state: s,
            baseTextStyle: const TextStyle(fontSize: 16, height: 1.6),
          ),
        ),
      ),
    ));
    await tester.pump();
    final h = tester.getSize(find.byType(EditableParagraph)).height;
    // forceStrutHeight 双向钳制下整段只有 ~26px,153px 图溢出绘制盖邻块
    expect(h, greaterThanOrEqualTo(153),
        reason: '含图段高 $h 必须 ≥ 图高 153(strut 未放开会压到一行高)');
  });
}
