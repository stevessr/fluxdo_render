// 真实 bundle DTO 的日期与常用样式回归，不以源码回退冒充支持。
import 'dart:convert';
import 'helpers/semantic_token_fixture.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  final fixtures = jsonDecode(File('test/fixtures/audit_token_matrix.json').readAsStringSync()) as Map<String, dynamic>;
  for (final key in ['dateRecurring', 'dateCountdown', 'dateRange', 'bbBold', 'bbItalic', 'htmlUnderline', 'spoilerInline']) {
    test('真实 token 可编辑：$key', () {
      final dto = Map<String, dynamic>.from(fixtures[key] as Map);
      final document = parseSemanticFixture(dto);
      final back = serializeSemanticFixture(document);
      expect(back, isNot(contains('```')));
      if (key == 'dateRecurring') expect(back, contains('recurring="1.months"'));
      if (key == 'dateCountdown') { expect(back, contains('countdown="false"')); expect(back, isNot(contains('countdown="true"'))); }
      if (key == 'dateRange') { expect(back, contains('[date-range from=2027-03-12 to=2027-03-15')); expect(back, isNot(contains('→'))); }
      if (key == 'bbBold') expect(back, contains('[b]mock[/b]'));
      if (key == 'bbItalic') expect(back, contains('[i]mock[/i]'));
      if (key == 'htmlUnderline') expect(back, contains('<u>mock</u>'));
      if (key == 'spoilerInline') expect(back, contains('[spoiler]mock[/spoiler]'));
    });
  }
  test('日期原子编辑正文后保留所有隐藏属性', () {
    const date = LocalDateRun(date: '2027-03-12', fallbackText: '日期', recurring: '1.months', countdownRaw: 'false', endDate: '2027-03-15', endTime: '12:34:56');
    final content = EditableTextContent.fromInlines(const [date]);
    final edited = content.insert(0, '新增');
    expect(edited.toInlines().whereType<LocalDateRun>().single, date);
    expect(date, isNot(const LocalDateRun(date: '2027-03-12', fallbackText: '日期')));
  });
  for (final key in ['htmlEmpty', 'htmlNestedSize', 'htmlNested']) {
    test('不可表示的 HTML 明确保源：$key', () {
      final dto = Map<String, dynamic>.from(fixtures[key] as Map);
      final document = parseSemanticFixture(dto);
      expect(serializeSemanticFixture(document), dto['raw']);
    });
  }
}
