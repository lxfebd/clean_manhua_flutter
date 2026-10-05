import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../sources/novel_source.dart';

/// 在线小说章节磁盘缓存（断网兜底）：网络失败时阅读器可读已缓存章节。
///
/// - 目录：`<appSupport>/novel_cache/<sourceId>/<novelId>/<chapterId>.json`；
/// - id 均经 [Uri.encodeComponent] 编码后作路径段，防外部 id 穿越目录；
/// - 只缓存正文段落 + 上下章导航，不缓存目录/元信息；
/// - 总容量受 [maxBytes] 配额约束：超限时按文件修改时间（≈最后读取/写入
///   时间）最旧优先清理，防无限增长占满磁盘。
class NovelChapterCache {
  NovelChapterCache._();

  /// 缓存总容量上限。章节正文每章约几十 KB，200MB ≈ 数千章，足够覆盖
  /// 常用追更书目，又不会悄悄吃掉用户磁盘。
  static const int maxBytes = 200 * 1024 * 1024;

  /// 读缓存；文件缺失/解析失败返回 null（不抛，调用方降级走网络）。
  /// 成功读取视为一次使用：touch mtime，参与 LRU 顺序。
  static Future<NovelContent?> read(
    String sourceId,
    String novelId,
    String chapterId,
  ) async {
    try {
      final f = await _file(sourceId, novelId, chapterId);
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final m = jsonDecode(raw) as Map<String, dynamic>;
      // touch：网络失败兜底读也算「最近使用」，防止正在离线读的书目
      // 被后续下载的缓存顶掉。
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}
      return NovelContent(
        (m['chapterId'] as String?) ?? chapterId,
        (m['title'] as String?) ?? '',
        (m['paragraphs'] as List? ?? const []).cast<String>(),
        prevChapterId: m['prevChapterId'] as String?,
        nextChapterId: m['nextChapterId'] as String?,
      );
    } catch (e) {
      // 解析失败当无缓存，不阻断阅读流程。
      return null;
    }
  }

  /// 写缓存（覆盖旧内容）。失败仅静默：缓存是加速/兜底，不阻塞阅读。
  /// 写完后按配额清理最旧文件。
  static Future<void> write(
    String sourceId,
    String novelId,
    String chapterId,
    NovelContent c,
  ) async {
    try {
      final f = await _file(sourceId, novelId, chapterId);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({
          'chapterId': c.chapterId,
          'title': c.title,
          'paragraphs': c.paragraphs,
          'prevChapterId': c.prevChapterId,
          'nextChapterId': c.nextChapterId,
        }),
      );
      // write 的 f 是 <base>/<src>/<novel>/<chapter>.json，三层 parent
      // 即缓存根 <base>；配额按整棵 novel_cache 树统计。
      await _enforceQuota(f.parent.parent.parent);
    } catch (e) {
      // 磁盘满/权限失败静默：缓存失败不影响在线阅读。
    }
  }

  /// 删除缓存（章节下线清理等场景用）。
  static Future<void> delete(
    String sourceId,
    String novelId,
    String chapterId,
  ) async {
    try {
      final f = await _file(sourceId, novelId, chapterId);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 配额清理（公开以便测试注入小配额）：删除 [root] 下修改时间最旧的
  /// 文件，直到总大小 ≤ [maxBytes]，返回删除的文件数。
  /// 文件 mtime ≈ 最近一次写入/读取，即 LRU 序。
  static Future<int> pruneDirectory(Directory root, int maxBytes) async {
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
      if (total <= maxBytes) return 0;
      // 最旧优先删，直到回到配额内（或删光）。
      files.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified));
      var removed = 0;
      for (final f in files) {
        if (total <= maxBytes) break;
        final len = await f.length();
        await f.delete();
        total -= len;
        removed++;
      }
      return removed;
    } catch (_) {
      // 目录不存在/权限失败静默：清理失败不影响本次阅读。
      return 0;
    }
  }

  /// 写缓存后的常规配额巡检：超限即按 LRU 清理。参数是缓存根目录
  /// （write 侧传入 `f.parent.parent.parent`）。
  static Future<void> _enforceQuota(Directory cacheRoot) async {
    await pruneDirectory(cacheRoot, maxBytes);
  }

  static Future<File> _file(String sourceId, String novelId, String chapterId) async {
    final d = await getApplicationSupportDirectory();
    final base = Directory('${d.path}/novel_cache');
    return File(
      '${base.path}/${Uri.encodeComponent(sourceId)}/'
      '${Uri.encodeComponent(novelId)}/'
      '${Uri.encodeComponent(chapterId)}.json',
    );
  }
}
