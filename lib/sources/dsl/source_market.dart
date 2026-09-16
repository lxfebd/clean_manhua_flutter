import 'dart:convert';

import '../../net/http_client.dart';
import '../../net/local_store.dart';
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

  /// 索引主地址（GitHub raw）。国内网络对 raw.githubusercontent.com 常限速
  /// 到 8-10s 甚至超时，故配 jsDelivr CDN 镜像，按序回退（见 [fetchIndex]）。
  static const String _indexUrl =
      'https://raw.githubusercontent.com/lxfebd/xingmanxia-sources/main/index.json';

  /// jsDelivr 镜像（与主 URL 同内容，CDN 国内可达性更好）。
  static const String _indexMirror =
      'https://cdn.jsdelivr.net/gh/lxfebd/xingmanxia-sources@main/index.json';

  /// 索引本地缓存域：网络失败时回退，避免整源市场空白。
  static const String _cacheFile = 'source_market_index';

  /// 拉取并解析源市场索引。网络失败先尝试缓存；
  /// 缓存也没有则抛异常（调用方给错误 UI）。
  static Future<List<MarketSourceEntry>> fetchIndex() async {
    try {
      // raw 限速时整体可能很慢（实测 8-10s），放宽到 30s；镜像回退按序尝试。
      final bytes = await Net.getBytesMirrors(
        [_indexUrl, _indexMirror],
        timeout: const Duration(seconds: 30),
      );
      final text = utf8.decode(bytes);
      // 网络成功先落缓存（下次离线也能浏览市场）
      await _cache(text);
      return _parse(text);
    } catch (e) {
      final cached = await _readCache();
      if (cached != null) return _parse(cached);
      rethrow;
    }
  }

  static List<MarketSourceEntry> _parse(String text) {
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

  static Future<void> _cache(String text) =>
      LocalStore.writeJson(_cacheFile, text);

  static Future<String?> _readCache() async {
    final v = await LocalStore.readJson(_cacheFile);
    return v is String && v.isNotEmpty ? v : null;
  }

  /// 安装（或更新）一个市场条目：交给 CustomSourceStore.importJson 校验+落盘。
  /// 返回是否成功。
  static Future<bool> install(MarketSourceEntry entry) async {
    final ok = await CustomSourceStore.importJson(entry.json);
    return ok > 0;
  }
}
