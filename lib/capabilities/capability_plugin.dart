/// 能力插件：算力/功能型插件的元数据 + 生命周期契约（SourcePlugin 的泛化）。
///
/// 与 [SourcePlugin] 的差异（这是设计里反复强调的那条分界线）：
/// - 源插件 bind 挂进 SourceManager（数据源注册）；能力插件 bind 挂进
///   [CapabilityRuntime]（FFI 句柄 / Isolate / 模型权重）——生命周期钩子一样，
///   运行边界完全不同。
/// - 能力插件可携带原生构件（artifact：桌面直链 .dll/.dylib，Android 走
///   Maven/AAR 构建期纳入）与模型权重（weights：运行期下载到 .model_cache/）。
///
/// 生命周期时序：`manager.install(plugin)` → [onInstall] → [bind]（把实现正文
/// 挂进运行时）→ 启用/禁用切换 [onEnable]/[onDisable] → 卸载时 [unbind]（收回
/// 正文）→ [onUninstall]。
///
/// 本类为具体类：内置能力直接实例化（纯 Dart 壳，bind 空实现）；
/// 自定义/远端能力继承它并在 [bind]/[unbind] 里挂/收实现正文。
class CapabilityPlugin {
  /// 插件唯一 id（如 'ai.colorize.ddcolor'）。
  final String id;

  /// 展示名称（如「AI 上色」）。
  final String name;

  /// 能力分类：ai / video / utility。
  final String category;

  /// 版本号（如 '1.0.0'）。能力市场按 id + version 判定 需更新。
  final String version;

  /// 作者。
  final String author;

  /// 摘要描述。
  final String? description;

  /// 是否随版本发布的内置能力（不可卸载、不落盘、仅元数据壳）。
  final bool builtin;

  /// 展示排序（内置能力注册顺序，值越小越靠前）。
  final int rank;

  /// 原生构件声明（null = 纯 Dart 能力，无原生依赖）。
  final CapabilityArtifact? artifact;

  /// 模型权重声明（运行期下载到 .model_cache/，随能力生命周期管理）。
  final List<CapabilityWeight> weights;

  const CapabilityPlugin({
    required this.id,
    required this.name,
    required this.category,
    required this.version,
    required this.author,
    this.description,
    this.builtin = false,
    this.rank = 0,
    this.artifact,
    this.weights = const [],
  });

  /// 安装/卸载钩子。默认空实现，子类可覆盖做资源初始化/清理。
  Future<void> onInstall() async {}
  Future<void> onUninstall() async {}

  /// 启用/禁用钩子。
  Future<void> onEnable() async {}
  Future<void> onDisable() async {}

  /// 把实现正文挂进 CapabilityRuntime（install 时调用）。默认空实现（内置能力）。
  Future<void> bind() async {}

  /// 收回实现正文（uninstall 时调用）。默认空实现（内置能力）。
  Future<void> unbind() async {}

