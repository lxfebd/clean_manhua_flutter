import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/ui/novel_reader_page.dart';

/// 回归：迭代轮8 小说阅读器补「本章阅读进度」指示条。
///
/// 覆盖 [chapterProgress] 纯函数：
/// - 内容不满一屏（maxScrollExtent <= 0）：算读完 1.0；
/// - 顶部：0.0；
/// - 中间：offset / maxScrollExtent；
/// - 越界值夹到 [0,1]。
void main() {
  test('内容不满一屏：算读完', () {
    expect(chapterProgress(0, 0), 1.0);
    expect(chapterProgress(10, 0), 1.0);
    expect(chapterProgress(0, -5), 1.0);
  });

  test('顶部：进度 0', () {
    expect(chapterProgress(0, 1000), 0.0);
  });

  test('中间：offset / maxScrollExtent', () {
    expect(chapterProgress(500, 1000), 0.5);
    expect(chapterProgress(250, 1000), 0.25);
  });

  test('offset 超过 maxScrollExtent：夹到 1.0', () {
    expect(chapterProgress(1500, 1000), 1.0);
  });

  test('offset 为负（极端）：夹到 0.0', () {
    expect(chapterProgress(-100, 1000), 0.0);
  });
}
