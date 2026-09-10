/// 书单文本解析：与「导出书单」模块互逆的纯文本格式。
///
/// 导出格式（见 profile_page._exportBooklist）：
/// ```
/// 星漫匣 · 我的书单（共 3 本）
/// 导出时间：2026-09-10 12:00
/// ─────────────
/// 1. 书名 — 作者（连载中）
/// 2. 书名2
/// ```
/// 解析容错：可无头部（用户可能只粘贴纯序号行）、无作者/状态、空格差异。
library;

class BooklistEntry {
  final String name;
  final String author;
  final String status;
  const BooklistEntry({required this.name, this.author = '', this.status = ''});

  @override
  String toString() =>
      'BooklistEntry(name: $name, author: $author, status: $status)';
}

class BooklistText {
  BooklistText._();

  /// 解析书单文本为条目列表，跳过空行与表头。
  /// 行格式：`1. 书名` / `1. 书名 — 作者` / `1. 书名（状态）` / 三者的组合。
  /// 书名的英文括号/全角括号都可识别；「共 N 本」表头不产生条目。
  static List<BooklistEntry> parse(String raw) {
    final out = <BooklistEntry>[];
    if (raw.trim().isEmpty) return out;
    final lines = raw.split('\n');
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      // 表头/间隔线：无序号、含「共 N 本」/「导出时间」/全等号行。
      if (!_itemRe.hasMatch(t)) continue;
      final m = _itemRe.firstMatch(t);
      final name = m!.group(1)?.trim() ?? '';
      if (name.isEmpty) continue;
      out.add(BooklistEntry(
        name: name,
        author: m.group(2)?.trim() ?? '',
        status: m.group(3)?.trim() ?? '',
      ));
    }
    return out;
  }

  /// `1. 书名（可选 — 作者）（可选（状态））`；作者用「—」或「-」分隔，
  /// 状态用全角/半角括号包裹。书名内部允许含「·」等符号。
  static final RegExp _itemRe = RegExp(
      r'^\d+[\.、]\s*(.+?)(?:\s*[—-]\s*([^（(]+?))?(?:\s*[（(]([^）)]+?)[）)])?\s*$');

  /// 生成导出文本（与 _exportBooklist 输出一致，供「复制后再导入」闭环自检）。
  static String format(List<BooklistEntry> entries, {DateTime? at}) {
    final sb = StringBuffer()
      ..writeln('星漫匣 · 我的书单（共 ${entries.length} 本）')
      ..writeln('导出时间：${(at ?? DateTime.now()).toString().substring(0, 16)}')
      ..writeln('─────────────');
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      sb.write('${i + 1}. ${e.name}');
      if (e.author.isNotEmpty) sb.write(' — ${e.author}');
      if (e.status.isNotEmpty) sb.write('（${e.status}）');
      sb.writeln();
    }
    return sb.toString();
  }
}