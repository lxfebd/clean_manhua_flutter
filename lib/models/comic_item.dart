/// 漫画/动漫/小说条目模型。
class ComicItem {
  String id;
  String name;
  String? yname;
  String pic; // 封面图 URL
  String? score;
  String? hits;
  String? rank;
  String? author;
  String? content;
  /// 更新提示（如「更新至第19集」「全12集」），视频源列表卡片展示用。
  String? remarks;
  /// 配音/语言（如「日语」「国语」），视频源详情展示用。
  String? lang;

  ComicItem(this.id, this.name, this.pic);

  factory ComicItem.fromMap(Map<String, dynamic> m) {
    return ComicItem(
      _s(m['id']),
      _s(m['name']),
      _s(m['pic']),
    )
      ..yname = _s(m['yname'])
      ..score = _s(m['score'])
      ..hits = _s(m['hits'])
      ..rank = _s(m['rank'])
      ..author = _s(m['author'])
      ..content = _s(m['content'])
      ..remarks = _s(m['remarks'])
      ..lang = _s(m['lang']);
  }

  static String _s(dynamic v) => v == null ? '' : v.toString();
}
