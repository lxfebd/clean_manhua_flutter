import 'dart:convert';

import '../../net/http_client.dart';
import 'custom_source_def.dart';
import 'custom_source_store.dart';

/// 源市场条目（来自远端索引 JSON 的单个源定义）。
class MarketSourceEntry {
  /// 源定义完整 JSON（字符串形式，安装时直接交给 importJson）。
  final String json;
  final CustomSourceDef def;

  /// 索引提供方（如 "官方"、"社区 A"），用于展示来源。
  final String provider;

  MarketSourceEntry(this.json, this.def, this.provider);

  String get id => def.id;
  String get name => def.name;
  String get type => def.type;
  String get version => def.version;
  String get author => def.author;
  String? get description => def.description;

  /// 当前版本是否已安装（按 id + 版本比对）。
  Future<bool> installed() async {
    final cur = await CustomSourceStore.byId(id);
    return cur != null && cur.version == version;
  }

  /// 是否已安装但版本不同（需要更新）。
  Future<bool> needsUpdate() async {
    final cur = await CustomSourceStore.byId(id);
    return cur != null && cur.version != version;
  }
}

/// 源市场：拉取公开索引、解析条目、一键安装/更新。
///
/// 索引 JSON 格式（公开 GitHub 仓库托管）：
/// ```json
/// {
///   "name": "星漫匣源市场",
///   "sources": [
///     { "...完整 CustomSourceDef..." }
///   ]
/// }
/// ```
class SourceMarket {
  SourceMarket._();

  static const String _indexUrl =
      'https://raw.githubusercontent.com/lxfebd/xingmanxia-sources/main/index.json';

  /// 拉取并解析源市场索引。网络失败抛异常（调用方给错误 UI）。
  static Future<List<MarketSourceEntry>> fetchIndex() async {
    final bytes = await Net.getBytes(_indexUrl, timeout: const Duration(seconds: 15));
    final text = utf8.decode(bytes);
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw FormatException('索引格式错误');
    final list = decoded['sources'];
    if (list is! List) throw FormatException('索引缺少 sources 数组');
    final out = <MarketSourceEntry>[];
    for (final item in list) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final def = CustomSourceDef.fromJson(m);
      // 跳过校验失败的条目（坏源不阻塞整个市场）
      if (def.validate().isNotEmpty) continue;
      out.add(MarketSourceEntry(
        const JsonEncoder().convert(m),
        def,
        (decoded['name'] as String?) ?? '源市场',
      ));
    }
    return out;
  }

  /// 安装（或更新）一个市场条目：交给 CustomSourceStore.importJson 校验+落盘。
  /// 返回是否成功。
  static Future<bool> install(MarketSourceEntry entry) async {
    final ok = await CustomSourceStore.importJson(entry.json);
    return ok > 0;
  }
}
