/// 章节摘要（纯规则版）：无模型依赖、离线可用、低端机友好。
///
/// 算法：
/// 1. 把段落拆成句子，丢弃过短（<8 字）/过长的废话段（如感叹词行）。
/// 2. 位置加权：开头（前 15%）与结尾（后 15%）的句子权重更高——
///    网络小说章节开篇常承接上文、结尾常埋钩子。
/// 3. 关键词加权：命中的词越多权重越高（穿鞋点题，如「他/她/我」、
///   转折词「但是/却/竟然/忽然」、动词「说/想/看到/发现」）。
/// 4. 按权重排序取 topK，且相邻选出的句子原文不相邻太近（避免连续摘取同段）。
///
/// [summarize] 输入段落列表，输出最多 [maxSentences] 条摘要句。
class NovelSummarizer {
  NovelSummarizer._();

  /// 生成摘要。空输入/全过滤返回空列表（调用方给空态）。
  static List<String> summarize(List<String> paragraphs,
      {int maxSentences = 3, String? focusName}) {
    if (paragraphs.isEmpty) return const [];

    // 拆句 + 过滤
    final sentences = <String>[];
    final words = <int>[];
    for (final para in paragraphs) {
      final parts = _splitSentences(para);
      for (final s in parts) {
        final w = _score(s, focusName);
        if (w < 0) continue; // 过短/无意义行直接丢
        sentences.add(s);
        words.add(w);
      }
    }
    if (sentences.length <= maxSentences) {
      return sentences.take(maxSentences).toList();
    }

    // 位置加权扩展权重
    final n = sentences.length;
    for (var i = 0; i < n; i++) {
      final pos = i / n;
      if (pos < 0.15 || pos > 0.85) words[i] = words[i] + 2;
    }

    // 排序索引（权重优先），贪心选择避免相邻重复
    final idx = List.generate(n, (i) => i)
      ..sort((a, b) => words[b].compareTo(words[a]));
    final picked = <String>[];
    final pickedIdx = <int>[];
    for (final i in idx) {
      if (picked.length >= maxSentences) break;
      // 与已选句子原文距离过近（diff 过小说明是同一段连续句）就跳过
      if (pickedIdx.any((j) => (_dist(j, i) < 8 && (j - i).abs() <= 1))) {
        continue;
      }
      picked.add(sentences[i]);
      pickedIdx.add(i);
    }
    // 按原文顺序输出（阅读连贯性优于权重序）
    pickedIdx.sort();
    return pickedIdx.map((i) => sentences[i]).toList();
  }

  /// 句子间字符差异（用于判断是否同段连续句）。
  static int _dist(int a, int b) => (a - b).abs();

  /// 句子打分：<0 丢弃；否则 0-6 分。
  static int _score(String s, String? focusName) {
    final t = s.trim();
    if (t.length < 8) return -1; // 太短（可能只是语气词/拟声）
    if (t.length > 120) return -1; // 超长段（多半是整页正文，摘要不可用）

    var w = 0;
    // 关键转折/高潮词
    for (final k in _keyWords) {
      if (t.contains(k)) w++;
    }
    // 主角名命中加权（用户可传入当前作品主角）
    if (focusName != null &&
        focusName.isNotEmpty &&
        t.contains(focusName)) {
      w += 2;
    }
    // 纯感叹/无实意行降权
    if (t.endsWith('……') || t.endsWith('！') || t.endsWith('？')) {
      w -= 1;
    }
    return w;
  }

  static const List<String> _keyWords = [
    '但是', '却', '竟然', '忽然', '突然', '终于', '然而', '没想到',
    '说', '想', '看到', '发现', '知道', '决定', '回来', '去', '走',
    '死', '杀', '战', '赢', '输', '救', '逃', '见', '听',
  ];

  /// 按中文标点拆句；省略号（……）作为整体句读，只在序列末尾拆。
  static List<String> _splitSentences(String para) {
    final t = para.trim();
    if (t.isEmpty) return const [];
    final parts = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < t.length; i++) {
      final c = t[i];
      buf.write(c);
      if (c == '。' || c == '！' || c == '？') {
        parts.add(buf.toString());
        buf.clear();
      } else if (c == '；' || c == '\u2026') {
        // U+2026「…」：省略号序列中间不拆，只有末尾（后面不是省略号）才拆，
        // 保证「……让你永远猜不透」这类连写不碎成语气词。
        if (c == '\u2026' && i + 1 < t.length && t[i + 1] == '\u2026') {
          continue;
        }
        parts.add(buf.toString());
        buf.clear();
      }
    }
    if (buf.isNotEmpty) parts.add(buf.toString());
    return parts;
  }
}