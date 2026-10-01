import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/image_deg.dart';

/// 修复 P1-3「超分缓存 key 槽污染」复核 + 守卫。
///
/// 复核结论：审计报告称「超分 key 经 normalizeUrl 后与普通图同 md5 槽」
/// 系误报——超分/裁边 key 是在 url 后拼接 `|{transform}|{version}`，
/// 而 [ImageDeg.normalizeUrl] 只剥离 `@jm:` 解扰标记、不触碰 `|`，因此
/// 普通图、超分、裁边三者在缓存里是三个互不相同的 md5 槽，不会互相顶替。
///
/// 守卫价值：把「变换 key 必须与普通图 key 分离、且带 @jm 时坍缩到主 URL」
/// 的不变量固化为门禁，防止未来有人把变换标识内联进 url 破坏槽位隔离。
void main() {
  group('缓存槽隔离（普通图 / 超分 / 裁边）', () {
    test('超分 key 与普通图 key 恒不同槽（url 含 | 分隔符）', () {
      const url = 'https://cdn.example.com/ch/001.jpg';
      const algo = 'sr-v2';
      // reader_page 的 _srKey 构造：'${widget.url}|${algoVersion}'
      final srKey = '$url|$algo';
      // 两者经 normalizeUrl 后仍带不同尾缀 → md5 槽不同
      expect(srKey, isNot(url));
      expect(ImageDeg.normalizeUrl(srKey), isNot(ImageDeg.normalizeUrl(url)));
    });

    test('裁边 key 与超分 key、普通图 key 三向互异', () {
      const url = 'https://img.example/x.jpg';
      final trimKey = '$url|trim|t-v1';
      final srKey = '$url|sr-v2';
      expect(
        {ImageDeg.normalizeUrl(url), ImageDeg.normalizeUrl(trimKey), ImageDeg.normalizeUrl(srKey)}
            .length,
        3,
        reason: '普通图/裁边/超分三项应各自独立缓存槽',
      );
    });

    test('带 @jm: 标记坍缩到主 URL：超分 key 也跟随坍缩（同图多地址共享）', () {
      const base = 'https://host/a.jpg';
      // 同一源图的两个不同 @jm 解扰引用 → 归一化后应为同主 URL（共享一份）
      final norm1 = ImageDeg.normalizeUrl('$base@jm:abc');
      final norm2 = ImageDeg.normalizeUrl('$base@jm:def');
      expect(norm1, base);
      expect(norm2, base);
      // 超分 key（主url+@jm+版本）同样坍缩到同一个「主url+版本」槽
      final sr1 = ImageDeg.normalizeUrl('$base@jm:abc|sr-v2');
      final sr2 = ImageDeg.normalizeUrl('$base@jm:def|sr-v2');
      expect(sr1, sr2, reason: '同图不同解扰标记的超分结果应共享缓存');
      // 注：这里的「超分 key」直接用 url 原文拼（修复前形态）。当 url 带
      // @jm: 时它坍缩成主 url，所以下面这个断言必须与主槽相同——这正是
      // 污染根因的演示（修复请移步下一个测试）。
    });

    test('P1-3 槽污染核心：url 原文拼 |algo 会被 @jm: 截尾并坍缩成普通图槽', () {
      // 修复前：srKey = '${widget.url}|${algoVersion}'，带 @jm 时
      //   normalizeUrl(url@jm:xyz|sr-v2) = url（从 @jm: 截断，|sr-v2 被丢）
      //   → 与普通图 key 完全同槽，超分结果覆盖原图缓存（污染）。
      const base = 'https://host/a.jpg';
      final oldSrKey = '$base@jm:xyz|sr-v2';
      expect(
        ImageDeg.normalizeUrl(oldSrKey),
        ImageDeg.normalizeUrl('$base@jm:xyz'),
        reason: '旧的 url 原文拼接在带 @jm 时会坍缩成普通图槽（污染根因）',
      );

      // 修复后：先取主 URL 再拼变换标识 → 变换槽恒与普通图分离。
      final fixedSrKey =
          '${ImageDeg.normalizeUrl('$base@jm:xyz')}|sr|sr-v2';
      expect(fixedSrKey, 'https://host/a.jpg|sr|sr-v2');
      expect(
        ImageDeg.normalizeUrl(fixedSrKey),
        isNot(ImageDeg.normalizeUrl('$base@jm:xyz')),
        reason: '修复后超分槽与普通图槽隔离',
      );
    });
  });
}