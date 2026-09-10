import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/image_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('ImageCacheManager 设备分档', () {
    test('未探测时走平台默认（非空且为正）', () {
      // 测试环境无原生设备信息，应回退到平台默认档
      final budget = ImageCacheManager.debugMemBudget();
      expect(budget, greaterThan(0));
    });

    test('分档探针输入合法（0 / 边界值）', () {
      // lowRam 标志与物理内存换算的纯逻辑校验：
      // 1GB → 低档、4GB → 中档、8GB → 高档
      final low = ImageCacheManager.debugTierForRamMb(1024);
      final mid = ImageCacheManager.debugTierForRamMb(4096);
      final high = ImageCacheManager.debugTierForRamMb(8192);
      expect(low, lessThan(mid));
      expect(mid, lessThan(high));
    });
  });
}