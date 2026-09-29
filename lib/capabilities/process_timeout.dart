import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 带超时的进程执行。
///
/// `Process.run` 没有 timeout 参数，且超时后拿不到进程句柄、无法终止——
/// 损坏的压缩包或挂起的 powershell/unzip 会永久占着解压流程（UI 卡死）。
/// 这里用 [Process.start] + [Process.exitCode.timeout] + 超时 kill，
/// 保证超时后进程被终止、调用方能拿到明确结果。
///
/// 超时抛 [TimeoutException]，由调用方转成用户可读原因。
Future<ProcessResult> runProcessWithTimeout(
  String executable,
  List<String> arguments,
  Duration timeout,
) async {
  final proc = await Process.start(executable, arguments);
  final out = <int>[];
  final err = <int>[];
  final outSub = proc.stdout.listen(out.addAll);
  final errSub = proc.stderr.listen(err.addAll);
  try {
    final code = await proc.exitCode.timeout(timeout);
    await outSub.cancel();
    await errSub.cancel();
    return ProcessResult(proc.pid, code, out, err);
  } on TimeoutException {
    // 超时：杀进程并等回收，避免僵尸/半解压目录残留。
    proc.kill();
    try {
      await proc.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {}
    await outSub.cancel();
    await errSub.cancel();
    rethrow;
  }
}

/// 从 [ProcessResult.stderr] 提取可读文本（二进制/编码异常时容错）。
String processStderrText(ProcessResult r) {
  final e = r.stderr;
  if (e is String) return e;
  if (e is List<int>) return utf8.decode(e, allowMalformed: true);
  return e.toString();
}

/// PowerShell 单引号字符串字面量（内部 `'` 加倍转义）。
///
/// 单引号串在 PowerShell 里**不做任何展开**：`$()`、反引号转义、`$var`
/// 全部按字面传递。双引号串则会求值 `$(...)`——zip 路径的文件名段来自
/// 远端 URL，恶意市场索引可构造含 `$(...)` 的文件名实现命令注入，故
/// [psExpandArchiveCommand] 必须走本函数而非 `"...$path..."` 插值。
String psSingleQuote(String s) => "'${s.replaceAll("'", "''")}'";

/// Expand-Archive 命令串（路径全部经 [psSingleQuote] 包裹，防注入）。
/// 抽成函数供 ffmpeg / rife 两处解压共用，避免各拼各的再拼错。
String psExpandArchiveCommand(String zipPath, String destinationPath) =>
    'Expand-Archive -LiteralPath ${psSingleQuote(zipPath)} '
    '-DestinationPath ${psSingleQuote(destinationPath)} -Force';