  /// 序列化为元数据快照（持久化 installed 集合用）。
  /// 只存纯数据字段：实现正文（artifact 二进制/权重文件）随市场安装流程
  /// 重建，不从快照恢复代码。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'category': category,
        'version': version,
        'author': author,
        'description': description,
        'builtin': builtin,
        'rank': rank,
        'weights': weights
            .map((w) => <String, dynamic>{
                  'name': w.name,
                  'url': w.url,
                  'sizeBytes': w.sizeBytes,
                  'sha256': w.sha256,
                })
            .toList(),
        if (artifact != null)
          'artifact': <String, dynamic>{
            if (artifact!.url != null) 'url': artifact!.url,
            if (artifact!.maven != null) 'maven': artifact!.maven,
            if (artifact!.jniLibsFile != null) 'jniLibsFile': artifact!.jniLibsFile,
            'embedded': artifact!.embedded,
            'sha256': artifact!.sha256,
          },
      };

  /// 从元数据快照重建市场能力实例（[CapabilityPluginManager.restore] 用）。
  /// 快照损坏/缺关键字段返回 null（跳过该条目，不阻断恢复）。
  static CapabilityPlugin? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    CapabilityWeight? weightFromJson(dynamic w) {
      if (w is! Map) return null;
      final wn = w['name'];
      final wu = w['url'];
      if (wn is! String || wn.isEmpty || wu is! String || wu.isEmpty) {
        return null;
      }
      return CapabilityWeight(
        name: wn,
        url: wu,
        sizeBytes: (w['sizeBytes'] as num?)?.toInt() ?? 0,
        sha256: (w['sha256'] as String?) ?? '',
      );
    }

    final weights = <CapabilityWeight>[];
    final wl = json['weights'];
    if (wl is List) {
      for (final w in wl) {
        final cw = weightFromJson(w);
        if (cw != null) weights.add(cw);
      }
    }
    CapabilityArtifact? artifact;
    final a = json['artifact'];
    if (a is Map) {
      final url = a['url'] as String?;
      final maven = a['maven'] as String?;
      final jniLibsFile = a['jniLibsFile'] as String?;
      final embedded = a['embedded'] == true;
      final sha = <String, String>{};
      final sm = a['sha256'];
      if (sm is Map) {
        sm.forEach((k, v) {
          if (k is String && v is String) sha[k] = v;
        });
      }
      artifact = CapabilityArtifact(
        url: (url == null || url.isEmpty) ? null : url,
        maven: (maven == null || maven.isEmpty) ? null : maven,
        jniLibsFile: (jniLibsFile == null || jniLibsFile.isEmpty)
            ? null
            : jniLibsFile,
        embedded: embedded,
        sha256: sha,
      );
    }
    return CapabilityPlugin(
      id: id,
      name: name,
      category: (json['category'] as String?) ?? 'utility',
      version: (json['version'] as String?) ?? '0.0.0',
      author: (json['author'] as String?) ?? '未知',
      description: json['description'] as String?,
      builtin: json['builtin'] == true,
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      artifact: artifact,
      weights: weights,
    );
  }
}

/// 原生构件声明：能力运行所需的动态库。
///
/// 分发渠道（设计 §12「三件绕不过的事」之一）：
/// - 桌面（Windows/macOS/Linux）：[url] 直链下载到应用支持目录 →
///   `DynamicLibrary.open(绝对路径)`（无 SELinux 限制，M2 先在这验证全链路）。
/// - Android：**只能构建期 bundle**（Android 7.0+ SELinux 禁止运行期裸 dlopen
///   应用私有目录下的 .so）。构建期纳入后，运行期从 APK `nativeLibraryDir`
///   复制 .so 到应用支持目录，SHA256 校验后 dlopen（复制到私有目录后 open
///   合法）。分发渠道：正式能力走 [maven] AAR（构建期依赖）；演示/内置走
///   [jniLibsFile] 的 jniLibs 打包（构建期进 `lib/<abi>/`）。
class CapabilityArtifact {
  /// 桌面直链（.dll/.dylib/.so）。
  final String? url;

  /// Android 分发：'groupId:artifactId:version'（Maven AAR）。
  final String? maven;

  /// Android jniLibs 打包的文件名（如 'libdemo_math.so'）：构建期经
  /// jniLibs 进 `lib/<abi>/`，运行期从 nativeLibraryDir 复制 + 校验。
  /// 非空时优先于 [maven]（演示/内置能力用）。
  final String? jniLibsFile;

  /// 是否随 App 构建期预打包（true 时不走下载/Maven，直接随 APK 发布）。
  final bool embedded;

  /// per-ABI SHA256：{'arm64-v8a': '…', 'x86_64': '…'}，加载前校验防损坏/篡改。
  final Map<String, String> sha256;

  const CapabilityArtifact({
    this.url,
    this.maven,
    this.jniLibsFile,
    this.embedded = false,
    this.sha256 = const {},
  });
}

/// 模型权重声明：能力运行所需的模型文件，运行期下载。
///
/// 统一进 `.model_cache/` 目录（项目红线：该目录保持为空，权重仅运行期下载，
/// 不入 git、不进 APK）。
class CapabilityWeight {
  /// 权重文件名（如 'ddcolor.tflite'）。
  final String name;

  /// 下载地址。
  final String url;

  /// 体积（字节，UI 展示下载大小）。
  final int sizeBytes;

  /// SHA256 校验，下载后验证，防损坏/篡改。
  final String sha256;

  const CapabilityWeight({
    required this.name,
    required this.url,
    required this.sizeBytes,
    required this.sha256,
  });
}
