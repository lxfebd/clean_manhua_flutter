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

  test('Android 平台选中 apk 附件', () {
    final assets = [
      {'name': 'app-release.apk', 'browser_download_url': 'https://x/app.apk'},
      {
        'name': 'xingmanxia-windows-1.4.1.zip',
        'browser_download_url': 'https://x/win.zip',
      },
    ];
    final picked = UpdateChecker.pickAssetForPlatform(assets, platformKey: '');
    expect(picked, isNotNull);
    expect(picked!.name, 'app-release.apk');
  });

  test('Windows 平台选中 windows zip，而非 apk', () {
    final assets = [
      {'name': 'app-release.apk', 'browser_download_url': 'https://x/app.apk'},
      {
        'name': 'xingmanxia-windows-1.4.1.zip',
        'browser_download_url': 'https://x/win.zip',
      },
    ];
    final picked = UpdateChecker.pickAssetForPlatform(
      assets,
      platformKey: '-windows',
    );
    expect(picked, isNotNull);
    expect(picked!.name, 'xingmanxia-windows-1.4.1.zip');
  });

  test('macOS 平台选中 macos dmg', () {
    final assets = [
      {'name': 'app-release.apk', 'browser_download_url': 'https://x/app.apk'},
      {
        'name': 'xingmanxia-macos-1.4.1.dmg',
        'browser_download_url': 'https://x/mac.dmg',
      },
    ];
    final picked = UpdateChecker.pickAssetForPlatform(
      assets,
      platformKey: '-macos',
    );
    expect(picked, isNotNull);
    expect(picked!.name, 'xingmanxia-macos-1.4.1.dmg');
  });

  test('平台无匹配附件时返回 null', () {
    final assets = [
      {'name': 'app-release.apk', 'browser_download_url': 'https://x/app.apk'},
    ];
    final picked = UpdateChecker.pickAssetForPlatform(
      assets,
      platformKey: '-windows',
    );
    expect(picked, isNull);
  });

  group('UpdateChecker.parseReleasePageAssets（API 403 降级解析）', () {
    const html = '''
<!DOCTYPE html>
<html><head><title>Releases · lxfebd/clean_manhua_flutter</title></head>
<body>
<a href="/lxfebd/clean_manhua_flutter/releases/tag/v1.5.1">v1.5.1</a>
<a href="/lxfebd/clean_manhua_flutter/releases/download/v1.5.1/app-release.apk">app-release.apk</a>
<a href="/lxfebd/clean_manhua_flutter/releases/download/v1.5.1/xingmanxia-windows-1.5.1-setup.exe">setup.exe</a>
<a href="/lxfebd/clean_manhua_flutter/releases/download/v1.5.1/xingmanxia-windows-1.5.1.zip">zip</a>
<a href="/lxfebd/clean_manhua_flutter/releases/tag/v1.4.0">old</a>
</body>
</html>''';

    test('解析出全部附件（含路径片段，URL 与网页一致）', () {
      final assets = UpdateChecker.parseReleasePageAssets(html);
      expect(assets.length, 3);
      final names = assets.map((a) => a['name']).toList();
      expect(
        names,
        containsAll([
          'app-release.apk',
          'xingmanxia-windows-1.5.1-setup.exe',
          'xingmanxia-windows-1.5.1.zip',
        ]),
      );
      final exe = assets.firstWhere(
        (a) => a['name'] == 'xingmanxia-windows-1.5.1-setup.exe',
      );
      expect(
        exe['browser_download_url'],
        'https://github.com/lxfebd/clean_manhua_flutter/releases/download/'
        'v1.5.1/xingmanxia-windows-1.5.1-setup.exe',
      );
    });

    test('Windows 下优先选 exe 附件', () {
      final assets = UpdateChecker.parseReleasePageAssets(html);
      final picked = UpdateChecker.pickAssetForPlatform(
        assets,
        platformKey: '-windows',
        prefer: '.exe',
      );
      expect(picked, isNotNull);
      expect(picked!.name, 'xingmanxia-windows-1.5.1-setup.exe');
    });

    test('重复链接去重', () {
      final assets = UpdateChecker.parseReleasePageAssets(
        '<a href="/lxfebd/clean_manhua_flutter/releases/download/v1.5.1/a.apk">a</a>'
        '<a href="/lxfebd/clean_manhua_flutter/releases/download/v1.5.1/a.apk">a</a>',
      );
      expect(assets.length, 1);
    });

    test('无附件 HTML 返回空列表（不抛异常）', () {
      expect(
        UpdateChecker.parseReleasePageAssets('<html>no assets</html>'),
        isEmpty,
      );
    });
  });
}
