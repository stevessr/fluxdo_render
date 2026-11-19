// golden 测试辅助:给一个 fixture 渲染成 widget 并跟 golden 文件对比。
//
// 用法:
// ```dart
// import 'package:flutter_test/flutter_test.dart';
// import 'golden_framework/golden_helper.dart';
//
// void main() {
//   group('paragraph 节点 golden', () {
//     setUpAll(setUpGoldenTest);
//     for (final fixture in loadByNodeType('paragraph')) {
//       testGoldens(fixture);
//     }
//   });
// }
// ```
//
// 设计点:
// - 用 `flutter_test` 自带的 `matchesGoldenFile`,不自造像素对比
// - 用 `HttpOverrides` 把所有网络请求拦截为占位图(避免 golden 联网不稳定)
// - 用平台 guard,**只在 macOS 上 lock golden**,其他平台 skip
//   (字体渲染差异在不同平台间不可控,但 golden 是检测"代码改动",不是"平台差异")
// - golden 文件路径:test/golden/<node_type>/<fixture_name>.png

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import '../fixtures/_meta/fixture_loader.dart';

/// 在 `main()` 或 `setUpAll` 中调用一次,初始化 golden 环境。
void setUpGoldenTest() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 用占位图替代所有网络图片请求,golden 不联网。
  HttpOverrides.global = _OfflineHttpOverrides();
}

/// 给单个 fixture 跑 golden 对比。
///
/// 默认 viewport 宽度 400px(模拟手机帖子区宽度)。
/// 高度由内容决定 — 用 `tester.view` 设置 surface size 后 `pumpWidget`,再
/// 让 widget 自己撑高,最后 `matchesGoldenFile` 截整 surface。
void testGolden(
  Fixture fixture, {
  double width = 400,
  double height = 1200,
  String? goldenSubPath,
}) {
  testWidgets(
    'golden ${fixture.relativePath}',
    (tester) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                // 关掉动画 → spoiler 等无限动画走静态遮罩(确定 + pumpAndSettle
                // 能 settle,不超时),golden 才稳定。
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: SingleChildScrollView(
                  child: FluxdoRender(
                    cookedHtml: fixture.html,
                    // 确定性 emoji:固定尺寸色块(契约形态 —— builder 按
                    // size 出图,即生产主流)。不注入时离线环境 Image 必
                    // 失败 → fallback 胶囊,胶囊宽度依赖字体/文案,且打破
                    // 「emoji 占位 = size」契约 —— 直绘岛按契约占位,
                    // RichText 按胶囊真实宽占位,双路径 golden 永远对不上。
                    // golden 要验证的是同形态下的排版一致性,不是兜底伪影。
                    emojiImageBuilder: (ctx, emoji, size) => Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        color: const Color(0xFF888888),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // 让 image / async builder 完成
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final goldenPath = goldenSubPath ?? '${fixture.name}.png';
      // matchesGoldenFile 的路径基准是测试 .dart 文件所在目录。
      // 所有 golden 测试约定:测试文件放 test/,golden 文件放 test/golden/。
      await expectLater(
        find.byType(FluxdoRender),
        matchesGoldenFile('golden/$goldenPath'),
      );
    },
    // golden 只在 macOS lock,避免跨平台字体噪音
    skip: !Platform.isMacOS,
  );
}

/// 拦截所有 HTTP 请求,返回 1x1 png 占位图。
class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _OfflineHttpClient();
  }
}

class _OfflineHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return _OfflineHttpClientRequest(url, 'GET');
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _OfflineHttpClientRequest(url, method);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) {}
  @override
  void addProxyCredentials(String host, int port, String realm, HttpClientCredentials credentials) {}
  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) {}
  @override
  set authenticateProxy(Future<bool> Function(String host, int port, String scheme, String? realm)? f) {}
  @override
  set badCertificateCallback(bool Function(X509Certificate cert, String host, int port)? callback) {}
  @override
  set connectionFactory(Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)? f) {}
  @override
  void close({bool force = false}) {}
  @override
  set findProxy(String Function(Uri url)? f) {}
  @override
  set keyLog(Function(String line)? callback) {}
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) => openUrl('DELETE', Uri.parse('http://$host:$port$path'));
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> get(String host, int port, String path) => openUrl('GET', Uri.parse('http://$host:$port$path'));
  @override
  Future<HttpClientRequest> head(String host, int port, String path) => openUrl('HEAD', Uri.parse('http://$host:$port$path'));
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) => openUrl('PATCH', Uri.parse('http://$host:$port$path'));
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) => openUrl('POST', Uri.parse('http://$host:$port$path'));
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) => openUrl('PUT', Uri.parse('http://$host:$port$path'));
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) =>
      openUrl(method, Uri.parse('http://$host:$port$path'));
}

class _OfflineHttpClientRequest implements HttpClientRequest {
  _OfflineHttpClientRequest(this.uri, this.method);
  @override
  final Uri uri;
  @override
  final String method;

  @override
  Future<HttpClientResponse> close() async => _OfflineHttpClientResponse();

  @override
  Future<HttpClientResponse> get done => close();

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  bool bufferOutput = true;
  @override
  int contentLength = -1;
  @override
  Encoding encoding = utf8;
  @override
  bool followRedirects = true;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  HttpHeaders get headers => _NoopHeaders();
  @override
  List<Cookie> get cookies => [];
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}

class _OfflineHttpClientResponse extends Stream<List<int>> implements HttpClientResponse {
  // 一张 1x1 透明 png(89 字节)
  static const _onePixelPng = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ];

  @override
  int get statusCode => 200;
  @override
  int get contentLength => _onePixelPng.length;
  @override
  HttpHeaders get headers {
    final h = _NoopHeaders();
    h.contentType = ContentType('image', 'png');
    return h;
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_onePixelPng]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  X509Certificate? get certificate => null;
  @override
  HttpClientResponseCompressionState get compressionState => HttpClientResponseCompressionState.notCompressed;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  List<Cookie> get cookies => [];
  @override
  Future<Socket> detachSocket() async => throw UnsupportedError('detachSocket');
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => 'OK';
  @override
  Future<HttpClientResponse> redirect([String? method, Uri? url, bool? followLoops]) async => this;
  @override
  List<RedirectInfo> get redirects => [];
}

class _NoopHeaders implements HttpHeaders {
  ContentType? _contentType;
  @override
  ContentType? get contentType => _contentType;
  @override
  set contentType(ContentType? value) => _contentType = value;
  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  bool chunkedTransferEncoding = false;
  @override
  int contentLength = -1;
  @override
  DateTime? date;
  @override
  DateTime? expires;
  @override
  String? host;
  @override
  DateTime? ifModifiedSince;
  @override
  bool persistentConnection = true;
  @override
  int? port;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void clear() {}
  @override
  void forEach(void Function(String name, List<String> values) action) {}
  @override
  void noFolding(String name) {}
  @override
  void remove(String name, Object value) {}
  @override
  void removeAll(String name) {}
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  String? value(String name) => null;
  @override
  List<String>? operator [](String name) => null;
}
