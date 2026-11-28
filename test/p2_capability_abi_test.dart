import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/capabilities/capability_runtime.dart';

/// P2-11：桌面 ABI 必须精确到 OS + 架构，不能「任意桌面键都行」。
void main() {
  group('桌面 ABI 精确键', () {
    test('Windows x64 / ARM64 各自映射', () {
      expect(CapabilityRuntime.desktopAbiKey('windows', 'AMD64'), 'windows-x64');
      expect(CapabilityRuntime.desktopAbiKey('windows', 'arm64'), 'windows-arm64');
      expect(CapabilityRuntime.desktopAbiKey('windows', 'x86_64'), 'windows-x64');
    });

    test('macOS / Linux 的 uname 输出映射', () {
      expect(CapabilityRuntime.desktopAbiKey('macos', 'x86_64'), 'macos-x64');
      expect(CapabilityRuntime.desktopAbiKey('macos', 'arm64'), 'macos-arm64');
      expect(CapabilityRuntime.desktopAbiKey('linux', 'aarch64'), 'linux-arm64');
      expect(CapabilityRuntime.desktopAbiKey('linux', 'amd64'), 'linux-x64');
    });

    test('未知架构 fail-fast，不猜桌面通用键', () {
      expect(CapabilityRuntime.desktopAbiKey('windows', null), isNull);
      expect(CapabilityRuntime.desktopAbiKey('windows', ''), isNull);
      expect(CapabilityRuntime.desktopAbiKey('windows', 'x86'), isNull,
          reason: '不认识的架构必须拒绝，而不是默认给 x64 构件');
      expect(CapabilityRuntime.desktopAbiKey('windows', 'mips'), isNull);
      expect(CapabilityRuntime.desktopAbiKey('android', 'arm64'), isNull,
          reason: 'Android 走自己的 ABI 分支，不该被桌面键兜底');
    });
  });
}
