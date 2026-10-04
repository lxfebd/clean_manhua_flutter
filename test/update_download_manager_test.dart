import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/update_checker.dart';
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

  group('_mirrorCandidates（镜像下载候选 + 双层前缀防御）', () {
    const githubUrl =
        'https://github.com/lxfebd/clean_manhua_flutter/'
        'releases/download/v1.5.3/app-release.apk';

    test('裸 GitHub URL：前缀镜像在前，直连在链尾', () {
      final c = mirrorCandidates(githubUrl);
      expect(c.length, UpdateChecker.githubMirrors.length);
      // 链首是第一个镜像前缀 + 原 URL
      expect(c.first.url, '${UpdateChecker.githubMirrors.first}$githubUrl');
      expect(c.first.label, '镜像0');
      // 链尾是直连（空前缀）
      expect(c.last.url, githubUrl);
      expect(c.last.label, '直连');
    });

    test('已带镜像前缀的 URL（检查端 HTML 降级产物）：前缀只拼一层，不叠双层', () {
      final mirrored = '${UpdateChecker.githubMirrors.first}$githubUrl';
      final c = mirrorCandidates(mirrored);
      // 第一候选直接复用镜像 URL，不再拼第二层前缀
      expect(c.first.url, mirrored);
      expect(c.first.label, '镜像(已选)');
      // 第二候选是剥掉前缀的 GitHub 原 URL（直连兜底）
      expect(c[1].url, githubUrl);
      expect(c[1].label, '直连');
      // 无任何候选带着双层前缀
      for (final x in c) {
        expect(
          x.url.contains('${UpdateChecker.githubMirrors.first}'
              '${UpdateChecker.githubMirrors.first}'),
          isFalse,
          reason: '不允许镜像前缀叠加：${x.url}',
        );
      }
    });

    test('URL 恰为某个镜像前缀本身：剥前缀后为空则仅一个候选', () {
      final c = mirrorCandidates(UpdateChecker.githubMirrors.first);
      expect(c.length, 1);
      expect(c.first.url, UpdateChecker.githubMirrors.first);
      expect(c.first.label, '镜像(已选)');
    });
  });
}
