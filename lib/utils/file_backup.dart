import 'dart:io';

/// 文件损坏备份：把损坏的持久化文件重命名为 `.corrupt-<毫秒时间戳>` 再继续，
/// 避免「数据突然清空且无法追溯」。三处持久化栈（LocalStore / BookshelfStore /
/// NovelShelfStore）统一走这里，重命名失败只记录不抛（不影响主流程）。
extension CorruptBackup on File {
  /// 返回是否成功备份（文件不存在 / 重命名失败都返回 false）。
  bool backupCorrupt() {
    try {
      if (!existsSync()) return false;
      final renamed = '$path.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      renameSync(renamed);
      _pruneCorruptBackups(path);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 同一逻辑文件的历史 .corrupt 备份保留份数：每次都损坏（如持续写盘失败）
/// 会无限累积占盘，只留最近 [keep] 份供追溯。
const int _corruptKeep = 3;

/// 清理 [logicalPath] 对应的旧 .corrupt 备份（保留最近几份）。
/// 同步枚举（目录内文件数受持久化文件数量限制，量级很小）。
void _pruneCorruptBackups(String logicalPath) {
  try {
    final dir = File(logicalPath).parent;
    final base = logicalPath.split(RegExp(r'[/\\]')).last;
    final prefix = '$base.corrupt-';
    final all = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.path.split(RegExp(r'[/\\]')).last.startsWith(prefix))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // 时间戳倒序（新在前）
    for (final f in all.skip(_corruptKeep)) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  } catch (_) {
    // 清理失败不影响主流程（下次损坏时再试）
  }
}
