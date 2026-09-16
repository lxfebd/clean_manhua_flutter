import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../net/http_client.dart';
import '../net/local_store.dart';
import 'capability_plugin.dart';
import 'capability_plugin_manager.dart';

/// 能力市场条目（来自远端索引 JSON 的单个能力定义）。
///
/// 与源市场条目（MarketSourceEntry）的区别：能力条目是**元数据声明**（不是
/// 完整实现），安装时构造 [CapabilityPlugin] 交给 Manager——实现正文随 App
/// 版本代码发布（内置壳）或由插件继承类在 bind 里挂 FFI/权重。远端索引只
/// 分发「声明」，不分发代码。
class MarketCapabilityEntry {
  final String id;
  final String name;
  final String category;
  final String version;
  final String author;
  final String? description;
  final List<CapabilityWeight> weights;

  MarketCapabilityEntry({
    required this.id,
    required this.name,
    required this.category,
    required this.version,
    required this.author,
    this.description,
    this.weights = const [],
  });

  /// 是否已安装且版本一致（按 id + version 比对）。
  Future<bool> installed() async {
    final p = CapabilityPluginManager.instance.byId(id);
    return p != null && p.version == version;
  }

  /// 是否已安装但版本不同（需要更新）。
  Future<bool> needsUpdate() async {
    final p = CapabilityPluginManager.instance.byId(id);
    return p != null && p.version != version;
  }
}

/// 能力市场：拉取公开索引、解析能力条目、一键安装/更新。
///
/// 索引 JSON 格式（公开 GitHub 仓库托管，与源市场同一套拉取/缓存/校验逻辑）：
/// ```json
/// {
///   "name": "星漫匣能力市场",
///   "capabilities": [
///     {
///       "id": "ai.colorize.ddcolor",
///       "name": "AI 上色",
///       "category": "ai",
///       "version": "1.0.0",
///       "author": "星漫匣上色团队",
///       "description": "…",
///       "weights": [
///         { "name": "ddcolor.tflite", "url": "…", "sizeBytes": 235929600, "sha256": "…" }
///       ]
///     }
///   ]
/// }
/// ```
class CapabilityMarket {
  CapabilityMarket._();

  /// 索引主地址（GitHub raw）。国内网络对 raw.githubusercontent.com 常限速
  /// 到 8-10s 甚至超时，故配 jsDelivr CDN 镜像，按序回退（见 [fetchIndex]）。
  static const String _indexUrl =
      'https://raw.githubusercontent.com/lxfebd/xingmanxia-sources/main/index.json';

  /// jsDelivr 镜像（与主 URL 同内容，CDN 国内可达性更好）。
  static const String _indexMirror =
      'https://cdn.jsdelivr.net/gh/lxfebd/xingmanxia-sources@main/index.json';

  /// 索引本地缓存域：网络失败时回退，避免整市场空白。
  static const String _cacheFile = 'capability_market_index';

  /// 拉取并解析能力市场索引。网络失败先尝试缓存；缓存也没有则抛异常。
  static Future<List<MarketCapabilityEntry>> fetchIndex() async {
    try {
      // raw 限速时整体可能很慢（实测 8-10s），放宽到 30s；镜像回退按序尝试。
      final bytes = await Net.getBytesMirrors(
        [_indexUrl, _indexMirror],
        timeout: const Duration(seconds: 30),
      );
      final text = utf8.decode(bytes);
      await _cache(text);
      return _parse(text);
    } catch (e) {
      final cached = await _readCache();
      if (cached != null) return _parse(cached);
      rethrow;
    }
  }

  /// 解析索引 JSON（纯函数，可单测）。
  /// 无 capabilities 数组或损坏条目：坏条目跳过、无数组返回空列表，不阻塞市场。
  @visibleForTesting
  static List<MarketCapabilityEntry> parseIndex(String text) => _parse(text);

  static List<MarketCapabilityEntry> _parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw FormatException('能力市场索引格式错误');
    final list = decoded['capabilities'];
    // 索引 JSON 尚无 capabilities 数组时返回空列表（源市场与能力市场共用一个
    // 索引文件，能力市场先上线则源索引未更新——不报错，给空态）。
    if (list is! List) return const <MarketCapabilityEntry>[];
    final out = <MarketCapabilityEntry>[];
    for (final item in list) {
      if (item is! Map) continue;
      final m = Map<String, dynamic>.from(item);
      final id = m['id'];
      final name = m['name'];
      if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
        continue; // 跳过无 id/name 的坏条目，不阻塞整个市场
      }
      final weights = <CapabilityWeight>[];
      final wl = m['weights'];
      if (wl is List) {
        for (final w in wl) {
          if (w is! Map) continue;
          final wn = w['name'];
          final wu = w['url'];
          if (wn is! String || wn.isEmpty || wu is! String || wu.isEmpty) {
            continue;
          }
          weights.add(CapabilityWeight(
            name: wn,
            url: wu,
            sizeBytes: (w['sizeBytes'] as num?)?.toInt() ?? 0,
            sha256: (w['sha256'] as String?) ?? '',
          ));
        }
      }
      out.add(MarketCapabilityEntry(
        id: id,
        name: name,
        category: (m['category'] as String?) ?? 'utility',
        version: (m['version'] as String?) ?? '0.0.0',
        author: (m['author'] as String?) ?? '未知',
        description: m['description'] as String?,
        weights: weights,
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

  /// 安装（或更新）一个市场能力条目：构造 CapabilityPlugin 交给 Manager。
  /// 返回是否成功。
  ///
  /// 幂等语义：
  /// - 全新安装：manager.install 注册（已存在同 id 则忽略）。
  /// - 更新（同 id 不同版本）：先把旧「市场安装」实例移出注册表 + purge
  ///   旧构件，再装新版本——否则 registry 里卡住旧版本，[installed]（按
  ///   id+version 比对）永远判 needsUpdate，且旧实现正文与新权重错配。
  ///   内置能力同 id 冲突（如 utility.*）不入此路径：内置不可覆盖。
  static Future<bool> install(MarketCapabilityEntry entry) async {
    final mgr = CapabilityPluginManager.instance;
    final cur = mgr.byId(entry.id);
    if (cur == null) {
      // 全新安装：直接注册（幂等）。
      final plugin = CapabilityPlugin(
        id: entry.id,
        name: entry.name,
        category: entry.category,
        version: entry.version,
        author: entry.author,
        description: entry.description,
        builtin: false, // 市场安装：可卸载
        weights: entry.weights,
      );
      await mgr.install(plugin);
      return mgr.byId(entry.id) != null;
    }
    // 已存在：仅当是市场安装（可卸载）且版本不同才走替换；同版本视为
    // 已安装（幂等 no-op）。
    if (cur.builtin || cur.version == entry.version) {
      return true;
    }
    final ok = await uninstall(entry.id);
    if (!ok) return false;
    return install(entry);
  }

  /// 卸载一个市场能力（内置能力不可卸载，返回 false）。
  static Future<bool> uninstall(String id) =>
      CapabilityPluginManager.instance.uninstall(id);
}
