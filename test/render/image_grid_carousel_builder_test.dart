/// 验证 carousel 形态 buildImageGrid 优先调 imageGridBuilder;返回 null 时
/// 降级单列大图(走 imageContentBuilder)。grid 形态不调 imageGridBuilder。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

void main() {
  ImageGridNode carouselNode() => const ImageGridNode(
        id: 'g',
        mode: ImageGridMode.carousel,
        images: [
          ImageRun(src: 'a.jpg', lightboxUrl: 'A.jpg', indexInPost: 0),
          ImageRun(src: 'b.jpg', lightboxUrl: 'B.jpg', indexInPost: 1),
        ],
      );

  testWidgets('carousel 优先用 imageGridBuilder 返回值', (tester) async {
    var called = 0;
    ImageGridNode? seen;
    final factory = NodeFactory(
      imageGridBuilder: (ctx, node) {
        called++;
        seen = node;
        return const Text('CUSTOM_CAROUSEL');
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => factory.buildImageGrid(ctx, carouselNode()),
        ),
      ),
    ));
    expect(called, 1);
    expect(seen!.images, hasLength(2));
    expect(find.text('CUSTOM_CAROUSEL'), findsOneWidget);
  });

  testWidgets('imageGridBuilder 返回 null → 单列 fallback(走 imageContentBuilder)',
      (tester) async {
    final built = <int>[];
    final factory = NodeFactory(
      imageGridBuilder: (ctx, node) => null, // 明确降级
      imageContentBuilder: (ctx, image, total) {
        built.add(image.indexInPost);
        return SizedBox(key: ValueKey('img_${image.indexInPost}'));
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => factory.buildImageGrid(ctx, carouselNode()),
        ),
      ),
    ));
    // 单列 fallback 逐张走 imageContentBuilder
    expect(built, [0, 1]);
    expect(find.byKey(const ValueKey('img_0')), findsOneWidget);
    expect(find.byKey(const ValueKey('img_1')), findsOneWidget);
    expect(find.text('CUSTOM_CAROUSEL'), findsNothing);
  });

  testWidgets('grid 形态不调 imageGridBuilder', (tester) async {
    var called = 0;
    final factory = NodeFactory(
      imageGridBuilder: (ctx, node) {
        called++;
        return const Text('X');
      },
      imageContentBuilder: (ctx, image, total) => const SizedBox(),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => factory.buildImageGrid(
            ctx,
            const ImageGridNode(
              id: 'g2',
              columns: 2,
              images: [ImageRun(src: 'a.jpg', indexInPost: 0)],
            ),
          ),
        ),
      ),
    ));
    expect(called, 0); // grid 走内置 Wrap
  });
}