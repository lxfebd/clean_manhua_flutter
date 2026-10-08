import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/widgets/chapter_list_sheet.dart';

/// 回归：迭代轮10 小说章节目录打开后自动定位到当前章。
///
/// 覆盖 [tocTargetOffset] 纯函数（dense ListTile 约 56px 高）：
/// - 目标偏移 = idx*56 - 视口*0.4（当前章滚到可视区中间偏上）；
/// - 顶部章节不越界（clamp 回 0）；
/// - 末尾章节 clamp 到 maxScrollExtent。
void main() {
  test('中部章节：滚到可视区中间偏上', () {
    // idx=50，视口 800：50*56 - 800*0.4 = 2800-320 = 2480
    expect(tocTargetOffset(50, 800, 100000), 2480);
  });

  test('顶部章节：clamp 回 0', () {
    expect(tocTargetOffset(0, 800, 100000), 0.0);
    // idx=3 在小视口下也可能算出负值 → 0
    expect(tocTargetOffset(3, 800, 100000), 0.0); // 168-320 < 0
  });

  test('末尾章节：clamp 到 maxScrollExtent', () {
    expect(tocTargetOffset(199, 800, 10000), 10000.0);
  });

  test('内容不满屏（maxExtent 很小）：clamp 不越界', () {
    // 560-320=240，maxExtent 500 不截断
    expect(tocTargetOffset(10, 800, 500), 240.0);
    // 但极端大 idx 仍会被 maxExtent 截断
    expect(tocTargetOffset(199, 800, 500), 500.0);
  });
}