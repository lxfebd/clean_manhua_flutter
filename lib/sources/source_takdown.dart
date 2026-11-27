/// 源下架清单（版本化）—— P0-06 的**执行层**。
///
/// ## 为什么要一个「能追到旧版本」的机制
/// [kSourceRegistrations] 是编译期快照：它只描述"发布那一刻的认知"。
/// 一旦某个源收到侵权投诉，光改代码发新版**不够**——已经装出去的旧版本
/// 仍会默认启用那个源。所以需要一个运行期可更新、带版本号的禁用清单：
/// 应用启动后拉到新清单，旧版本的 App 也会当场停止默认启用被下架的源。
///
/// 验收项要求完成一次「投诉 → 禁用索引 → 旧版本停止默认启用」演练，
/// 本文件就是那个「禁用索引」。
///
/// ## 数据形态
/// ```json
/// {
///   "version": 3,
///   "issuedAt": "2026-11-27T00:00:00Z",
///   "entries": [
///     {"sourceId": "jm", "action": "disable", "reason": "权利人投诉", "at": "2026-11-27"}
///   ]
/// }
/// ```
///
/// ## 语义（与 P0-01/P0-03 的 fail-closed 一致）
/// - **版本单调**：本地已有 version=N，远端 version<=N 时不回退（防回滚攻击：
///   否则攻击者给一份 version=0 的空清单就能让所有下架失效）。
/// - **禁用是单向的**：`disable` 只能让源更不可用，不能反过来启用。
///   远端清单里出现 `enable` 一律忽略——启用某个源必须靠新版 App 的登记册，
///   不能靠一份可被抓包的清单放宽限制。
/// - **只影响内置源的默认启用**：用户自己导入的自定义源（DSL 插件）不受此清单
///   约束，因为那不是本项目分发的内容。
/// - **拉取失败不阻塞启动**：清单拉不到就用本地缓存；本地也没有就按登记册走。
///   这不是安全边界（禁用清单是合规动作，不是安全断言），所以不做 fail-closed
///   阻断——把 App 锁死在某次网络失败上比漏掉一次下架更糟。
library;

import 'dart:convert';

import '../net/local_store.dart';

/// 一条下架指令的动作类型。
enum TakdownAction {
  /// 下架：该源不得默认启用（用户仍可在源管理页手动开启并自担风险）。
  disable,

  /// 仅预警：界面提示，但仍可默认启用（复核中）。
  warn,
}

TakdownAction _parseAction(String? raw) {
  switch (raw) {
    case 'disable':
      return TakdownAction.disable;
    case 'warn':
      return TakdownAction.warn;
    default:
      // 未知动作按「仅预警」处理，而不是 disable——避免一份畸形清单
      // 把全部源莫名关掉（拒真优于误伤）。清单是我们自己签发的，
      // 畸形更可能是 bug 而非攻击。
      return TakdownAction.warn;
  }
}

/// 单条下架记录。
class TakdownEntry {
  final String sourceId;
  final TakdownAction action;

  /// 下架原因（面向用户展示，可含投诉方/法务意见）。
  final String reason;

  /// 生效日期（YYYY-MM-DD）。
  final String at;

  const TakdownEntry({
    required this.sourceId,
    required this.action,
    required this.reason,
    required this.at,
  });

