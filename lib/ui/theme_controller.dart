import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/local_store.dart';
import 'style_scope.dart';

/// 主题/风格全局状态（Riverpod 渐进批次 C 第一阶段）。
///
/// 迁移自 [YingManHeAppState] 的四字段（`_themeMode`/`_themeId`/
/// `_uiStyleOverride`/`_loaded`）：原 setState 同步生效 → 这里
/// StateNotifier 同步改 state；原「先 setState 立即生效 → 再异步落盘」
/// 的双写拆成：setter 只改内存（UI 立即重建），持久化由调用方自行
/// `LocalStore.setXxx`（与旧调用点语义一致，避免把 IO 塞进 setter 造成
/// 测试时序不稳）。
///
/// 语义对齐旧实现：
/// - `_loaded` 保持「首帧前不闪深色」：ProviderScope 下 build 先 watch
///   state，load 完成前 `loaded=false` → 一律 light；
/// - null 风格 = 跟随平台（[UIStyle.forPlatform] 在读取侧解析，不入 controller）。
class ThemeController extends StateNotifier<ThemeState> {
  ThemeController() : super(const ThemeState());

  /// 异步装载持久化主题（启动时调一次；失败保持默认值，不闪错）。
  Future<void> load() async {
    try {
      final d = await LocalStore.darkMode();
      final tid = await LocalStore.themeId();
      final styleId = await LocalStore.uiStyle();
      state = ThemeState(
        themeMode: d ? ThemeMode.dark : ThemeMode.light,
        themeId: tid,
        uiStyleOverride: styleId == null ? null : UIStyle.fromId(styleId),
        loaded: true,
      );
    } catch (_) {
      // 本地读取异常：保持默认值（light/0/跟随平台），不抛给启动链。
      state = state.copyWith(loaded: true);
    }
  }

  void setDark(bool v) {
    state = state.copyWith(
        themeMode: v ? ThemeMode.dark : ThemeMode.light);
  }

  void setThemeId(int id) {
    state = state.copyWith(themeId: id);
  }

  /// 切换 UI 风格：null 表示「跟随平台」，否则固定到指定风格。
  void setUiStyle(UIStyle? style) {
    state = state.copyWith(
      uiStyleOverride: style,
      clearUiStyleOverride: style == null,
    );
  }
}

/// 主题/风格全局状态（不可变快照，便于测试逐字段断言）。
class ThemeState {
  const ThemeState({
    this.themeMode = ThemeMode.light,
    this.themeId = 0,
    this.uiStyleOverride,
    this.loaded = false,
  });

  final ThemeMode themeMode;
  final int themeId;

  /// 用户手动覆盖的 UI 风格；null = 跟随平台（[UIStyle.forPlatform] 自动映射）。
  final UIStyle? uiStyleOverride;

  /// 持久化装载是否完成；完成前一律按浅色渲染（首帧不闪深色）。
  final bool loaded;

  /// 当前生效风格（跟随平台时由 [UIStyle.forPlatform] 解析）。
  UIStyle get effectiveStyle =>
      uiStyleOverride ?? UIStyle.forPlatform(defaultTargetPlatform);

  ThemeState copyWith({
    ThemeMode? themeMode,
    int? themeId,
    UIStyle? uiStyleOverride,
    bool clearUiStyleOverride = false,
    bool? loaded,
  }) {
    return ThemeState(
      themeMode: themeMode ?? this.themeMode,
      themeId: themeId ?? this.themeId,
      uiStyleOverride: clearUiStyleOverride
          ? null
          : uiStyleOverride ?? this.uiStyleOverride,
      loaded: loaded ?? this.loaded,
    );
  }
}

/// 全局主题/风格 provider（挂 ProviderScope 内，见 main.dart）。
final themeControllerProvider =
    StateNotifierProvider<ThemeController, ThemeState>(
  (ref) => ThemeController(),
);
