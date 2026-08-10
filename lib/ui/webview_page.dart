import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 通用 WebView 页面：用于「站点入口」类工具（如 NekoGAL / 各平台官网），
/// 仅做页面加载与基本导航，不解析/不托管任何第三方内容。
class WebviewPage extends StatefulWidget {
  final String url;
  final String title;
  const WebviewPage({super.key, required this.url, this.title = ''});

  @override
  State<WebviewPage> createState() => _WebviewPageState();
}

class _WebviewPageState extends State<WebviewPage> {
  late final WebViewController _ctrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => setState(() => _loading = false),
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? widget.url : widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _ctrl.reload(),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_browser_rounded),
            onPressed: () => _ctrl.loadRequest(Uri.parse(widget.url)),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _ctrl),
          if (_loading)
            Center(
              child: CircularProgressIndicator(
                color: scheme.primary.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
    );
  }
}
