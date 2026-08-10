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
      ..content = _s(m['content']);
  }

  static String _s(dynamic v) => v == null ? '' : v.toString();
}
