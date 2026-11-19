import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  group('attachment widget 渲染 + tap', () {
    testWidgets('附件渲染下载图标 + 文件名,tap 调 onDownloadAttachment 带 filename',
        (tester) async {
      String? tappedHref;
      String? tappedFilename;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FluxdoRender(
            cookedHtml:
                '<p><a class="attachment" href="/uploads/default/1X/abc.pdf">报告.pdf</a> (1.2 MB)</p>',
            selectionEnabled: false,
            onDownloadAttachment: (ctx, href, filename) {
              tappedHref = href;
              tappedFilename = filename;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // 下载图标存在
      expect(find.byIcon(Icons.save_alt), findsOneWidget);
      // 点击图标触发下载回调(带 filename)
      await tester.tap(find.byIcon(Icons.save_alt));
      await tester.pump();
      expect(tappedHref, '/uploads/default/1X/abc.pdf');
      expect(tappedFilename, '报告.pdf');
    });

    testWidgets('未注入 onDownloadAttachment 时降级到 linkHandler', (tester) async {
      String? linkTapped;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FluxdoRender(
            cookedHtml:
                '<p><a class="attachment" href="/uploads/default/1X/abc.pdf">f.pdf</a></p>',
            selectionEnabled: false,
            linkHandler: (ctx, href) => linkTapped = href,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.save_alt));
      await tester.pump();
      expect(linkTapped, '/uploads/default/1X/abc.pdf');
    });
  });
}
