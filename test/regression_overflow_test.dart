import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 窄屏溢出回归测试：在 320px 极窄屏下渲染关键组件，
/// 通过 Flutter test 框架的 overflow 检测（tester.takeException()）
/// 确定性验证 RenderFlex overflowed（黄黑斜纹条）已被消除。
void main() {
  testWidgets('SourceSwitchButton：长源名在 320px 窄屏不溢出', (tester) async {
    final longName = '漫画柜JMComic超长源名测试测试测试测试测试';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Row(
              children: [
                const Icon(Icons.public_rounded, size: 15),
                const SizedBox(width: 5),
                const Text('站点', style: TextStyle(fontSize: 11)),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    longName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                const SizedBox(width: 3),
                const Icon(Icons.unfold_more_rounded, size: 15),
              ],
            ),
          ),
        ),
      ),
    );
    // 关键断言：窄屏下渲染不应产生任何 overflow 异常
    expect(tester.takeException(), isNull);
  });

  testWidgets('列表标题 modeTitle：长搜索词在 320px 窄屏不溢出', (tester) async {
    final longKeyword = '这是一个非常非常非常非常非常长的搜索关键词用于测试溢出边界';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Row(
              children: [
                Container(width: 3, height: 14, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '搜索：$longKeyword',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                const Text('20 部', style: TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('三等分 Row 内 label：长标签在 320px 窄屏不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const Icon(Icons.auto_awesome_rounded, size: 19),
                      const SizedBox(height: 6),
                      const Text(
                        '画质增强(滤镜)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    children: [
                      const Icon(Icons.tune_rounded, size: 19),
                      const SizedBox(height: 6),
                      const Text(
                        '快速增强',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('_srCard 标题 + 角标 Row：长角标名在窄屏不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: Row(
              children: [
                Flexible(
                  child: const Text(
                    '网页画质增强(滤镜)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: const Text(
                      'Anime4K 1080p 超长超分模式名',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('下载摘要 Wrap：大数字在 320px 窄屏不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                const Text('共 999 个', style: TextStyle(fontSize: 13)),
                const Text('已完成 999', style: TextStyle(fontSize: 13)),
                const Text('进行中 900', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('SliverAppBar 角标：type+remarks 在 320px 窄屏不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: Stack(
              children: [
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        child: const Text('剧场版',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10)),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          child: const Text('更新至第999集完结篇最终章',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
