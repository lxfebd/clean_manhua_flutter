// 覆盖率门禁（P2-27）。
// 这是命令行工具，stdout 就是它的输出通道。
// ignore_for_file: avoid_print
//
// 用法：
//   flutter test --coverage -j4
//   dart run tool/check_coverage.dart
//
// 基线在 tool/coverage_baseline.json。当前覆盖率低于基线即失败；
// `--update` 只允许把基线**往上调**，防止有人为了让 CI 变绿把阈值往下改。
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final lcov = File('coverage/lcov.info');
  if (!lcov.existsSync()) {
    stderr.writeln('缺少 coverage/lcov.info，请先跑 flutter test --coverage');
    exitCode = 2;
    return;
  }
  final baselineFile = File('tool/coverage_baseline.json');
  final baseline = jsonDecode(await baselineFile.readAsString())
      as Map<String, dynamic>;

  final totals = <String, List<int>>{};
  String? current;
  for (final raw in await lcov.readAsLines()) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      var path = line.substring(3).replaceAll('\\', '/');
      if (path.contains('/lib/')) {
        path = path.split('/lib/').last;
      } else if (path.startsWith('lib/')) {
        path = path.substring(4);
      }
      current = path;
    } else if (line.startsWith('DA:') && current != null) {
      final parts = line.substring(3).split(',');
      if (parts.length < 2) continue;
      final hits = int.tryParse(parts[1]) ?? 0;
      final top = current.contains('/') ? current.split('/').first : '(root)';
      final key = 'lib/$top';
      final entry = totals.putIfAbsent(key, () => [0, 0]);
      entry[1]++;
      if (hits > 0) entry[0]++;
    }
  }

  var failed = false;
  final next = <String, dynamic>{};
  for (final entry in baseline.entries) {
    final key = entry.key;
    final min = (entry.value as num).toDouble();
    final stat = totals[key];
    if (stat == null || stat[1] == 0) {
      stderr.writeln('⚠️  $key 在 lcov 中没有记录');
      failed = true;
      continue;
    }
    final pct = stat[0] * 100.0 / stat[1];
    next[key] = double.parse(pct.toStringAsFixed(2));
    final ok = pct + 1e-9 >= min;
    if (!ok) failed = true;
    print('${ok ? '✅' : '❌'} $key: ${pct.toStringAsFixed(2)}% '
        '(基线 ${min.toStringAsFixed(2)}%, ${stat[0]}/${stat[1]} 行)');
  }

  if (args.contains('--update')) {
    var changed = false;
    for (final entry in next.entries) {
      final old = (baseline[entry.key] as num).toDouble();
      if ((entry.value as num).toDouble() > old) {
        baseline[entry.key] = entry.value;
        changed = true;
      }
    }
    if (changed) {
      await baselineFile.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(baseline)}\n');
      print('基线已上调并写回 tool/coverage_baseline.json');
    } else {
      print('没有可上调的基线（不会向下修改）');
    }
  }

  if (failed) {
    stderr.writeln('覆盖率低于基线。若是新代码导致，请补测试；'
        '若确实提升了覆盖率，可跑 --update 上调基线。');
    exitCode = 1;
  }
}
