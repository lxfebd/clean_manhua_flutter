import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../sources/novel_source.dart';

/// 在线小说章节磁盘缓存（断网兜底）：网络失败时阅读器可读已缓存章节。
///
/// - 目录：`<appSupport>/novel_cache/<sourceId>/<novelId>/<chapterId>.json`；
/// - id 均经 [Uri.encodeComponent] 编码后作路径段，防外部 id 穿越目录；
/// - 只缓存正文段落 + 上下章导航，不缓存目录/元信息。
class NovelChapterCache {
  NovelChapterCache._();

  /// 读缓存；文件缺失/解析失败返回 null（不抛，调用方降级走网络）。
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
