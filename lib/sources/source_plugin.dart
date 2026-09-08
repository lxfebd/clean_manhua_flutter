/// 源插件元数据 + 生命周期契约。
///
/// 「插件化源」的分层约定：
/// - [SourcePlugin] 只描述一个源的存在（元数据）与生命周期（安装/卸载/启用/禁用），
///   不承载具体抓取逻辑——具体能力仍由各源实现类（[ComicSource]/[VideoSource]/[NovelSource]）提供，
///   插件的 [bind] 就是把这些实现挂进各自管理器，[unbind] 收回。
/// - 内置源（随版本发布的引擎代码）与自定义源（JSON DSL / 导入导出）统一走同一注册表，
///   由 [SourcePluginManager] 单例管理，持久化各自的启用状态。
///
/// 生命周期时序（以漫画源为例）：
/// `manager.install(plugin)` → [onInstall] → [bind] 把实现的正文注册进 ServiceManager
/// → 启用/禁用切换 [onEnable]/[onDisable] → 卸载时 [unbind] 收回正文 → [onUninstall]。
///
/// 本类为具体类：内置源直接用实例（纯元数据壳，bind/unbind 空实现）；
/// 自定义源继承它并在 [bind]/[unbind] 里挂/收实现正文。
class SourcePlugin {
  /// 插件唯一 id（如 'com.example.mysource'）。内置源用内置 id（'dm5' 等）。
  final String id;

  /// 展示名称（如「我的源」）。
  final String name;

  /// 插件类型标签：comic / video / novel / custom。
  final String type;

  /// 版本号（如 '1.0.0'）。自定义源导入时校验最低版本，避免旧数据不兼容。
  final String version;

  /// 作者。
  final String author;

  /// 摘要描述。
  final String? description;

  /// 是否随版本发布的内置源（不可卸载、不落盘、仅元数据壳）。
  final bool builtin;

  /// 展示排序（内置源注册顺序，值越小越靠前）。
  final int rank;

  const SourcePlugin({
    required this.id,
    required this.name,
    required this.type,
    required this.version,
    required this.author,
    this.description,
    this.builtin = false,
    this.rank = 0,
  });

  /// 安装/卸载钩子。默认空实现，子类可覆盖做资源初始化/清理。
  Future<void> onInstall() async {}
  Future<void> onUninstall() async {}

  /// 启用/禁用钩子。
  Future<void> onEnable() async {}
  Future<void> onDisable() async {}

  /// 把实现正文注册进对应管理器（install 时调用）。默认空实现（内置源）。
  Future<void> bind() async {}

  /// 收回实现正文（uninstall 时调用）。默认空实现（内置源）。
  Future<void> unbind() async {}
}