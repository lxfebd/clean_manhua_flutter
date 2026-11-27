import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/net/self_signed_trust.dart';
import 'package:xingmanxia/playback/playback_buffer_policy.dart';

/// P1-26 / P1-27 验收测试。
///
/// P1-26 验收：「2GB/4GB Android 连续播放 1 小时无 OOM」——真机长跑做不了，
/// 这里验证**分档决策本身**（低内存设备拿到的缓冲确实更小、桌面确实更大、
/// 任何档位都不低于 64MB 的可用性底线）。
///
/// P1-27 验收：「HTTP WebDAV/HTTP 备份认证出网前失败；NAS 指纹匹配可用、
/// 错误指纹失败；开启 NAS 例外后访问 GitHub 仍拒绝伪造证书」
/// 40 位十六进制假指纹（SHA-1 长度）。
const String fp40 = 'abcdef0123456789abcdef0123456789abcdef01';
const String fpAabb = 'aabbccddaabbccddaabbccddaabbccddaabbccdd';

void main() {
  group('P1-26 播放缓冲分档', () {
    setUp(() => PlaybackBufferPolicy.testReset());
    tearDown(() => PlaybackBufferPolicy.testReset());

    test('档位字节数符合预期', () {
      expect(PlaybackBufferPolicy.bytesFor(PlaybackBufferTier.mobileLow),
          64 * 1024 * 1024);
      expect(PlaybackBufferPolicy.bytesFor(PlaybackBufferTier.mobileNormal),
          128 * 1024 * 1024);
      expect(PlaybackBufferPolicy.bytesFor(PlaybackBufferTier.mobileHigh),
          192 * 1024 * 1024);
      expect(PlaybackBufferPolicy.bytesFor(PlaybackBufferTier.desktop),
          256 * 1024 * 1024);
    });

    test('任何档位都不低于 64MB（可用性底线）', () {
      for (final t in PlaybackBufferTier.values) {
        expect(PlaybackBufferPolicy.bytesFor(t),
            greaterThanOrEqualTo(64 * 1024 * 1024),
            reason: '$t 低于 64MB 会让慢源首播失败率明显上升——'
                '那是把 OOM 风险换成了"根本播不了"，更糟');
      }
    });

    test('移动端档位都小于桌面档位（不再一刀切）', () {
      final desktop = PlaybackBufferPolicy.bytesFor(PlaybackBufferTier.desktop);
      for (final t in [
        PlaybackBufferTier.mobileLow,
        PlaybackBufferTier.mobileNormal,
        PlaybackBufferTier.mobileHigh,
      ]) {
        expect(PlaybackBufferPolicy.bytesFor(t), lessThan(desktop),
            reason: '旧实现全平台统一 256MB，移动端与桌面必须区分');
      }
    });

    test('未解析时默认标准档（不退化到最低档）', () {
      PlaybackBufferPolicy.testReset();
      expect(PlaybackBufferPolicy.tier, PlaybackBufferTier.mobileNormal,
          reason: '读不到设备信息时不该把桌面端也降到 64MB');
    });

    test('档位文案是中文且含容量', () {
      for (final t in PlaybackBufferTier.values) {
        PlaybackBufferPolicy.testSetTier(t);
        expect(PlaybackBufferPolicy.tierLabel, contains('MB'));
      }
    });
  });

  group('P1-27 自签信任：按主机 + 指纹', () {
    setUp(() => SelfSignedTrust.testReset());
    tearDown(() => SelfSignedTrust.testReset());

    test('没有规则时不设 badCertificateCallback', () {
      expect(SelfSignedTrust.callbackFor(), isNull,
          reason: '没有规则就应该走 dart:io 标准校验，不设回调');
    });

    test('GitHub 等下发通道永远严格，即使登记也不放行', () {
      // 关键验收项：开启 NAS 例外后，GitHub 仍必须严格校验。
      const strictHosts = [
        'github.com',
        'api.github.com',
        'objects.githubusercontent.com',
        'raw.githubusercontent.com',
      ];
      for (final h in strictHosts) {
        expect(isAlwaysStrictHost(h), isTrue, reason: '$h 必须永久严格');
        // 即使硬塞一条规则
        SelfSignedTrust.replaceAll([
          SelfSignedTrustRule(host: h, fingerprint: fp40),
        ]);
        expect(SelfSignedTrust.rules, isEmpty,
            reason: '$h 的规则必须被丢弃，不能进入生效集合');
        expect(SelfSignedTrust.hasRuleFor(h), isFalse);
      }
    });

    test('GitHub 子域也严格', () {
      expect(isAlwaysStrictHost('release-assets.github.com'), isTrue);
      expect(isAlwaysStrictHost('my.github.com'), isTrue);
    });

    test('未登记的主机不放行', () {
      SelfSignedTrust.replaceAll([
        SelfSignedTrustRule(host: 'nas.local', fingerprint: fp40),
      ]);
      expect(SelfSignedTrust.hasRuleFor('nas.local'), isTrue);
      expect(SelfSignedTrust.hasRuleFor('other.local'), isFalse);
      // 未登记主机不应拿到 onBadCertificate
      expect(
          SelfSignedTrust.onBadCertificateForHost('other.local'), isNull);
    });

    test('永久严格主机拿不到 onBadCertificate', () {
      SelfSignedTrust.replaceAll([
        SelfSignedTrustRule(host: 'github.com', fingerprint: fp40),
      ]);
      expect(SelfSignedTrust.onBadCertificateForHost('github.com'), isNull);
    });

    test('指纹归一：冒号/前缀/大小写都能兼容', () {
      final a = normalizeFingerprint('AB:CD:EF:01');
      final b = normalizeFingerprint('abcdef01');
      final c = normalizeFingerprint('SHA-1: AB CD EF 01');
      expect(a, 'abcdef01');
      expect(b, 'abcdef01');
      expect(c, 'abcdef01');
    });

    test('规则序列化往返一致', () {
      SelfSignedTrust.replaceAll([
        const SelfSignedTrustRule(
            host: 'nas.local', fingerprint: fpAabb),
      ]);
      final json = SelfSignedTrust.toJson();
      expect(json.length, 1);
      expect(json.first['host'], 'nas.local');
      final parsed = SelfSignedTrustRule.tryParse(json.first);
      expect(parsed, isNotNull);
      expect(parsed!.host, 'nas.local');
    });

    test('单条坏数据跳过，不影响其它规则', () {
      expect(SelfSignedTrustRule.tryParse(null), isNull);
      expect(SelfSignedTrustRule.tryParse('str'), isNull);
      expect(SelfSignedTrustRule.tryParse({'host': ''}), isNull);
      expect(SelfSignedTrustRule.tryParse({'host': 'a', 'fingerprint': ''}),
          isNull);
      expect(
          SelfSignedTrustRule.tryParse(
              {'host': 'ok.local', 'fingerprint': 'ab'}),
          isNotNull);
    });
  });

  group('P1-27 Android 明文策略（配置检查）', () {
    String readFile(String p) {
      try {
        return File(p).readAsStringSync();
      } catch (_) {
        return '';
      }
    }

    test('主 manifest 不再全局放开明文', () {
      final m = readFile('android/app/src/main/AndroidManifest.xml');
      expect(m.isNotEmpty, isTrue, reason: '找不到主 manifest');
      expect(m.contains('android:usesCleartextTraffic="true"'), isFalse,
          reason: '全局明文在 P1-27 后必须收回');
      expect(m.contains('android:usesCleartextTraffic="false"'), isTrue);
      expect(m.contains('android:networkSecurityConfig='), isTrue,
          reason: '必须指向 Network Security Config');
    });

    test('Network Security Config 默认禁明文，只白名单有据可查的域', () {
      final xml = readFile(
          'android/app/src/main/res/xml/network_security_config.xml');
      expect(xml.isNotEmpty, isTrue, reason: '找不到 network_security_config');
      expect(xml.contains('cleartextTrafficPermitted="false"'), isTrue,
          reason: 'base-config 必须默认禁明文');
      // 白名单里只允许 dainyew.com（鞍山影院，HTTPS 已失效，有记录）
      final domains = RegExp(r'<domain[^>]*>([^<]+)</domain>')
          .allMatches(xml)
          .map((m) => m.group(1)!.trim())
          .toSet();
      expect(domains, isNotEmpty, reason: '至少应有 dainyew 白名单');
      for (final d in domains) {
        expect(d.contains('dainyew'), isTrue,
            reason: '白名单里出现了未评估的域名：$d。'
                '加白名单必须有"该站确实没有 HTTPS"的记录，见文件内注释。');
      }
    });

    test('主 manifest 保留自更新所需的两项权限（GitHub 侧载分发）', () {
      // 本项目只在 GitHub Release 侧载分发、不上架应用商店，
      // 所以这两项权限是**功能必需**，不能删：
      // - REQUEST_INSTALL_PACKAGES：应用内自更新
      // - USE_FULL_SCREEN_INTENT：下载完成后直接弹安装界面
      // 若将来要上架商店，再引入 flavor 拆分（届时需同时改 CI 的 APK 路径）。
      final m = readFile('android/app/src/main/AndroidManifest.xml');
      expect(m.contains('REQUEST_INSTALL_PACKAGES'), isTrue);
      expect(m.contains('USE_FULL_SCREEN_INTENT'), isTrue);
    });
  });

  group('P1-28 安装能力探测与降级', () {
    String readFile(String p) {
      try {
        return File(p).readAsStringSync();
      } catch (_) {
        return '';
      }
    }

    test('Kotlin 安装路径有能力探测 + 降级（不再直接崩）', () {
      final k = readFile(
          'android/app/src/main/kotlin/com/xingmanxia/app/MainActivity.kt');
      expect(k.isNotEmpty, isTrue);
      expect(k.contains('canRequestPackageInstalls'), isTrue,
          reason: '必须探测「安装未知应用」权限——用户没开时直接调安装 Intent '
              '会抛 ActivityNotFoundException，表现为点更新后闪退');
      expect(k.contains('canInstallPackages'), isTrue,
          reason: '必须抽成一个判断函数，供安装与全屏通知两处复用');
      expect(k.contains('ActivityNotFoundException'), isTrue,
          reason: '极简 ROM 可能连安装器都没有，必须 catch 住');
    });

    test('每一处全屏 Intent 都受安装能力约束', () {
      final k = readFile(
          'android/app/src/main/kotlin/com/xingmanxia/app/MainActivity.kt');
      // 逐行扫：凡是**实际调用** setFullScreenIntent 的行（排除注释），
      // 其前 6 行内必须出现 canInstallPackages 判断。
      final lines = k.split('\n');
      var checked = 0;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (!line.contains('setFullScreenIntent')) continue;
        if (line.startsWith('//') || line.startsWith('*')) continue;
        checked++;
        final ctx = lines.sublist(i > 6 ? i - 6 : 0, i + 1).join('\n');
        expect(ctx.contains('canInstallPackages()'), isTrue,
            reason: '第 ${i + 1} 行的 setFullScreenIntent 没有被 '
                'canInstallPackages() 守护。用户没开「未知来源」时，'
                'Android 14+ 会拒绝并可能让用户看到一次失败的弹窗。');
      }
      expect(checked, greaterThanOrEqualTo(2),
          reason: '应有两处全屏 Intent（下载完成通知 + 更新通知），'
              '实际找到 $checked 处——若确实减少了，同步更新本断言');
    });

    test('项目只在 GitHub 发布：不应残留商店渠道配置', () {
      // 本项目定位是 GitHub Release 侧载分发，不上架应用商店。
      // 因此不应存在 flavor 拆分 / store manifest —— 那些只会引入
      // 「CI 报错、APK 路径变化、选错架构」三类风险而无收益。
      final g = readFile('android/app/build.gradle.kts');
      expect(g.contains('productFlavors'), isFalse,
          reason: 'flavor 拆分只服务于商店渠道，本项目用不上');
      expect(File('android/app/src/store').existsSync(), isFalse,
          reason: '不应存在 store 渠道的 manifest 覆盖层');
    });
  });
}

