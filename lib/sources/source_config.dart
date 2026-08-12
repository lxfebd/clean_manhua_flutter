import '../net/local_store.dart';

/// 源优先级层级（对应 Ani 的 `MediaSourceTier`）。
///
/// - [primary]：首选源（默认启用、排在前面）。
/// - [fallback]：兜底源。
/// - [disabled]：用户关闭。
enum SourceTier { primary, fallback, disabled }

/// 声明式源配置——「会变的东西」全部外置到这里，而非写死在源实现里。
///
/// 这是对「禁漫域名一死就要改代码重发版」根因的治本：源 = 引擎代码（不变） + 本配置（易变）。
/// 本对象可序列化为 JSON 持久化，源管理页可直接编辑，并支持远程覆盖（免发版更新域名）。
class SourceConfig {
  final String engineId; // 对应 concrete 源实现（如 'jm' / 'doubao'）
  final String id;
  final String name;
  final String? iconUrl;
  final List<String> hosts; // 可变域名 / 镜像列表，连接时逐个尝试
  final List<String> imageHosts; // 图片 CDN 兜底域名
  final Map<String, String> headers; // 固定请求头（UA / Referer / 鉴权等）
  final bool requiresLogin; // 如哔咔=true
  final bool isEnabled; // 用户可在源管理关闭
  final SourceTier tier;
  final String? proxy; // 可选代理

  const SourceConfig({
    required this.engineId,
    required this.id,
    required this.name,
    this.iconUrl,
    this.hosts = const [],
    this.imageHosts = const [],
    this.headers = const {},
    this.requiresLogin = false,
    this.isEnabled = true,
    this.tier = SourceTier.fallback,
    this.proxy,
  });

  factory SourceConfig.fromJson(Map<String, dynamic> j) => SourceConfig(
        engineId: (j['engineId'] as String?) ?? '',
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        iconUrl: j['iconUrl'] as String?,
        hosts: List<String>.from(j['hosts'] as List? ?? []),
        imageHosts: List<String>.from(j['imageHosts'] as List? ?? []),
        headers: Map<String, String>.from(j['headers'] as Map? ?? {}),
        requiresLogin: (j['requiresLogin'] as bool?) ?? false,
        isEnabled: (j['isEnabled'] as bool?) ?? true,
        tier: SourceTier.values.firstWhere(
          (e) => e.name == (j['tier'] as String? ?? 'fallback'),
          orElse: () => SourceTier.fallback,
        ),
        proxy: j['proxy'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'engineId': engineId,
        'id': id,
        'name': name,
        'iconUrl': iconUrl,
        'hosts': hosts,
        'imageHosts': imageHosts,
        'headers': headers,
        'requiresLogin': requiresLogin,
        'isEnabled': isEnabled,
        'tier': tier.name,
        'proxy': proxy,
      };
}

/// 源配置存储：内置默认 + 用户持久化覆盖。
///
/// 合并策略：以 [defaults] 为蓝本，用户保存过的配置按 engineId 覆盖对应字段。
/// 远程配置 [remoteUrl] 预留：域名过期时后台改一份 JSON 即可，免发版。
class SourceConfigStore {
  static const String _file = 'sources_config';

  /// 可选远程配置 URL（域名过期时后台更新，免发版）。预留接口，未设置时不拉取。
  static String? remoteUrl;

  static List<SourceConfig>? _cache;

