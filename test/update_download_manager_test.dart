import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/update_download_manager.dart';

void main() {
  group('fallbackFileName（附件名缺失时兜底文件名）', () {
    test('exe 链接推断为 .exe（Windows 可触发自动安装）', () {
      final name = fallbackFileName(
        'https://github.com/lxfebd/clean_manhua_flutter/releases/download/'
            'v1.5.1/xingmanxia-windows-1.5.1-setup.exe',
        '-windows',
      );
      expect(name, 'xingmanxia_update-windows.exe');
    });

    test('zip 链接推断为 .zip', () {
      final name = fallbackFileName(
        'https://github.com/lxfebd/clean_manhua_flutter/releases/download/'
            'v1.5.1/xingmanxia-windows-1.5.1.zip',
        '-windows',
      );
      expect(name, 'xingmanxia_update-windows.zip');
    });

    test('apk 链接推断为 .apk', () {
      final name = fallbackFileName(
        'https://github.com/lxfebd/clean_manhua_flutter/releases/download/'
            'v1.5.1/app-release.apk',
        '',
      );
      expect(name, 'xingmanxia_update.apk');
    });

    test('URL 无扩展名时兜底 .apk', () {
      final name = fallbackFileName('https://example.com/download', '');
      expect(name, 'xingmanxia_update.apk');
    });

    test('平台关键字拼入文件名', () {
      final name = fallbackFileName(
        'https://github.com/lxfebd/clean_manhua_flutter/releases/download/'
            'v1.5.1/app-release.apk',
        '-windows',
      );
      expect(name, 'xingmanxia_update-windows.apk');
    });
  });

  group('updateTagFromUrl（按 release tag 分目录隔离版本）', () {
    test('GitHub releases 直链提取 tag（去 v 前缀）', () {
      expect(
        updateTagFromUrl(
          'https://github.com/lxfebd/clean_manhua_flutter/releases/download/'
              'v1.5.1/xingmanxia-windows-1.5.1-setup.exe',
        ),
        'v1.5.1',
      );
    });

    test('镜像前缀不影响 tag 提取（镜像保留原路径）', () {
      expect(
        updateTagFromUrl(
          'https://ghproxy.net/https://github.com/lxfebd/clean_manhua_flutter/'
              'releases/download/v1.5.2/app-release.apk',
        ),
        'v1.5.2',
      );
    });

    test('无 /releases/download/ 的普通链接返回 null', () {
      expect(updateTagFromUrl('https://example.com/download/app.apk'), isNull);
    });

    test('tag 非法字符被替换，防路径注入', () {
      expect(updateTagFromUrl('a/releases/download/v1.0.0..a/x.apk'), 'v1.0.0..a');
      expect(updateTagFromUrl('x/releases/download/v1/../a.apk'), 'v1');
    });
  });

  group('contentRangeStart / contentRangeTotal（续传位置校验）', () {
    test('解析 206 的起始字节与总大小', () {
      expect(contentRangeStart('bytes 0-499/5000'), 0);
      expect(contentRangeTotal('bytes 0-499/5000'), 5000);
      expect(contentRangeStart('bytes 1024-2047/8192'), 1024);
      expect(contentRangeTotal('bytes 1024-2047/8192'), 8192);
    });

    test('解析失败返回空安全值（start=-1, total=0）', () {
      expect(contentRangeStart('not-a-range'), -1);
      expect(contentRangeStart(''), -1);
      expect(contentRangeTotal('bytes 0-499'), 0);
      expect(contentRangeTotal(''), 0);
    });
  });
}
