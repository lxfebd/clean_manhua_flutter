import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/smart_prefetch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('SmartPrefetch 策略', () {
    setUp(() => SmartPrefetch.resetCache());
    tearDown(() => SmartPrefetch.resetCache());

    test('Wi-Fi 深度预取（当前章 5 页、下章 5 页）', () {
      expect(SmartPrefetch.chapterDepth(NetKind.wifi), 5);
      expect(SmartPrefetch.nextChapterDepth(NetKind.wifi), 5);
    });

    test('蜂窝网络轻量预取（2 页）', () {
      expect(SmartPrefetch.chapterDepth(NetKind.cellular), 2);
      expect(SmartPrefetch.nextChapterDepth(NetKind.cellular), 2);
    });

    test('无网络不预取（0 页）', () {
      expect(SmartPrefetch.chapterDepth(NetKind.none), 0);
      expect(SmartPrefetch.nextChapterDepth(NetKind.none), 0);
    });

    test('探测失败按保守策略（2 页）', () {
      expect(SmartPrefetch.chapterDepth(NetKind.unknown), 2);
      expect(SmartPrefetch.nextChapterDepth(NetKind.unknown), 2);
    });

    test('未探测时回退旧默认（当前 3 页、下章 2 页），保证首章体验不退步', () {
      expect(SmartPrefetch.cachedNetwork(), isNull);
      expect(SmartPrefetch.chapterDepth(null), 3);
      expect(SmartPrefetch.nextChapterDepth(null), 2);
    });
  });
}