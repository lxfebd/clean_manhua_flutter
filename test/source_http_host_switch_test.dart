import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/source_http.dart';
import 'package:xingmanxia/sources/source_result.dart';

/// P1-07 多 host 故障切换的判定逻辑回归。
///
/// 背景：配置里的 `hosts` 是「可变域名 / 镜像列表，连接时逐个尝试」，但
/// `pickHost` 永远只返回第一个 → 首域名失效时其他镜像形同虚设，用户感知为
/// 「源整体挂了」。修复后按列表逐个尝试，而**该不该换**由纯函数判定。
///
/// 「该换」与「不该换」的边界是这个修复的核心：换错方向要么把 404 打 N 遍
/// （浪费配额、拖慢失败），要么该换的时候不换（镜像白配）。
void main() {
  group('shouldTryNextHost（P1-07）', () {
    test('连接层/超时 → 换（这个 host 的问题）', () {
      expect(SourceHttp.shouldTryNextHost(const SourceNetwork('连接被重置')),
          isTrue);
      expect(SourceHttp.shouldTryNextHost(const SourceNetwork('timeout')), isTrue);
    });

    // P2-15 审计修复后：判定用结构化 statusCode。带上状态码才判 5xx/429。
    test('5xx / 429 → 换', () {
      for (final c in [500, 502, 503, 429]) {
        expect(SourceHttp.shouldTryNextHost(SourceService('HTTP $c', c)), isTrue,
            reason: 'HTTP $c');
      }
    });

    test('404 / 401 / 403 → 不换（path 或凭据问题，换了也是同样的错）', () {
      for (final c in [404, 401, 403]) {
        expect(SourceHttp.shouldTryNextHost(SourceService('HTTP $c', c)), isFalse,
            reason: 'HTTP $c');
      }
    });

    test('service 无状态码（业务/配置错误）→ 不换', () {
      // 「未配置详情页规则」这类业务错误与 host 无关，换了也没用。
      expect(SourceHttp.shouldTryNextHost(const SourceService('该源未配置详情页规则')),
          isFalse);
      expect(SourceHttp.shouldTryNextHost(const SourceService()), isFalse);
    });

    test('只有 message 字符串、没有 statusCode → 不再当成 5xx', () {
      // 审计发现的真 bug：HttpStatusException 不是 HttpException，早前所有
      // 状态错误都落进 unknown；message 匹配形同虚设。现在结构化后才可信。
      expect(SourceHttp.shouldTryNextHost(SourceService('HTTP 500')), isFalse,
          reason: '字符串里写了 500 但没有 statusCode，不能当 5xx 处理');
    });

    test('传输层 HttpException → network → 换', () {
      expect(
          SourceHttp.shouldTryNextHost(const SourceNetwork('收完整响应头前连接被关闭')),
          isTrue);
    });

    test('解析失败 → 不换（页面拿到了，是选择器失效，换域名治不好）', () {
      expect(SourceHttp.shouldTryNextHost(const SourceParse('选择器未命中')),
          isFalse);
    });

    test('鉴权 / 风控 / 未知 → 不换', () {
      expect(SourceHttp.shouldTryNextHost(const SourceUnauthorized('需要登录')),
          isFalse);
      expect(
          SourceHttp.shouldTryNextHost(
              const SourceBlocked(BlockReason.captcha, '人机验证')),
          isFalse);
      expect(SourceHttp.shouldTryNextHost(const SourceUnknown('boom')), isFalse);
    });

    test('普通异常 → 不换（可能是代码/path 问题，不该盲目打全部镜像）', () {
      expect(SourceHttp.shouldTryNextHost(Exception('x')), isFalse);
      expect(SourceHttp.shouldTryNextHost('str'), isFalse);
    });
  });
}
