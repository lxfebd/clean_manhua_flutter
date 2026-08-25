import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'net/bookshelf_store.dart';
import 'net/http_client.dart';
import 'net/local_store.dart';
import 'net/novel_shelf_store.dart';
import 'theme.dart';
import 'ui/main_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize = 20;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 30 * 1024 * 1024;
  try {
    MediaKit.ensureInitialized();
  } catch (_) {}
  try {
    await LocalStore.init();
  } catch (_) {}
  try {
    await Net.restorePreferredHostIps();
  } catch (_) {}
  try {
    final dir = await getApplicationSupportDirectory();
    BookshelfStore.bindFile(File('${dir.path}/bookshelf.json'));
    NovelShelfStore.bindFile(File('${dir.path}/novel_shelf.json'));
  } catch (_) {}
  runApp(const YingManHeApp());
}

class YingManHeApp extends StatefulWidget {
  const YingManHeApp({super.key});

  /// 供设置页调用以立即生效主题。
  static YingManHeAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<YingManHeAppState>();

  @override
  State<YingManHeApp> createState() => YingManHeAppState();
}

class YingManHeAppState extends State<YingManHeApp> {
  ThemeMode _themeMode = ThemeMode.light;
  int _themeId = 0;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final d = await LocalStore.darkMode();
    final tid = await LocalStore.themeId();
    if (mounted) {
      setState(() {
        _themeMode = d ? ThemeMode.dark : ThemeMode.light;
        _themeId = tid;
        _loaded = true;
      });
    }
  }

  void setDark(bool v) {
    setState(() => _themeMode = v ? ThemeMode.dark : ThemeMode.light);
  }

  void setThemeId(int id) {
    setState(() => _themeId = id);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '星漫匣',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(_themeId),
      darkTheme: AppTheme.dark(_themeId),
      themeMode: _loaded ? _themeMode : ThemeMode.light,
      home: const MainShell(),
    );
  }
}
