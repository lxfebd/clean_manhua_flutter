import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/ui/responsive.dart';

void main() {
  group('补帧/超分桌面门闸判定方向（DesktopUi）', () {
    test('Windows 桌面：isDesktopPlatform 为真（门闸放行）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        expect(DesktopUi.isDesktopPlatform, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('macOS 桌面：为真', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        expect(DesktopUi.isDesktopPlatform, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('Android 移动端：为假（门闸短路，UI 不展示入口）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        expect(DesktopUi.isDesktopPlatform, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('iOS 移动端：为假', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(DesktopUi.isDesktopPlatform, isFalse);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('覆盖复位后回归默认（VM 上通常非桌面）', () {
      expect(DesktopUi.isDesktopPlatform, isFalse);
    });
  });
}