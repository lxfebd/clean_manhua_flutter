import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/update_checker.dart';

void main() {
  group('UpdateChecker.compareVersions', () {
    test('相同版本返回 0', () {
      expect(UpdateChecker.compareVersions('1.0.0', '1.0.0'), 0);
    });

    test('主版本号优先', () {
      expect(UpdateChecker.compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.9.9', '2.0.0'), lessThan(0));
    });

    test('次版本号', () {
      expect(UpdateChecker.compareVersions('1.2.0', '1.1.9'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.1.9', '1.2.0'), lessThan(0));
    });

    test('修订号', () {
      expect(UpdateChecker.compareVersions('1.0.3', '1.0.2'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.0.2', '1.0.3'), lessThan(0));
    });

    test('忽略 build number (+n)', () {
      expect(UpdateChecker.compareVersions('1.0.0+5', '1.0.0+1'), 0);
    });

    test('非数字兜底为 0', () {
      expect(UpdateChecker.compareVersions('1.0.x', '1.0.0'), 0);
    });
  });

  test('currentVersion 非空', () {
    expect(UpdateChecker.currentVersion(), '1.0.0');
  });
}
