/// 图片原子「加入网格」命令:三分支块结构 + 单事务 undo + 序列化。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

const _img = ImageRun(
  src: 'upload://new.png',
  alt: 'n',
  width: 100,
  height: 80,
);
const _gridImg = ImageRun(
  src: 'upload://old.png',
  alt: 'o',
  width: 50,
  height: 50,
);

TextBlock _textWithImg(String id, {String before = 'a', String after = 'b'}) =>
    TextBlock(
      id: id,
      content: EditableTextContent.fromInlines([
        if (before.isNotEmpty) TextRun(before),
        _img,
        if (after.isNotEmpty) TextRun(after),
      ]),
    );

IslandBlock _gridIsland(String id) => IslandBlock(
  id: id,
  node: const ImageGridNode(id: 'b_g', images: [_gridImg]),
);

void main() {
  test('批量添加合并当前图片顺序、保留模式且可一步撤销', () {
    final s = EditorState(
      blocks: [
        const IslandBlock(
          id: 'grid',
          node: ImageGridNode(
            id: 'node',
            mode: ImageGridMode.carousel,
            columns: 3,
            images: [_gridImg],
          ),
        ),
      ],
    );
    addTearDown(s.dispose);
    final before = s.blocks;
    expect(
      appendImagesToGrid(s, 'grid', [_img, const ImageRun(src: 'other')]),
      isTrue,
    );
    final node = (s.blocks.first as IslandBlock).node as ImageGridNode;
    expect(node.images.map((image) => image.src), [
      'upload://old.png',
      'upload://new.png',
      'other',
    ]);
    expect(node.mode, ImageGridMode.carousel);
    expect(node.columns, 3);
    s.undo();
    expect(s.blocks, before);
    expect(appendImagesToGrid(s, 'gone', [_img]), isFalse);
    expect(s.blocks, before);
  });

  test('分支1:前邻 grid → append,选中 grid 岛,undo 一步还原', () {
    final s = EditorState(blocks: [_gridIsland('e_g'), _textWithImg('e_t')]);
    addTearDown(s.dispose);
    final beforeBlocks = s.blocks;

    expect(addImageAtomToGrid(s, 'e_t', 1), isTrue);
    expect(s.blocks, hasLength(2));
    final grid = (s.blocks[0] as IslandBlock).node as ImageGridNode;
    expect(grid.images, [_gridImg, _img], reason: 'append 到尾');
    expect((s.blocks[1] as TextBlock).content.text, 'ab');
    expect(s.selection!.base.blockId, 'e_g', reason: '整选 grid 岛');
    expect(s.selection!.extent.offset, 1);

    s.undo();
    expect(s.blocks, beforeBlocks, reason: '单事务 undo 一步整体还原');
  });

  test('分支2:后邻 grid → prepend;删原子后空段丢弃', () {
    final s = EditorState(
      blocks: [
        _textWithImg('e_t', before: '', after: ''), // 段内只有图
        _gridIsland('e_g'),
      ],
    );
    addTearDown(s.dispose);

    expect(addImageAtomToGrid(s, 'e_t', 0), isTrue);
    // 空段丢弃 → 只剩 grid 岛(+文档不变量自动补的空段)
    final islands = s.blocks.whereType<IslandBlock>().toList();
    expect(islands, hasLength(1));
    final grid = islands.single.node as ImageGridNode;
    expect(grid.images, [_img, _gridImg], reason: 'prepend 到头');
  });

  test('分支3:无邻 grid → 原地新建,段切三段', () {
    final s = EditorState(blocks: [_textWithImg('e_t')]);
    addTearDown(s.dispose);

    expect(addImageAtomToGrid(s, 'e_t', 1), isTrue);
    expect(s.blocks, hasLength(3));
    expect((s.blocks[0] as TextBlock).content.text, 'a');
    final grid = (s.blocks[1] as IslandBlock).node as ImageGridNode;
    expect(grid.images, [_img]);
    expect((s.blocks[2] as TextBlock).content.text, 'b');
    // 序列化含 [grid]
    expect(docToMarkdown(s.blocks), contains('[grid]'));
    expect(docToMarkdown(s.blocks), contains('![n|100x80](upload://new.png)'));

    s.undo();
    expect(s.blocks, hasLength(1));
    expect((s.blocks[0] as TextBlock).content.text, 'a￼b');
  });

  test('非图原子位置返回 false 不动文档', () {
    final s = EditorState.fromTexts(['纯文本']);
    addTearDown(s.dispose);
    expect(addImageAtomToGrid(s, s.blocks.first.id, 0), isFalse);
  });

  test('replaceAtomAt reselect:true 保持原子整选', () {
    final s = EditorState(blocks: [_textWithImg('e_t')]);
    addTearDown(s.dispose);
    s.replaceAtomAt('e_t', 1, _img.copyWith(scale: 75), reselect: true);
    expect(s.selection!.base.offset, 1);
    expect(s.selection!.extent.offset, 2, reason: '原子整选保持');
    expect(((s.blocks[0] as TextBlock).content.atoms[1] as ImageRun).scale, 75);
    // 默认(date chip 路径)仍是折叠到原子后
    s.replaceAtomAt('e_t', 1, _img);
    expect(s.selection!.isCollapsed, isTrue);
    expect(s.selection!.base.offset, 2);
  });

  test('copyWith alt:空串清空,null 不改', () {
    const img = ImageRun(src: 's', alt: '原');
    expect(img.copyWith(alt: '新').alt, '新');
    expect(img.copyWith(alt: '').alt, '');
    expect(img.copyWith(scale: 50).alt, '原');
  });

  gridOpsTests();
}

