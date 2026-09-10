import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/image_cache.dart';

/// 性能项「内存动态适配」回归：磁盘缓存预算随设备内存档位缩放。
/// 低端机收紧省存储，高端机放开提升连读流畅度；默认（未探测）保持原值。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ImageCacheManager 磁盘预算动态适配', () {
    test('默认（未探测）磁盘预算保持原 512MB', () {
      expect(ImageCacheManager.debugDiskBudget(), 512 * 1024 * 1024);
    });

    test('探测分档后磁盘预算与内存档位单调（低<中<高）', () {
      // 分档边界与 debugTierForRamMb 一致：24MB→128MB、40MB→256MB、64MB→512MB
      final budgets = [
        ImageCacheManager.debugDiskBudgetForTier(24 * 1024 * 1024),
        ImageCacheManager.debugDiskBudgetForTier(40 * 1024 * 1024),
        ImageCacheManager.debugDiskBudgetForTier(64 * 1024 * 1024),
      ];
      expect(budgets[0], lessThan(budgets[1]));
      expect(budgets[1], lessThan(budgets[2]));
      expect(budgets[0], 128 * 1024 * 1024);
      expect(budgets[2], 512 * 1024 * 1024);
    });

    test('内存预算与磁盘预算联动合理（磁盘远大于内存）', () {
      final memLow = ImageCacheManager.debugTierForRamMb(1024);
      final diskLow = ImageCacheManager.debugDiskBudgetForTier(memLow);
      // 磁盘是内存的 5 倍以上，保证连读时磁盘能承接换出的图片
      expect(diskLow >= memLow * 5, isTrue);
    });
  });
}
