import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser image 识别', () {
    test('普通 img 产生 ImageRun(无 width/height)', () {
      final result = parser.parse(
        '<p>x <img src="https://e.com/foo.png" alt="foo"> y</p>',
      );
      final p = result[0] as ParagraphNode;
      final img = p.inlines[1] as ImageRun;
      expect(img.src, 'https://e.com/foo.png');
      expect(img.alt, 'foo');
      expect(img.width, isNull);
      expect(img.height, isNull);
    });

    test('带 width/height attribute 解析为 double', () {
      final result = parser.parse(
        '<p><img src="x.png" width="200" height="120"></p>',
      );
      final p = result[0] as ParagraphNode;
      final img = p.inlines[0] as ImageRun;
      expect(img.width, 200);
      expect(img.height, 120);
    });

    test('class=emoji 走 EmojiRun 不走 ImageRun', () {
      final result = parser.parse(
        '<p><img src="h.png" class="emoji" title=":heart:"></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines[0], isA<EmojiRun>());
      expect(p.inlines[0], isNot(isA<ImageRun>()));
    });

    test('alt 缺失时 alt 为空串', () {
      final result = parser.parse('<p><img src="x.png"></p>');
      final p = result[0] as ParagraphNode;
      expect((p.inlines[0] as ImageRun).alt, '');
    });

    test('img 嵌套在 link 内', () {
      final result = parser.parse(
        '<p><a href="/big"><img src="thumb.png" width="100" height="100"></a></p>',
      );
      final p = result[0] as ParagraphNode;
      final link = p.inlines[0] as LinkRun;
      expect(link.children, hasLength(1));
      expect(link.children[0], isA<ImageRun>());
    });

    test('一段内多张图', () {
      final result = parser.parse(
        '<p><img src="a.png"> 和 <img src="b.png"></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<ImageRun>(), hasLength(2));
    });

    test('width attribute 非数字时为 null(parse 容错)', () {
      final result = parser.parse(
        '<p><img src="x.png" width="auto" height="auto"></p>',
      );
      final p = result[0] as ParagraphNode;
      expect((p.inlines[0] as ImageRun).width, isNull);
      expect((p.inlines[0] as ImageRun).height, isNull);
    });

    test('div.lightbox-wrapper 产 ImageRun(src=缩略图, lightboxUrl=原图)', () {
      final result = parser.parse(
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x/full.png">'
        '<img src="https://x/thumb_690x52.png" alt="hash" width="690" height="52">'
        '<div class="meta">'
        '<span class="filename">hash</span>'
        '<span class="informations">1686×128 15.7 KB</span>'
        '</div>'
        '</a>'
        '</div>',
      );
      expect(result, hasLength(1));
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(1));
      final img = p.inlines[0] as ImageRun;
      expect(img.src, 'https://x/thumb_690x52.png');
      expect(img.lightboxUrl, 'https://x/full.png');
      expect(img.alt, 'hash');
      expect(img.width, 690);
      expect(img.height, 52);
    });

    test('a.lightbox 直包 img 也产 lightboxUrl', () {
      final result = parser.parse(
        '<p><a class="lightbox" href="https://x/full.png">'
        '<img src="https://x/thumb.png" alt="x" width="100" height="50">'
        '</a></p>',
      );
      final p = result[0] as ParagraphNode;
      final img = p.inlines[0] as ImageRun;
      expect(img.src, 'https://x/thumb.png');
      expect(img.lightboxUrl, 'https://x/full.png');
      expect(img.indexInPost, 0);
    });

    test('lightbox-wrapper 在 p 内(HTML5 implicit p close)', () {
      // 真实 Discourse cooked 形态,markdown 渲染时把 div 写在 p 里
      final result = parser.parse(
        '<p><strong>前</strong></p>'
        '<p><div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x/full.png">'
        '<img src="https://x/thumb.png" alt="x" width="100" height="50">'
        '<div class="meta"><span>x</span><span>100×50 1 KB</span></div>'
        '</a>'
        '</div></p>'
        '<p><strong>后</strong></p>',
      );
      // 期望:p1(前) + p(image) + p2(后)
      expect(result.whereType<ParagraphNode>(), hasLength(3));
      final imageP = result[1] as ParagraphNode;
      expect(imageP.inlines, hasLength(1));
      expect(imageP.inlines[0], isA<ImageRun>());
      // 关键:不应有 ".meta" 内的文字 (hash / 100×50 / 1 KB)
      // textContent fallback 走的话会有
    });

    test('lightbox-wrapper 内无 img 时不产 ImageRun', () {
      final result = parser.parse(
        '<div class="lightbox-wrapper"><a>no img</a></div>',
      );
      // 容错:跳过不产节点
      expect(result.whereType<ImageRun>(), isEmpty);
    });

    test('连续两张 lightbox-wrapper(中间 br)合并到同一 ParagraphNode', () {
      // 真实 cooked 形态:Discourse markdown 渲染多图时
      //   <p><div class="lightbox-wrapper">img1</div><br>
      //      <div class="lightbox-wrapper">img2</div></p>
      // 如果两张图各产独立 ParagraphNode,1em+1em 段间距堆出大空隙。
      // 正确行为:合并到一个 ParagraphNode + LineBreakRun 分隔。
      final result = parser.parse(
        '<p><strong>前</strong></p>'
        '<p><div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x/full1.png">'
        '<img src="https://x/thumb1.png" alt="i1" width="100" height="50">'
        '</a></div><br>'
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x/full2.png">'
        '<img src="https://x/thumb2.png" alt="i2" width="100" height="50">'
        '</a></div></p>'
        '<p><strong>后</strong></p>',
      );
      // 期望 3 个 BlockNode:前段 / 图1+br+图2 / 后段
      expect(result, hasLength(3));
      final imagesParagraph = result[1] as ParagraphNode;
      final imgs = imagesParagraph.inlines.whereType<ImageRun>().toList();
      expect(imgs, hasLength(2));
      expect(imgs[0].lightboxUrl, 'https://x/full1.png');
      expect(imgs[1].lightboxUrl, 'https://x/full2.png');
      // 期望两张图之间至少有 1 个 LineBreakRun(原 cooked <br>)
      expect(imagesParagraph.inlines.whereType<LineBreakRun>(), isNotEmpty);
    });

    test('indexInPost 按出现顺序 0,1,2 递增', () {
      final result = parser.parse(
        '<p><img src="a.png"></p>'
        '<p>中间段</p>'
        '<p><img src="b.png"> 和 <img src="c.png"></p>',
      );
      final imgs = <ImageRun>[];
      for (final n in result.whereType<ParagraphNode>()) {
        imgs.addAll(n.inlines.whereType<ImageRun>());
      }
      expect(imgs, hasLength(3));
      expect(imgs[0].indexInPost, 0);
      expect(imgs[1].indexInPost, 1);
      expect(imgs[2].indexInPost, 2);
    });

    test('indexInPost 跨 blockquote / list 嵌套全局连续', () {
      final result = parser.parse(
        '<p><img src="a.png"></p>'
        '<blockquote><p><img src="b.png"></p></blockquote>'
        '<ul><li><img src="c.png"></li></ul>',
      );
      final imgs = <ImageRun>[];
      void scan(BlockNode b) {
        switch (b) {
          case ParagraphNode(:final inlines):
            imgs.addAll(inlines.whereType<ImageRun>());
          case BlockquoteNode(:final children):
            for (final c in children) {
              scan(c);
            }
          case ListNode(:final items):
            for (final i in items) {
              imgs.addAll(i.inlines.whereType<ImageRun>());
            }
          case _:
            break;
        }
      }
      result.forEach(scan);
      expect(imgs.map((e) => e.indexInPost), [0, 1, 2]);
    });

    test('emoji img 不参与 indexInPost 计数', () {
      final result = parser.parse(
        '<p>'
        '<img src="e1.png" class="emoji" alt=":heart:">'
        '<img src="a.png">'
        '<img src="e2.png" class="emoji" alt=":fire:">'
        '<img src="b.png">'
        '</p>',
      );
      final p = result[0] as ParagraphNode;
      final imgs = p.inlines.whereType<ImageRun>().toList();
      expect(imgs, hasLength(2));
      expect(imgs[0].indexInPost, 0);
      expect(imgs[1].indexInPost, 1);
    });
  });

  group('Discourse 契约字段(srcset/dominant-color/base62/informations)', () {
    ImageRun firstImage(List<BlockNode> nodes) =>
        collectImageRuns(nodes).first;

    test('srcset 解析为档位列表(首项 1x,描述符 1.5x/2x)', () {
      final result = parser.parse(
        '<p><img src="a_690.png" '
        'srcset="a_690.png, a_1035.png 1.5x, a_1380.png 2x"></p>',
      );
      final img = firstImage(result);
      expect(img.srcset, hasLength(3));
      expect(img.srcset[0].url, 'a_690.png');
      expect(img.srcset[0].scale, 1.0);
      expect(img.srcset[1].scale, 1.5);
      expect(img.srcset[2].url, 'a_1380.png');
      expect(img.srcset[2].scale, 2.0);
    });

    test('无 srcset 时为空列表', () {
      final result = parser.parse('<p><img src="a.png"></p>');
      expect(firstImage(result).srcset, isEmpty);
    });

    test('data-dominant-color / data-base62-sha1 提取', () {
      final result = parser.parse(
        '<p><img src="a.png" data-dominant-color="E8F0D5" '
        'data-base62-sha1="xyz123"></p>',
      );
      final img = firstImage(result);
      expect(img.dominantColor, 'E8F0D5');
      expect(img.base62Sha1, 'xyz123');
    });

    test('lightbox .informations 解析原图尺寸与文件大小', () {
      final result = parser.parse(
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://e.com/original/x.png">'
        '<img src="https://e.com/optimized/x_690x52.png" width="690" height="52">'
        '<div class="meta">'
        '<span class="filename">x.png</span>'
        '<span class="informations">1686×128 15.7 KB</span>'
        '</div></a></div>',
      );
      final img = firstImage(result);
      expect(img.lightboxUrl, 'https://e.com/original/x.png');
      expect(img.naturalWidth, 1686);
      expect(img.naturalHeight, 128);
      expect(img.fileSizeText, '15.7 KB');
      // 显示尺寸与原图尺寸分离
      expect(img.width, 690);
      expect(img.height, 52);
    });

    test('lightbox .meta .filename 提取原始文件名', () {
      final result = parser.parse(
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://e.com/original/7d38c2.jpeg">'
        '<img src="https://e.com/optimized/x_690x52.jpeg" width="690" height="52">'
        '<div class="meta">'
        '<span class="filename">PXL_20240101_123456.jpg</span>'
        '<span class="informations">1686×128 15.7 KB</span>'
        '</div></a></div>',
      );
      // 文件名与 URL 解耦:即使原图 URL 是哈希名,仍拿到上传原名。
      expect(firstImage(result).filename, 'PXL_20240101_123456.jpg');
    });

    test('.filename 缺失时回退 anchor title', () {
      final result = parser.parse(
        '<p><a class="lightbox" href="https://e.com/o.png" title="photo.png">'
        '<img src="https://e.com/t.png">'
        '</a></p>',
      );
      expect(firstImage(result).filename, 'photo.png');
    });

    test('无 .filename 与 title 时 filename 为 null', () {
      final result = parser.parse(
        '<p><a class="lightbox" href="https://e.com/o.png">'
        '<img src="https://e.com/t.png">'
        '</a></p>',
      );
      expect(firstImage(result).filename, isNull);
    });

    test('informations 缺失/畸形时静默 null 不炸', () {
      final result = parser.parse(
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://e.com/o.png">'
        '<img src="https://e.com/t.png">'
        '<div class="meta"><span class="informations">not-a-size</span></div>'
        '</a></div>',
      );
      final img = firstImage(result);
      expect(img.lightboxUrl, 'https://e.com/o.png');
      expect(img.naturalWidth, isNull);
      expect(img.fileSizeText, isNull);
    });
  });
}
