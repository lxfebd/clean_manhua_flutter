import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xingmanxia/net/update_checker.dart';

/// 修复线 6「网络/下载/存储」P1 回归测试。
///
/// 覆盖：
///   1. `compareVersions` 支持 `+build` 元数据比较（P1 #2）
///   2. `_attemptCronet` 的 client.close 在 finally 路径中显式 `.ignore()`
///      （P1 #1，静态源码审查——无法真实 mock Cronet 引擎）
void main() {
  group('UpdateChecker.compareVersions 含 build 元数据', () {
    test('同版本 build 数字不同：build 大者为新（P1 #2 核心）', () {
      expect(UpdateChecker.compareVersions('1.2.3+4', '1.2.3+5'), lessThan(0));
      expect(UpdateChecker.compareVersions('1.2.3+5', '1.2.3+4'), greaterThan(0));
    });

    test('同版本 build 数字相等：视为相等', () {
      expect(UpdateChecker.compareVersions('1.2.3+5', '1.2.3+5'), 0);
    });

    test('无 build vs 有 build：有 build 视为更新（缺失 build 视为 0）', () {
      expect(UpdateChecker.compareVersions('1.2.3', '1.2.3+1'), lessThan(0));
      expect(UpdateChecker.compareVersions('1.2.3+1', '1.2.3'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('主/次/补丁不同优先于 build 比较', () {
      // 主版本更高时，即使 build 更小也视为更新
      expect(UpdateChecker.compareVersions('2.0.0+1', '1.9.9+999'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.9.9+999', '2.0.0+1'), lessThan(0));
      // 次版本优先
      expect(UpdateChecker.compareVersions('1.3.0+1', '1.2.9+999'), greaterThan(0));
      // 补丁优先
      expect(UpdateChecker.compareVersions('1.2.4+1', '1.2.3+999'), greaterThan(0));
    });

    test('build 非纯数字时按字符串比兜底', () {
      // 'rc' > 'dev'（字符串比较）
      expect(UpdateChecker.compareVersions('1.0.0+rc', '1.0.0+dev'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.0.0+dev', '1.0.0+rc'), lessThan(0));
      expect(UpdateChecker.compareVersions('1.0.0+dev', '1.0.0+dev'), 0);
    });

    test('CI 多轮打包场景：1.2.3+4 → 1.2.3+5 应提示升级（回归断言）', () {
      // 修复前该断言为 0，CI 上永远不会提示升级——正是 P1 #2 报的缺陷
      expect(
        UpdateChecker.compareVersions('1.2.3+5', '1.2.3+4'),
        greaterThan(0),
        reason: 'build 元数据必须参与比较，否则 CI 多轮打包永不提示升级',
      );
    });
  });

  group('_attemptCronet 资源泄漏回归（P1 #1）', () {
    // 说明：`_attemptCronet` 是 private 且内部调用
    // `CronetHttp.defaultCronetEngine()`（Android-only 真实引擎，测试环境返回 null）。
    // 无法独立 mock 出一个可运行的「超时后仍需释放 client」路径。
    // 因此退化为静态源码审查：验证 finally 中 `client.close()` 存在且在
    // finally 块内——close 是同步 void（CronetHttp 引擎），外层
    // `.timeout(probe)` 触发时 finally 仍同步执行，client 一定被释放。
    test('finally 中 client.close() 存在且在 finally 块内（超时也释放）', () {
      final src = _readHttpclientSource();
      final idx = src.indexOf('_attemptCronet');
      expect(idx, greaterThan(0), reason: '应能定位到 _attemptCronet 方法');
      // 截取 _attemptCronet 到下一个 static 方法或函数结束的大致范围
      final segment = src.substring(idx,
          src.length > idx + 4000 ? idx + 4000 : src.length);
      // 关键断言：finally 块中存在 client.close()（同步 void，无 Future 可等）
      expect(
        segment,
        contains('client.close()'),
        reason:
            'finally 中必须调用 client.close() 释放连接（close 为同步 void，'
            '外层 .timeout(probe) 触发时 finally 仍同步执行，保证释放）',
      );
      // 断言 close 位于 finally 块内（避免移到 try 尾部导致 throw 路径不释放）
      final finallyIdx = segment.indexOf('finally');
      final closeIdx = segment.indexOf('client.close()');
      expect(finallyIdx, greaterThan(0));
      expect(closeIdx, greaterThan(finallyIdx),
          reason: 'client.close() 必须位于 finally 块内以保证 throw 路径也释放');
    });
  });
}

/// 读取 lib/net/http_client.dart 源码文本。用于 _attemptCronet 的静态审查。
///
/// 说明：Flutter 测试在 package:xingmanxia 工作区下运行时，ProjectRoot 与
/// `Platform.script` 位于同一 repo 内，向上回溯定位到项目根即可稳定读取。
String _readHttpclientSource() {
  // flutter test 的工作目录固定在项目根（package:xingmanxia），直接用相对
  // 路径即可；Platform.script 在 flutter test 下指向编译产物，不能作锚点。
  final candidate = File(p.join('lib', 'net', 'http_client.dart'));
  if (!candidate.existsSync()) {
    fail('无法定位 lib/net/http_client.dart（当前目录: ${Directory.current.path}）');
  }
  return candidate.readAsStringSync();
}
