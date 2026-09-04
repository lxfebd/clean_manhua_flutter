import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show kIsWeb, TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart' show Colors, Widget;
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart' as ww;

/// 当前平台是否有可用的内嵌 WebView 实现。
/// * Android/iOS/macOS：webview_flutter（官方实现）
/// * Windows：WebView2（webview_windows）。webview_flutter 没有 Windows
///   平台实现，直接用它只会渲染一个不可用的灰色占位块（历史灰屏 bug）。
/// * Linux/其他：无内嵌实现，播放页需走降级 UI。
bool get isWebViewSupported {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return true;
    default:
      return false;
  }
}

/// Windows 走 WebView2（webview_windows）实现。
bool get isWindowsWebView2 =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Windows 内嵌 WebView2 适配层：加载页面、执行 JS、加载/错误事件流。
///
/// 环境初始化时带 `--autoplay-policy=no-user-gesture-required`，
/// 让站点播放器无需用户手势即可出声自动播放（与移动端体验一致）。
class DesktopWebview {
  DesktopWebview();

  final ww.WebviewController controller = ww.WebviewController();
  bool _ready = false;

  static bool _envInited = false;

  static Future<void> _ensureEnvironment() async {
    if (_envInited) return;
    _envInited = true;
    try {
      final dir = await getApplicationSupportDirectory();
      await ww.WebviewController.initializeEnvironment(
        userDataPath: '${dir.path}${Platform.pathSeparator}webview2_data',
        additionalArguments: '--autoplay-policy=no-user-gesture-required',
      );
    } catch (_) {
      // 环境已初始化或参数不被接受：忽略，使用默认环境继续。
    }
  }

  Future<void> initialize({required String userAgent}) async {
    await _ensureEnvironment();
    await controller.initialize();
    await controller.setPopupWindowPolicy(ww.WebviewPopupWindowPolicy.deny);
    await controller.setBackgroundColor(Colors.black);
    try {
      await controller.setUserAgent(userAgent);
    } catch (_) {}
    _ready = true;
  }

  /// true = 正在加载/导航，false = 导航完成。
  Stream<bool> get loadingState =>
      controller.loadingState.map((s) => s == ww.LoadingState.loading);

  Stream<String> get url => controller.url;

  /// 导航失败时发出错误名（证书/超时/断网等）。
  Stream<String> get loadErrors => controller.onLoadError.map((e) => e.name);

  Future<void> loadUrl(String url) async {
    if (!_ready) return;
    await controller.loadUrl(url);
  }

  Future<void> reload() async {
    if (!_ready) return;
    await controller.reload();
  }

  /// 注入“文档创建时执行”的脚本（早于页面任何脚本），
  /// 用于拦截 fetch/XHR 的 resolve API，确保直链不丢。
  Future<void> injectOnDocumentCreated(String script) async {
    if (!_ready) return;
    try {
      await controller.addScriptToExecuteOnDocumentCreated(script);
    } catch (_) {}
  }

  static String _asExpression(String js) {
    var s = js.trim();
    while (s.endsWith(';')) {
      s = s.substring(0, s.length - 1).trimRight();
    }
    return s;
  }

  /// 执行 JS 并取回结果，对齐 webview_flutter 的
  /// runJavaScriptReturningResult。表达式求值结果若是字符串直接返回，
  /// 其他类型（对象/数组/数字）序列化为 JSON 字符串。
  Future<String?> evaluate(String js) async {
    if (!_ready) return null;
    try {
      final expr = _asExpression(js);
      final r = await controller.executeScript(expr);
      if (r == null) return null;
      if (r is String) return r;
      return jsonEncode(r);
    } catch (_) {
      return null;
    }
  }

  /// 执行 JS，忽略返回值，对齐 webview_flutter 的 runJavaScript。
  Future<void> runJavaScript(String js) async {
    if (!_ready) return;
    try {
      await controller.executeScript(js);
    } catch (_) {}
  }

  /// 内嵌渲染视图（Texture 方式，由 WebView2 绘制）。
  Widget buildView() => ww.Webview(controller);

  Future<void> dispose() async {
    if (_ready) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }
}
