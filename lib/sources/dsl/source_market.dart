import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../net/error_logger.dart';
import '../../net/http_client.dart';
import '../../net/local_store.dart';
import '../../utils/index_signature.dart';
import '../../utils/market_index_urls.dart';
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

  /// 索引本地缓存域：网络失败时回退，避免整源市场空白。
  static const String _cacheFile = 'source_market_index';

  /// 拉取并解析源市场索引。网络失败先尝试缓存；
  /// 缓存也没有则抛异常（调用方给错误 UI）。
  ///
  /// 安全时序（P1 修复）：**先解析再写缓存**。旧实现先落盘再解析，一旦解析
  /// 失败会留下坏缓存——下次离线时同样解析失败，把好版本挤掉。现在网络拉
  /// 到后立即在内存里跑 [_parse]，只有解析成功才写缓存。
  static Future<List<MarketSourceEntry>> fetchIndex() async {
    try {
      // 候选按序回退：官方直连 → 回源型 GH 代理（返回最新）→ jsDelivr（仅兜底，
      // 可能 7 天旧缓存）。totalTimeout 给整条链设合计上限，见 kMarketIndexTotalTimeout。
      final bytes = await Net.getBytesMirrors(
        kMarketIndexUrls,
        timeout: kMarketIndexTimeout,
        totalTimeout: kMarketIndexTotalTimeout,
      );
      final text = utf8.decode(bytes);
      // 来源校验（签名）：篡改视为拉取失败走 catch 回退缓存，且**绝不落盘**，
      // 坏索引连缓存都污染不了。未签名暂告警放行，见 checkIndexOrTrust。
      // 缓存路径不再验签：缓存只写入过验签通过的内容，是本机可信数据。
      if (!checkIndexOrTrust(text, what: '源市场')) {
        throw const FormatException('源市场索引签名校验失败');
      }
      // 先解析、解析成功才落盘；避免坏索引覆盖已有好缓存
      final parsed = _parse(text);
      await _cache(text);
      return parsed;
    } catch (e) {
      final cached = await _readCache();
      if (cached != null) return _parse(cached);
      rethrow;
    }
  }

  /// 解析索引 JSON（纯函数，可单测）。
  /// sources 段为坏条目（字段缺/类型错/校验失败）时跳过并记日志，
  /// 不阻塞整个市场——与 [MarketSourceEntry.installed] 的按条比对一致。
  @visibleForTesting
  static List<MarketSourceEntry> parseIndex(String text) => _parse(text);

  static List<MarketSourceEntry> _parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw FormatException('索引格式错误');
    final list = decoded['sources'];
    if (list is! List) throw FormatException('索引缺少 sources 数组');
    final out = <MarketSourceEntry>[];
    final provider = (decoded['name'] as String?) ?? '源市场';
    for (final item in list) {
      if (item is! Map) continue;
      try {
        final m = Map<String, dynamic>.from(item);
        final def = CustomSourceDef.fromJson(m);
        final errs = def.validate();
        if (errs.isNotEmpty) {
          ErrorLogger.instance.warn('源市场跳过 ${def.id}：$errs');
          continue;
        }
        out.add(MarketSourceEntry(
          const JsonEncoder().convert(m),
          def,
          provider,
        ));
      } catch (e) {
        // fromJson 对字段做严格类型断言（id/name/baseUrl…）：远端条目任一
        // 字段类型错（如 "id": 123）会抛 TypeError，单条隔离，不让坏源
        // 把整个市场崩掉（旧实现这里没有 try，TypeError 会逃出 fetchIndex）。
        ErrorLogger.instance.warn('源市场解析条目失败，跳过：$e');
      }
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
