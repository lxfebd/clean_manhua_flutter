import 'dart:io';

/// 文件损坏备份：把损坏的持久化文件重命名为 `.corrupt-<毫秒时间戳>` 再继续，
/// 避免「数据突然清空且无法追溯」。三处持久化栈（LocalStore / BookshelfStore /
/// NovelShelfStore）统一走这里，重命名失败只记录不抛（不影响主流程）。
extension CorruptBackup on File {
  /// 返回是否成功备份（文件不存在 / 重命名失败都返回 false）。
  bool backupCorrupt() {
    try {
      if (!existsSync()) return false;
      renameSync('$path.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      return true;
    } catch (_) {
      return false;
    }
  }
}
