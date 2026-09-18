import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/link_text.dart';

void main() {
  test('显示解码中文与反斜杠，但保留会改变链接语义的编码', () {
    expect(
      displayLinkText('https://example.com/%E4%B8%AD%E6%96%87'),
      'https://example.com/中文',
    );
    expect(displayLinkText('https://github.com/%5C'), r'https://github.com/\');
    for (final suffix in [
      'a%20b',
      'a%2Fb',
      '%3Fq%3D1',
      '%FF',
      '%25',
      'a%C2%A0b',
      'a%E2%80%A8b',
      '%EF%BF%BC',
      '%E2%80%8B',
    ]) {
      final url = 'https://example.com/$suffix';
      expect(displayLinkText(url), url);
    }
  });

  test('编辑后的目标编码保留百分号和反斜杠语义', () {
    expect(
      encodeLinkTarget(r'https://example.com/中文\a%2Fb'),
      'https://example.com/%E4%B8%AD%E6%96%87%5Ca%2Fb',
    );
  });

  test('裸链判定不把保留字符或协议差异当等价', () {
    expect(
      isBareLinkText(
        r'https://github.com/\',
        'https://github.com/%5C',
        allowDecoded: true,
      ),
      isTrue,
    );
    expect(
      isBareLinkText(
        'example.com/中文',
        'http://example.com/%E4%B8%AD%E6%96%87',
        allowDecoded: true,
      ),
      isTrue,
    );
    expect(isBareLinkText('example.com', 'https://example.com'), isFalse);
    expect(
      isBareLinkText('https://example.com/a/b', 'https://example.com/a%2Fb'),
      isFalse,
    );
    expect(isBareLinkText('标题', 'https://example.com'), isFalse);
  });
}