// ---- 网格自身操作(官方 GridNodeView:removeGrid / setMode) ----

IslandBlock _grid3(String id) => IslandBlock(
  id: id,
  node: const ImageGridNode(
    id: 'b_g3',
    images: [
      ImageRun(src: 'upload://1.png', alt: 'a', width: 10, height: 10),
      ImageRun(src: 'upload://2.png', alt: 'b', width: 20, height: 20),
      ImageRun(src: 'upload://3.png', alt: 'c', width: 30, height: 30),
    ],
  ),
);

void gridOpsTests() {
  test('removeImageGrid:拆壳,每图一原子段,undo 一步还原', () {
    final s = EditorState(
      blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: '前'),
        ),
        _grid3('e_g'),
      ],
    );
    addTearDown(s.dispose);

    expect(removeImageGrid(s, 'e_g'), isTrue);
    expect(s.blocks, hasLength(4)); // 前 + 三图段
    for (var i = 1; i <= 3; i++) {
      final b = s.blocks[i] as TextBlock;
      expect(b.content.atoms[0], isA<ImageRun>());
      expect(b.content.text, '￼');
    }
    // 序列化:不再有 [grid],三图各自独段
    final md = docToMarkdown(s.blocks);
    expect(md, isNot(contains('[grid]')));
    expect(md, contains('![a|10x10](upload://1.png)'));

    s.undo();
    expect(s.blocks, hasLength(2));
    expect(s.blocks[1], isA<IslandBlock>());
  });

  test('setImageGridMode:grid ⇄ carousel,序列化带 mode 后缀', () {
    final s = EditorState(
      blocks: [
        _grid3('e_g'),
        TextBlock(id: 'e_t', content: EditableTextContent.empty),
      ],
    );
    addTearDown(s.dispose);

    expect(setImageGridMode(s, 'e_g', ImageGridMode.carousel), isTrue);
    final grid = (s.blocks[0] as IslandBlock).node as ImageGridNode;
    expect(grid.mode, ImageGridMode.carousel);
    expect(docToMarkdown(s.blocks), contains('[grid mode=carousel]'));

    // 切回 grid:无 mode 后缀
    setImageGridMode(s, 'e_g', ImageGridMode.grid);
    expect(docToMarkdown(s.blocks), isNot(contains('mode=carousel')));
    // 同值幂等
    expect(setImageGridMode(s, 'e_g', ImageGridMode.grid), isTrue);
  });

  test('非 grid 岛返回 false', () {
    final s = EditorState.fromTexts(['x']);
    addTearDown(s.dispose);
    expect(removeImageGrid(s, s.blocks.first.id), isFalse);
    expect(
      setImageGridMode(s, s.blocks.first.id, ImageGridMode.carousel),
      isFalse,
    );
  });

  test('removeImageFromGrid:删单图;删到空整岛移除', () {
    final s = EditorState(
      blocks: [
        _grid3('e_g'),
        TextBlock(id: 'e_t', content: EditableTextContent.empty),
      ],
    );
    addTearDown(s.dispose);

    expect(removeImageFromGrid(s, 'e_g', 1), isTrue);
    var grid = (s.blocks[0] as IslandBlock).node as ImageGridNode;
    expect(grid.images.map((i) => i.alt), ['a', 'c']);

    removeImageFromGrid(s, 'e_g', 0);
    removeImageFromGrid(s, 'e_g', 0);
    expect(s.blocks.whereType<IslandBlock>(), isEmpty, reason: '空 grid 清理');
    // 越界/非 grid 拒绝
    expect(removeImageFromGrid(s, 'e_t', 0), isFalse);
  });

  test('moveImageOutsideGrid:抽出为岛后独立图段并整选;剩一张拆壳', () {
    final s = EditorState(
      blocks: [
        _grid3('e_g'),
        TextBlock(id: 'e_t', content: EditableTextContent.empty),
      ],
    );
    addTearDown(s.dispose);

    expect(moveImageOutsideGrid(s, 'e_g', 1), isTrue);
    // grid(a,c) + b 图段 + 空段
    final grid = (s.blocks[0] as IslandBlock).node as ImageGridNode;
    expect(grid.images.map((i) => i.alt), ['a', 'c']);
    final imgBlock = s.blocks[1] as TextBlock;
    expect((imgBlock.content.atoms[0] as ImageRun).alt, 'b');
    // 移出的图保持原子整选(官方 NodeSelection)
    expect(s.selection!.base.blockId, imgBlock.id);
    expect(s.selection!.extent.offset, 1);

    // 连续移出到只剩一张:grid 壳消失
    moveImageOutsideGrid(s, 'e_g', 0);
    moveImageOutsideGrid(s, 'e_g', 0);
    expect(s.blocks.whereType<IslandBlock>(), isEmpty);

    s.undo(); // 一步还原最后一次移出
    expect(s.blocks.whereType<IslandBlock>(), hasLength(1));
  });
}
