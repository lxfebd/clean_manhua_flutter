// 更新清单验签 CLI：用 App 内置的生产公钥校验一份 release-manifest.json。
//
// 为什么必须在包内（而不是 /tmp 下的临时脚本）：`package:xingmanxia/...` 的
// 导入要靠本包的 .dart_tool/package_config.json 解析，包外脚本会直接报
// "Couldn't resolve the package 'xingmanxia'"。CI 的自检步骤因此必须调用
// 本文件，不能 heredoc 到 /tmp。
//
// 用法：
//   dart run tool/verify_update_manifest.dart <manifest.json>
//
// 退出码：0 = valid；1 = missing/invalid/unparsable；2 = 用法或文件问题；
//        64 = 参数个数不对。
import 'dart:io';

import 'package:xingmanxia/net/update_manifest.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('用法：dart run tool/verify_update_manifest.dart <manifest.json>');
    exit(64);
  }
  final f = File(args[0]);
  if (!f.existsSync()) {
    stderr.writeln('找不到清单文件：${args[0]}');
    exit(2);
  }
  final text = f.readAsStringSync();
  switch (UpdateManifest.classify(text)) {
    case UpdateManifestStatus.valid:
      final m = UpdateManifest.tryParse(text)!;
      stdout.writeln('✅ 清单验签通过（valid）');
      stdout.writeln('   version=${m.version}  sequence=${m.sequence}  '
          'minApp=${m.minApp ?? "-"}  issuedAt=${m.issuedAt ?? "-"}');
      for (final a in m.assets) {
        stdout.writeln('   - ${a.name}  platform=${a.platform}  '
            'size=${a.size}  sha256=${a.sha256}');
      }
      exit(0);
    case UpdateManifestStatus.missing:
      stderr.writeln('❌ 清单未签名（missing）：没有 _sig 字段，App 端将禁止自动安装');
      exit(1);
    case UpdateManifestStatus.invalid:
      stderr.writeln('❌ 清单验签失败（invalid）：公钥不匹配/内容被改/字段不全，'
          'App 端将禁止自动安装');
      exit(1);
    case UpdateManifestStatus.unparsable:
      stderr.writeln('❌ 清单无法解析（unparsable）：顶层不是 JSON 对象');
      exit(1);
  }
}
