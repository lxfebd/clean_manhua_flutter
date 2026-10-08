import 'dart:io';

/// 磁盘 LRU 配额清理原语（P1-15 收敛）：删除 [root] 下修改时间最旧的
/// 文件，直到总大小 ≤ [maxBytes] 且文件数 ≤ [maxCount]（可选），返回
/// 删除的文件数。
///
/// 文件 mtime ≈ 最近一次写入/读取，即 LRU 序。被 image_cache（封面/连读/
/// 超分导数目录，带 [_maxDiskCount] 上限）与 novel_chapter_cache（小说章节
/// 缓存）共用——两份实现曾是 `_maybeTrimDisk` / `pruneDirectory` 各写一遍。
///
/// [maxCount] 为 null 时不限制文件数（仅按字节配额裁剪）。
Future<int> pruneLruDirectory(
  Directory root,
  int maxBytes, {
  int? maxCount,
}) async {
  try {
    if (!await root.exists()) return 0;
    final files = <File>[];
    await for (final e in root.list(recursive: true)) {
      if (e is File) files.add(e);
    }
    if (files.isEmpty) return 0;
    var total = 0;
    for (final f in files) {
      total += await f.length();
    }
    final overCount = maxCount != null && files.length > maxCount;
    if (total <= maxBytes && !overCount) return 0;
    // 最旧优先删，直到回到配额内（字节 + 可选文件数上限，或删光）。
    files.sort((a, b) =>
        a.statSync().modified.compareTo(b.statSync().modified));
    var removed = 0;
    while (removed < files.length &&
        (total > maxBytes ||
            (maxCount != null && files.length - removed > maxCount))) {
      final len = await files[removed].length();
      await files[removed].delete();
      total -= len;
      removed++;
    }
    return removed;
  } catch (_) {
    // 目录不存在/权限失败静默：清理失败不影响本次阅读。
    return 0;
  }
}
