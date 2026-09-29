import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 校验可加载的站点 URL：仅允许 http/https，且必须可解析出主机名。
/// 成功返回规范化 [Uri]，非法时返回 null（由调用方决定错误文案）。
///
/// 导出为顶层函数以便单测直接覆盖校验逻辑（WebViewController 依赖平台通道，
/// 纯 Flutter 测试里难以实例化）。
Uri? validateWebviewUrl(String raw) {
  Uri? uri;
  try {
    uri = Uri.parse(raw);
  } catch (_) {
    return null;
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return null;
  }
  if (uri.host.trim().toLowerCase().isEmpty) {
    return null;
  }
  return uri;
}

/// 判断 [target] 是否属于 [allowedHost] 或其子域名（同主机）。
/// 用于把 JS 无限制的跨域导航收敛到当前站点，阻断外部跳转到任意页面。
bool isHostInScope(String allowedHost, Uri target) {
  final h = target.host.trim().toLowerCase();
  final a = allowedHost.trim().toLowerCase();
  if (h.isEmpty || a.isEmpty) return false;
  return h == a || h.endsWith('.$a');
}

/// 通用 WebView 页面：用于「站点入口」类工具（如 NekoGAL / 各平台官网），
/// 仅做页面加载与基本导航，不解析/不托管任何第三方内容。
///
/// 安全约束：仅接受 http/https；站内主框架导航放行（同主机及子域），
/// 跨域主框架导航一律拦截并交由系统浏览器打开，避免把 unrestricted JS
/// 上下文扩散到任意外部站点。子框架（iframe）保持原行为，避免误伤站内嵌入。
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
  String? _error;

  /// 合法站点 URI；scheme 非法时为 null（仅展示错误态，不加载任何内容）。
  late final Uri? _validUri;

  @override
  void initState() {
    super.initState();
    final uri = validateWebviewUrl(widget.url);
    if (uri == null) {
      // scheme 非法或解析失败：拒绝加载，走错误态。
      // 仍需构造控制器以让 build() 里的 WebViewWidget 有对象可用，
      // 但禁用 JS 且不调用 loadRequest，杜绝任何远程内容被拉取。
      _validUri = null;
      _ctrl = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.disabled)
        ..setBackgroundColor(Colors.white);
      _loading = false;
      _error = '加载失败：不支持的链接地址';
      return;
    }
    _validUri = uri;
    _ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // 只拦截主框架导航；子框架（iframe）放行以保持原行为。
            if (!request.isMainFrame) return NavigationDecision.navigate;
            final target = Uri.tryParse(request.url);
            if (target == null ||
                (target.scheme != 'http' && target.scheme != 'https')) {
              // 非 http(s) 主框架导航（file:/javascript: 等）一律拦截。
              return NavigationDecision.prevent;
            }
            // 站点内部（同主机/子域）放行；跨域主框架导航交给系统浏览器。
            if (isHostInScope(uri.host, target)) {
              return NavigationDecision.navigate;
            }
            _openInBrowser(target);
            return NavigationDecision.prevent;
          },
          onPageStarted: (_) {
            if (mounted) setState(() { _loading = true; _error = null; });
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = '加载失败：${e.description}';
              });
            }
          },
        ),
      )
      ..loadRequest(uri);
  }

  /// 用系统浏览器打开外部站点（url_launcher），避免在 WebView 里跨域导航。
  /// 位置参数可省略：AppBar 按钮以 tear-off（`onPressed: _openInBrowser`）方式
  /// 传入时不接受参数，故默认回退到当前站点。
  Future<void> _openInBrowser([Uri? target]) async {
    final uri = target ?? _validUri ?? Uri.tryParse(widget.url);
    if (uri == null) return;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? widget.url : widget.title),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              setState(() { _error = null; _loading = true; });
              _ctrl.reload();
            },
          ),
          IconButton(
            tooltip: '浏览器打开',
            icon: const Icon(Icons.open_in_browser_rounded),
            onPressed: _openInBrowser,
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
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_rounded,
                        size: 48, color: scheme.onSurface.withValues(alpha: 0.3)),
                    const SizedBox(height: 12),
                    Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() { _error = null; _loading = true; });
                        _ctrl.reload();
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重试'),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _openInBrowser,
                      icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                      label: const Text('在浏览器中打开'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