  /// 内置默认配置（随 App 发布，保证开箱即用）。
  ///
  /// 注意：只有 JM 的 hosts 写在这里做演示；其余源若未配置 hosts，则回退到各自源实现里的内置值。
  static List<SourceConfig> defaults() => [
        const SourceConfig(
          engineId: 'doubao',
          id: 'doubao',
          name: '豆包漫画',
          tier: SourceTier.primary,
          hosts: ['https://www.doubaomanhua.com'],
          imageHosts: ['https://img.doubaomanhua.com'],
        ),
        const SourceConfig(
          engineId: 'baozi',
          id: 'baozi',
          name: '包子漫画',
          tier: SourceTier.primary,
          hosts: [
            'https://www.baozimh.com',
            'https://cn.bzmgcn.com',
            'https://www.bzmgcn.com',
          ],
          imageHosts: [
            'https://s1.bzcdn.net',
            'https://s2.bzcdn.net',
            'https://static-tw.bzmgcn.com',
          ],
        ),
        const SourceConfig(
          engineId: 'yyfun',
          id: 'yyfun',
          name: '樱漫(YYFun)',
          tier: SourceTier.primary,
          hosts: ['https://comifg.yy-fun.cc'],
        ),
        SourceConfig(
          engineId: 'jm',
          id: 'jm',
          name: '禁漫天堂',
          tier: SourceTier.fallback,
          hosts: const [
            'https://www.18comic.vg',
            'https://www.18comic.org',
            'https://www.cdnxxx-proxy.xyz',
            'https://jmcomic.xyz',
            'https://18comic.vg',
          ],
          imageHosts: const [
            'https://cdn-msp.comic18j-jobi.me',
            'https://cdn-msp2.comic18j-jobi.me',
            'https://cdn-msp3.comic18j-jobi.me',
          ],
        ),
        const SourceConfig(
          engineId: 'mangadex',
          id: 'mangadex',
          name: 'MangaDex',
          tier: SourceTier.fallback,
          hosts: ['https://api.mangadex.org'],
          imageHosts: ['https://uploads.mangadex.org'],
        ),
        const SourceConfig(
          engineId: 'agedm',
          id: 'agedm',
          name: 'AGE 动漫',
          tier: SourceTier.fallback,
          hosts: ['https://www.agedm.io'],
        ),
        const SourceConfig(
          engineId: 'tvtfun',
          id: 'tvtfun',
          name: 'TvTFun',
          tier: SourceTier.fallback,
          hosts: ['https://www.tvtfun.net'],
        ),
        const SourceConfig(
          engineId: 'biquge',
          id: 'biquge',
          name: '笔趣阁',
          tier: SourceTier.primary,
          hosts: [
            'https://www.tobiquge.com',
            'https://www.xbiquge.com',
          ],
        ),
      ];

  /// 合并后的全部配置（带缓存）。
  static Future<List<SourceConfig>> all() async {
    if (_cache != null) return _cache!;
    final raw = await _load();
    final defs = defaults();
    if (raw == null || raw.isEmpty) {
      _cache = defs;
      return _cache!;
    }
    final saved = raw.map((m) => SourceConfig.fromJson(m)).toList();
    final Map<String, SourceConfig> map = {
      for (final d in defs) d.engineId: d,
    };
    for (final s in saved) {
      if (map.containsKey(s.engineId)) map[s.engineId] = s;
    }
    _cache = map.values.toList();
    return _cache!;
  }

  static Future<SourceConfig> byEngine(String engineId) async =>
      (await all()).firstWhere(
        (c) => c.engineId == engineId,
        orElse: () => throw StateError('未找到源配置: $engineId'),
      );

  /// 取得某源的可用 hosts：用户配置优先，无则回退内置。
  static Future<List<String>> hostsFor(
    String engineId,
    List<String> fallback,
  ) async {
    try {
      final c = await byEngine(engineId);
      return c.hosts.isNotEmpty ? c.hosts : fallback;
    } catch (_) {
      return fallback;
    }
  }

  /// 取得某源的图片 CDN hosts。
  static Future<List<String>> imageHostsFor(
    String engineId,
    List<String> fallback,
  ) async {
    try {
      final c = await byEngine(engineId);
      return c.imageHosts.isNotEmpty ? c.imageHosts : fallback;
    } catch (_) {
      return fallback;
    }
  }

  /// 保存用户对某源的修改（保留其他源配置）。
  static Future<void> save(SourceConfig cfg) async {
    final list = await all();
    final idx = list.indexWhere((c) => c.engineId == cfg.engineId);
    if (idx >= 0) {
      list[idx] = cfg;
    } else {
      list.add(cfg);
    }
    _cache = list;
    await LocalStore.writeJson(
      _file,
      list.map((c) => c.toJson()).toList(),
    );
  }

  /// 失效缓存（如远程配置更新后调用）。
  static void invalidateCache() => _cache = null;

  /// 恢复内置默认配置（清空用户覆盖）。
  static Future<void> resetToDefaults() async {
    _cache = defaults();
    await LocalStore.writeJson(_file, const <Object>[]);
  }

  static Future<List<Map<String, dynamic>>?> _load() async {
    final data = await LocalStore.readJson(_file);
    if (data is List) {
      return data.whereType<Map<String, dynamic>>().toList();
    }
    return null;
  }
}
