import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';

/// 远端索引格式回归：index.json 的 sources 段必须是 CustomSourceDef
/// 顶层格式（categoryList/detail 等），否则源市场列表为空。
///
/// 候选路径：先看本地生成的候选索引（tmpprobe/index.json.new），
/// 不存在则回退到 sources/ 下两个演示源。
void main() {
  test('新索引 sources 段全部可解析且 validate 通过', () {
    final root = Directory.current.absolute;
    final candidates = [
      File('${root.path}\\..\\tmpprobe\\index.json.new'),
      File('${root.path}\\tmpprobe\\index.json.new'),
    ];
    File? f;
    for (final c in candidates) {
      if (c.existsSync()) {
        f = c;
        break;
      }
    }
    expect(f, isNotNull, reason: '未找到候选索引文件 tmpprobe/index.json.new');
    final idx = jsonDecode(f!.readAsStringSync()) as Map<String, dynamic>;
    final sources = idx['sources'] as List;
    expect(sources.length, greaterThan(0), reason: 'sources 段不能为空');

    final seen = <String>{};
    for (final s in sources) {
      final def = CustomSourceDef.fromJson(Map<String, dynamic>.from(s as Map));
      expect(seen.add(def.id), isTrue, reason: '源 id 重复: ${def.id}');
      final errs = def.validate();
      expect(errs, isEmpty,
          reason: '源 ${def.id} 校验失败: ${errs.join("; ")}');
    }
  });
}
