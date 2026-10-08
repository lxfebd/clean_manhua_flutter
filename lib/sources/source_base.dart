import 'source_config.dart';

/// 数据源最小共享契约（漫画/视频/小说三接口的共同成员，P2-2 收敛）。
///
/// 三个域接口各自 extends 本基类，因此 [SourceManager] 的
/// `_enabledSorted<T extends AppSource>` 泛型过滤可同时作用于三者，
/// 消除 `enabledSources`/`enabledVideoSources`/`enabledNovelSources`
/// 三份逐字相同的实现。
abstract class AppSource {
  String get id;
  String get name;

  /// 是否需要登录（哔咔等）。默认 false，子类可覆盖。
  bool get requiresLogin => false;

  /// 是否启用（可由源管理页/配置控制）。默认 true。
  bool get isEnabled => true;

  /// 源优先级层级。默认 fallback。
  SourceTier get tier => SourceTier.fallback;
}
