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
}