  static TakdownEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['sourceId'];
    if (id is! String || id.isEmpty) return null;
    return TakdownEntry(
      sourceId: id,
      action: _parseAction(raw['action'] as String?),
      reason: (raw['reason'] as String?) ?? '',
      at: (raw['at'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'action': action == TakdownAction.disable ? 'disable' : 'warn',
        'reason': reason,
        'at': at,
      };
}

/// 一份完整的下架清单。
class SourceTakdownList {
  /// 单调递增版本号。**只接受更大值**。
  final int version;

  final String issuedAt;

  final List<TakdownEntry> entries;

  const SourceTakdownList({
    required this.version,
    required this.issuedAt,
    required this.entries,
  });

  static const SourceTakdownList empty =
      SourceTakdownList(version: 0, issuedAt: '', entries: []);

  /// 解析失败一律返回 null（调用方保留旧缓存，绝不拿畸形清单覆盖好数据）。
  static SourceTakdownList? tryParse(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final v = decoded['version'];
    if (v is! int || v < 0) return null;
    final raw = decoded['entries'];
    if (raw != null && raw is! List) return null;
    final entries = <TakdownEntry>[];
    for (final e in (raw as List?) ?? const []) {
      final parsed = TakdownEntry.tryParse(e);
      // 单条坏数据跳过而不是整份作废：一条格式错不该让所有下架失效。
      if (parsed != null) entries.add(parsed);
    }
    return SourceTakdownList(
      version: v,
      issuedAt: (decoded['issuedAt'] as String?) ?? '',
      entries: entries,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'issuedAt': issuedAt,
        'entries': [for (final e in entries) e.toJson()],
      };

  /// 该源是否被**下架**（disable）。
  bool isDisabled(String sourceId) => entries.any(
      (e) => e.sourceId == sourceId && e.action == TakdownAction.disable);

  /// 该源是否只被**预警**（warn）。
  bool isWarned(String sourceId) => entries.any(
      (e) => e.sourceId == sourceId && e.action == TakdownAction.warn);

  /// 取该源的条目（便于界面展示原因）。
  TakdownEntry? entryOf(String sourceId) {
    for (final e in entries) {
      if (e.sourceId == sourceId) return e;
    }
    return null;
  }

  /// 合并：本清单里的 disable 是单向的。返回合并后的清单。
  ///
  /// 语义细节：同 id 既有 disable 又有 warn 时，**disable 胜**（更严格者优先）。
  SourceTakdownList mergedWith(SourceTakdownList other) {
    final byId = <String, TakdownEntry>{};
    void put(TakdownEntry e) {
      final cur = byId[e.sourceId];
      if (cur == null ||
          (cur.action == TakdownAction.warn && e.action == TakdownAction.disable)) {
        byId[e.sourceId] = e;
      }
    }

    for (final e in entries) {
      put(e);
    }
    for (final e in other.entries) {
      put(e);
    }
    return SourceTakdownList(
      version: version > other.version ? version : other.version,
      issuedAt: other.issuedAt.isNotEmpty ? other.issuedAt : issuedAt,
      entries: byId.values.toList(),
    );
  }
}

/// 下架清单的加载/缓存/更新。
///
/// 存储键：`source_takdown`（经 [LocalStore] 落到本地 JSON）。
class SourceTakdownStore {
  static const String _key = 'source_takdown';

  /// 清单地址（可指向仓库里的 raw 文件或自己的静态托管）。
  ///
  /// 留空 = 只用编译期内置清单 + 本地缓存，不做网络拉取。
  /// 之所以留空而不是写死一个 URL：本项目目前没有稳定的托管点，
  /// 写死一个不存在的地址只会产生启动期无谓超时。
  static String remoteUrl = '';

  static SourceTakdownList? _cache;

  /// 仅测试用：注入内存结果，绕过网络与磁盘。
  static void testSetCache(SourceTakdownList? v) => _cache = v;

  /// 仅测试用：重置（含 remoteUrl）。
  static void testReset() {
    _cache = null;
    remoteUrl = '';
  }

  /// 读取当前生效的清单（本地缓存优先，不与网络交互）。
  static Future<SourceTakdownList> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = await LocalStore.readJson(_key);
    if (raw is Map) {
      final parsed = SourceTakdownList.tryParse(jsonEncode(raw));
      if (parsed != null) {
        _cache = parsed;
        return parsed;
      }
    }
    _cache = SourceTakdownList.empty;
    return SourceTakdownList.empty;
  }

  /// 应用一份新清单。**版本必须更大**，否则忽略（防回滚）。
  ///
  /// 返回是否被采纳。
  static Future<bool> apply(SourceTakdownList next) async {
    final cur = await load();
    if (next.version <= cur.version) return false;
    _cache = next;
    await LocalStore.writeJson(_key, next.toJson());
    return true;
  }

  /// 尝试从 [remoteUrl] 拉取并应用。失败静默（见库注释：这不是安全边界）。
  ///
  /// 仅在 [remoteUrl] 非空时动作；返回是否采纳了新清单。
  static Future<bool> refresh({Duration timeout = const Duration(seconds: 8)}) async {
    if (remoteUrl.isEmpty) return false;
    try {
      final body = await _fetch(remoteUrl, timeout);
      if (body == null) return false;
      final parsed = SourceTakdownList.tryParse(body);
      if (parsed == null) return false;
      return await apply(parsed);
    } catch (_) {
      return false;
    }
  }

  /// 网络取文本的间接层。默认实现要 [LocalStore] 之外的 Net，但直接 import
  /// `net/http_client.dart` 会把平台通道拖进本文件的纯逻辑测试；
  /// 故由 `main.dart` 启动时注入（见 [injectFetcher]），测试也可替换。
  static Future<String?> Function(String url, Duration timeout) _fetch =
      (String url, Duration timeout) async => null;

  /// 注入真实网络实现。**必须在 App 启动时调用一次**，否则 [refresh] 恒返回 false
  /// （等价于「不做远端下架」，功能降级但不影响启动）。
  static void injectFetcher(
      Future<String?> Function(String url, Duration timeout) fn) {
    _fetch = fn;
  }

  /// 仅测试用：替换/恢复取数实现。
  static void testSetFetcher(
      Future<String?> Function(String url, Duration timeout)? fn) {
    _fetch = fn ?? ((url, timeout) async => null);
  }
}
