import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/http_client.dart';
import 'package:xingmanxia/sources/dsl/source_market.dart';
import 'package:xingmanxia/utils/index_signature.dart';
import 'package:xingmanxia/utils/market_index_urls.dart';

/// 远端**已发布**索引的实时校验：用源市场自己的取数路径（主地址 + jsDelivr 镜像
/// 回退）拉 index.json，再走 [SourceMarket.parseIndex] 解析。
///
/// 为什么需要：市场索引是手工合并文本的（缩进/逗号写错就整份坏掉），而 App 侧
/// 对坏条目是「跳过并记日志」——坏条目不会崩市场，但会**静默消失**，用户看到
/// 的源市场少几个源。这条测试直接对着线上文件跑，把「发布出去但装不上」这类
/// 事故变成红灯。
///
/// CI 不出网：仅当 `XM_LIVE=1` 时执行。
/// `$env:XM_LIVE=1; flutter test test/market_live_index_test.dart`
void main() {
  final liveOn = (Platform.environment['XM_LIVE'] ?? '').trim() == '1';
  final skip = liveOn ? null : '设置 XM_LIVE=1 才拉线上索引';

  test('线上源市场索引：可拉取、条目全部通过校验', () async {
    // 用市场自己的地址候选与超时，测的就是 App 实际会走的那条路
    final bytes = await Net.getBytesMirrors(kMarketIndexUrls,
        timeout: kMarketIndexTimeout,
        totalTimeout: kMarketIndexTotalTimeout);
    final text = utf8.decode(bytes);

    // 线上索引必须已签名且验签通过：这条断言闭合「发布流程真的签了名」。
    // 只要有人改了 index.json 没重签就 push，这里立刻红——而不是等真机
    // 市场靠 checkIndexOrTrust 打一条没人看的 debugPrint。
    expect(verifyIndexSignature(text), IndexSignatureStatus.valid,
        reason: '线上索引未签名或验签失败：发布时漏跑 tool/sign_index.dart，'
            '或内容被篡改');

    final entries = SourceMarket.parseIndex(text);

    // 线上至少要有这些源（缺一个就是发布事故/源站下线被跳过）。
    // ashan_yy（鞍山影院）**不在此列**：它已从**市场索引**下架——其 CDN 对任何
    // 带 SNI 的 TLS 握手直接 RST，浏览器同样进不去（见 da4e2b5 提交记录）。
    // 注意它仍作为**内置 DSL 孪生源**保留在 App 里（sources/ashan_yy.json，
    // restorePlugins 会注册），所以这里断言的是「市场」而非「内置」。
    const required = [
      'wche_dm',
      'shuhaige_novel',
      'miaobige_novel',
      'quanben5_novel',
      'manhuawang_comic',
      'manhuady_comic',
    ];
    final ids = entries.map((e) => e.def.id).toSet();
    for (final id in required) {
      expect(ids, contains(id), reason: '线上索引缺少 $id：该源在市场里不可见');
    }
    for (final e in entries) {
      expect(e.def.validate(), isEmpty, reason: '${e.def.id} 校验失败');
      expect(e.json.isNotEmpty, isTrue);
    }
    // 三种类型都要有真实源（不是只有演示源）
    for (final type in const ['comic', 'novel', 'video']) {
      expect(
          entries.where((e) => e.def.type == type && !e.def.id.startsWith('demo.')),
          isNotEmpty,
          reason: '线上索引没有 $type 型真实源');
    }
  }, skip: skip, timeout: const Timeout(Duration(seconds: 120)));
}
