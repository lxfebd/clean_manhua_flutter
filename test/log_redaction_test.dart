import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/net/error_logger.dart';

/// P2-19 日志脱敏回归。
///
/// 日志会被用户一键导出并转发给开发者，因此写下的每一行都按「可能外传」的
/// 标准处理。这里锁死四类必须掩的敏感片段，以及「不该掩的别乱掩」——
/// 过度掩码会让日志失去诊断价值。
void main() {
  String r(String s) => ErrorLogger.redactSensitive(s);

  group('redactSensitive', () {
    test('Authorization 头掩码', () {
      expect(r('Authorization: Bearer abc.def.ghi'),
          contains('Authorization: ***'));
      expect(r('Authorization: Bearer abc.def.ghi'), isNot(contains('abc.def')));
      // 大小写不敏感
      expect(r('authorization=Zm9vOmJhcg=='), contains('***'));
    });

    test('Cookie 头掩码', () {
      final out = r('Cookie: sessionid=deadbeef; theme=dark');
      expect(out, contains('***'));
      expect(out, isNot(contains('deadbeef')));
    });

    test('Bearer / Basic 令牌本体掩码', () {
      expect(r('Authorization: Bearer eyJhbGciOi.x.y'),
          isNot(contains('eyJhbGciOi')));
      expect(r('Authorization: Basic dXNlcjpwYXNzd29yZA=='),
          isNot(contains('dXNlcjpwYXNzd29yZA==')));
    });

    test('URL 用户口令掩码（保留 host 便于定位）', () {
      final out = r('连接失败 https://alice:s3cr3t@nas.example.com/dav');
      expect(out, contains('alice:***@'));
      expect(out, isNot(contains('s3cr3t')));
      expect(out, contains('nas.example.com'), reason: 'host 要留着定位');
    });

    test('敏感查询参数值掩码', () {
      for (final q in [
        'token=abc123',
        'apikey=abcdef',
        'api_key=abcdef',
        'signature=deadbeef',
        'session=xyz',
        'password=hunter2',
      ]) {
        final out = r('https://x.com/a?$q&keep=1');
        expect(out, contains('***'), reason: q);
        expect(out, contains('keep=1'), reason: '非敏感参数要保留');
      }
      expect(r('https://x.com/a?token=abc123'), isNot(contains('abc123')));
    });

    test('普通文本不被误伤', () {
      const plain = '章节加载失败 id=12345 timeout 15s url=https://m.dm5.com/c1/p3.jpg';
      expect(r(plain), plain, reason: '没有敏感内容时必须原样返回');
    });

    test('堆栈同样经过脱敏', () {
      final out = r('#0 main (file:///a.dart)\nAuthorization: Bearer zzz.yyy');
      expect(out, isNot(contains('zzz.yyy')));
    });

    test('幂等：重复脱敏不产生新泄漏', () {
      final once = r('Authorization: Bearer abc.def.ghi');
      expect(r(once), once);
    });
  });
}
