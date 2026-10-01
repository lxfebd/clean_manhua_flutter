import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/local_store.dart';

// ────────────────────────────────────────────────────────────────────────────
// 阅读器阅读偏好（Riverpod 渐进阶段D：以 provider 包住持久化偏好）。
//
// 与 readerModeProvider（阶段5）同模式：build() 给默认值 → resume() 幂等懒载
// 持久化 → update(...) 命名参数单项更新 + 相等短路 + 写回。页面在 init 时
// resume 一次，之后所有读写走 provider，不再直读/直写 LocalStore。
// ────────────────────────────────────────────────────────────────────────────

/// 小说阅读器六项阅读偏好（与 LocalStore.novel_read_settings 一一对应）。
class NovelReaderPrefs {
  /// 字号（默认 17）。
  final int fontSize;
  /// 行距倍数*100（默认 180）。
  final int lineHeight;
  /// 背景纸色：0=跟随主题 1=米白 2=浅绿 3=深青。
  final int theme;
  /// 段间距（px，默认 18）。
  final int paragraphGap;
  /// 首行缩进（默认 true）。
  final bool firstIndent;
  /// 色温 0~100（默认 0 = 无色温滤镜）。
  final int colorTemp;

  const NovelReaderPrefs({
    this.fontSize = 17,
    this.lineHeight = 180,
    this.theme = 0,
    this.paragraphGap = 18,
    this.firstIndent = true,
    this.colorTemp = 0,
  });

  NovelReaderPrefs copyWith({
    int? fontSize,
    int? lineHeight,
    int? theme,
    int? paragraphGap,
    bool? firstIndent,
    int? colorTemp,
  }) =>
      NovelReaderPrefs(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        theme: theme ?? this.theme,
        paragraphGap: paragraphGap ?? this.paragraphGap,
        firstIndent: firstIndent ?? this.firstIndent,
        colorTemp: colorTemp ?? this.colorTemp,
      );

  /// 值相等（update 的相等短路用：同值更新不写盘）。
  @override
  bool operator ==(Object other) =>
      other is NovelReaderPrefs &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.theme == theme &&
      other.paragraphGap == paragraphGap &&
      other.firstIndent == firstIndent &&
      other.colorTemp == colorTemp;

  @override
  int get hashCode => Object.hash(
      fontSize, lineHeight, theme, paragraphGap, firstIndent, colorTemp);
}

/// 小说阅读偏好全局 provider（懒加载：build 返回默认值，首次 resume 读盘）。
final novelReaderPrefsProvider =
    NotifierProvider<NovelReaderPrefsNotifier, NovelReaderPrefs>(
  NovelReaderPrefsNotifier.new,
);

/// 小说阅读偏好状态：resume 幂等懒载 + update 单项更新（相等短路写回）。
class NovelReaderPrefsNotifier extends Notifier<NovelReaderPrefs> {
  @override
  NovelReaderPrefs build() => const NovelReaderPrefs();

  bool _resumed = false;

  /// 从持久化恢复六项（幂等，页面 init 时调用一次）：已 resume 过则
  /// 直接返回当前值不重复读盘。
  Future<NovelReaderPrefs> resume() async {
    if (_resumed) return state;
    _resumed = true;
    state = NovelReaderPrefs(
      fontSize: await LocalStore.novelFontSize(),
      lineHeight: await LocalStore.novelLineHeight(),
      theme: await LocalStore.novelTheme(),
      paragraphGap: await LocalStore.novelParagraphGap(),
      firstIndent: await LocalStore.novelFirstIndent(),
      colorTemp: await LocalStore.novelColorTemp(),
    );
    return state;
  }

  /// 单项更新：相等短路（同值不写盘）+ 写回持久化。
  Future<void> update({
    int? fontSize,
    int? lineHeight,
    int? theme,
    int? paragraphGap,
    bool? firstIndent,
    int? colorTemp,
  }) async {
    final next = state.copyWith(
      fontSize: fontSize,
      lineHeight: lineHeight,
      theme: theme,
      paragraphGap: paragraphGap,
      firstIndent: firstIndent,
      colorTemp: colorTemp,
    );
    if (next == state) return;
    state = next;
    await LocalStore.setNovelReadSettings(
      fontSize: fontSize,
      lineHeight: lineHeight,
      theme: theme,
      paragraphGap: paragraphGap,
      firstIndent: firstIndent,
      colorTemp: colorTemp,
    );
  }
}

/// 漫画阅读器偏好（与 LocalStore.settings 对应键一一对应）。
class ComicReaderPrefs {
  /// 日漫 RTL 反向翻页（默认 false）。
  final bool rtl;
  /// 画质增强档位：0=无, 1=性能, 2=质量。
  final int resLevel;
  /// 自动翻页间隔（秒），0 = 关闭。
  final int autoPage;
  /// 自动裁边去白边（默认关）。
  final bool trimBorder;

  const ComicReaderPrefs({
    this.rtl = false,
    this.resLevel = 0,
    this.autoPage = 0,
    this.trimBorder = false,
  });

  ComicReaderPrefs copyWith({
    bool? rtl,
    int? resLevel,
    int? autoPage,
    bool? trimBorder,
  }) =>
      ComicReaderPrefs(
        rtl: rtl ?? this.rtl,
        resLevel: resLevel ?? this.resLevel,
        autoPage: autoPage ?? this.autoPage,
        trimBorder: trimBorder ?? this.trimBorder,
      );

  /// 值相等（update 的相等短路用：同值更新不写盘）。
  @override
  bool operator ==(Object other) =>
      other is ComicReaderPrefs &&
      other.rtl == rtl &&
      other.resLevel == resLevel &&
      other.autoPage == autoPage &&
      other.trimBorder == trimBorder;

  @override
  int get hashCode => Object.hash(rtl, resLevel, autoPage, trimBorder);
}

/// 漫画阅读偏好全局 provider（懒加载：build 返回默认值，首次 resume 读盘）。
final comicReaderPrefsProvider =
    NotifierProvider<ComicReaderPrefsNotifier, ComicReaderPrefs>(
  ComicReaderPrefsNotifier.new,
);

/// 漫画阅读偏好状态：resume 幂等懒载 + update 单项更新（相等短路写回）。
class ComicReaderPrefsNotifier extends Notifier<ComicReaderPrefs> {
  @override
  ComicReaderPrefs build() => const ComicReaderPrefs();

  bool _resumed = false;

  /// 从持久化恢复（幂等，阅读器/设置页 init 时调用一次）。
  Future<ComicReaderPrefs> resume() async {
    if (_resumed) return state;
    _resumed = true;
    state = ComicReaderPrefs(
      rtl: await LocalStore.rtlReader(),
      resLevel: await LocalStore.resLevel(),
      autoPage: await LocalStore.autoPageTurn(),
      trimBorder: await LocalStore.trimBorder(),
    );
    return state;
  }

  /// 单项更新：相等短路（同值不写盘）+ 写回持久化。
  Future<void> update({
    bool? rtl,
    int? resLevel,
    int? autoPage,
    bool? trimBorder,
  }) async {
    final next = state.copyWith(
      rtl: rtl,
      resLevel: resLevel,
      autoPage: autoPage,
      trimBorder: trimBorder,
    );
    if (next == state) return;
    state = next;
    if (rtl != null) await LocalStore.setRtlReader(rtl);
    if (resLevel != null) await LocalStore.setResLevel(resLevel);
    if (autoPage != null) await LocalStore.setAutoPageTurn(autoPage);
    if (trimBorder != null) await LocalStore.setTrimBorder(trimBorder);
  }
}
