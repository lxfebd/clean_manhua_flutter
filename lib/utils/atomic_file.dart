library;

import 'dart:io';

/// 原子写文件（P1-08）。
///
/// ## 为什么需要
/// 直接 `File(path).writeAsBytes()` 的问题：进程在写盘途中被杀（低内存被
/// 系统回收 / 崩溃 / 用户强行停止），目标路径会留下**半截文件**。而调用方
/// 的判据通常是「文件存在 = 这一页/这张图已经好了」——于是半截内容被永久
/// 当成有效数据：离线读到半张图，且永远不会重下（用户只能手动删缓存）。
///
/// ## 做法
/// 写 `path.part`（写的过程中只有它是不完整的），完成后 `rename` 到目标
/// 路径。同一目录内 rename 是原子操作：观察者要么看不到文件，要么看到完整
/// 的新文件，不会看到中间态。残留的 `.part` 不进最终数据，由调用方忽略。
///
/// 跨平台注意：POSIX 的 rename 直接覆盖；Windows 上 rename 到已存在文件会
/// 抛异常，故先 delete 再 rename（窗口极短，且语义仍是「要么旧要么完整新」）。

/// 原子写入 [bytes] 到 [path]。
/// 返回 true = 成功；false = 写盘或替换失败（调用方按失败处理，绝不半截）。
///
/// 并发安全（test/atomic_file_test.dart 的 race 用例锁死）：
/// - `.part` 带**唯一后缀**。若所有写者共用同一个 `$path.part`，并发写会把
///   彼此的字节缝进同一个文件，rename 出去的就是垃圾数据；
/// - **不做「先 delete 再 rename」**。dart:io 的 File.rename 在 Windows 上
///   用 MOVEFILE_REPLACE_EXISTING、POSIX 直接覆盖，本就无需先删；而先删会
///   引入竞态（两个写者交替删/改名，最后一次操作可能落在 delete 上 → 目标
///   文件反而消失）。
Future<bool> writeFileAtomic(String path, List<int> bytes) async {
  final part = File('$path.part.${++_partSeq}');
  try {
    await part.parent.create(recursive: true);
    await part.writeAsBytes(bytes);
    await part.rename(path);
    return true;
  } catch (_) {
    // 失败时清理自己那份额外的 part，别把垃圾留在缓存目录里
    // （否则 LRU 一直被它占位）。不清别人的 part——可能还有写在途。
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
    return false;
  }
}

int _partSeq = 0;

/// 目标文件是否「可信任地存在」：存在且非空。
///
/// 0 字节文件只会来自异常路径（原子写前的残留/磁盘错误），不能当成有效数据。
bool fileIsUsable(String path) {
  final f = File(path);
  if (!f.existsSync()) return false;
  try {
    return f.lengthSync() > 0;
  } catch (_) {
    return false;
  }
}
