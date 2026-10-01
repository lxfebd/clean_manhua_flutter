import 'package:flutter/material.dart';

import '../../net/error_logger.dart';
import '../../net/webdav_sync.dart';

/// WebDAV 同步配置面板：服务器地址 / 账号 / 目录 / 加密开关 / 上传下载。
class WebDavSheet extends StatefulWidget {
  final VoidCallback onChanged;
  const WebDavSheet({super.key, required this.onChanged});

  @override
  State<WebDavSheet> createState() => WebDavSheetState();
}

class WebDavSheetState extends State<WebDavSheet> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _dirCtrl = TextEditingController();
  bool _encrypt = true;
  bool _busy = false;
  String? _status;
  bool _statusOk = false;

  @override
  void initState() {
    super.initState();
    final c = WebDavSync.config;
    if (c != null) {
      _urlCtrl.text = c['url'] as String? ?? '';
      _userCtrl.text = c['username'] as String? ?? '';
      _passCtrl.text = ''; // 明文密码不落盘；有密码时用「已设置」占位提示
      _dirCtrl.text = c['dir'] as String? ?? '';
      _encrypt = (c['encrypt'] as bool?) ?? true;
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(
    String label,
    Future<void> Function() fn, {
    String ok = '',
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await fn();
      if (mounted) {
        setState(() {
          _status = ok.isEmpty ? '完成' : ok;
          _statusOk = true;
        });
      }
      widget.onChanged();
    } catch (e) {
      if (mounted) {
        setState(() {
          // 具体错误直接上屏（WebDavException 已含状态码+响应体摘要，
          // 网络异常含主机信息）：原「请检查网络后重试」掩盖了
          // 401/403/404 等可操作的真实原因，用户只能盲目重试。
          _status = _humanError('$label失败', e);
          _statusOk = false;
        });
      }
      ErrorLogger.instance.warn('webdav $label failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 把异常转成可上屏的一行提示：WebDavException 用其状态码+摘要，
  /// 其余（SocketException/TimeoutException/自定义 Exception）取 toString
  /// 主体并截断，避免超长堆栈信息进 UI。
  static String _humanError(String prefix, Object e) {
    final raw = e is WebDavException ? e.toString() : e.toString();
    final msg = raw.length > 160 ? '${raw.substring(0, 160)}…' : raw;
    return '$prefix：$msg';
  }

  /// 保存配置：先探测连通性（URL/账号/密码一次性校验），失败红字提示、
  /// 不写配置不关面板；成功才落盘。
  Future<void> _save() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() {
        _status = '请填写 WebDAV 服务器地址';
        _statusOk = false;
      });
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '正在连接服务器…';
      _statusOk = false;
    });
    // 阶段标记：区分「连接探测失败」和「配置落盘失败」，让用户知道
    // 该改服务器地址还是该清磁盘空间。声明在 try 外，catch 分支可访问。
    var stage = 'probe';
    try {
      // 密码框留空 = 沿用已存密码（WebDavSync 内部处理），探测时同样沿用。
      final pass =
          _passCtrl.text.isEmpty
              ? (WebDavSync.config?['password'] as String? ?? '')
              : _passCtrl.text;
      if (pass.isEmpty && _userCtrl.text.trim().isNotEmpty) {
        // 有账号但没密码：绝大多数 WebDAV 服务（坚果云/Nextcloud）都要求
        // 认证，空密码探测只会得到 401/403，这里直接提示避免误伤。
        setState(() {
          _status = '请输入密码（或应用密码）';
          _statusOk = false;
        });
        return;
      }
      await WebDavSync.probe(
        url: url,
        username: _userCtrl.text.trim(),
        password: pass,
        dir: _dirCtrl.text.trim(),
      );
      // 必须 await：saveConfig 落盘失败（磁盘满/权限）时会抛异常，若不等待
      // 会误报「已保存」并关面板，重启后配置丢失。
      stage = 'save';
      await WebDavSync.saveConfig(
        url: url,
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
        dir: _dirCtrl.text.trim(),
        encrypt: _encrypt,
      );
      widget.onChanged();
      if (mounted) {
        setState(() {
          _status = '已保存并验证连接';
          _statusOk = true;
        });
        // 先置状态再关面板（context 在 async gap 后已用 mounted 校验）
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      if (mounted) {
        final saveFailed = stage == 'save';
        setState(() {
          _status = saveFailed
              ? '配置保存失败，请检查存储权限后重试'
              : '连接失败，请检查网络后重试';
          _statusOk = false;
        });
      }
      ErrorLogger.instance.error(
        'webdav 保存配置失败: $e',
        error: e,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_sync_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'WebDAV 同步',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '把收藏、阅读进度、设置同步到你的 WebDAV 网盘\n'
              '（坚果云 / Nextcloud / 群晖 WebDAV 等），实现多端同步。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'https://dav.jianguoyun.com/dav/',
                prefixIcon: Icon(Icons.link_rounded, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _userCtrl,
                    decoration: const InputDecoration(
                      labelText: '账号',
                      prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '密码 / 应用密码',
                      prefixIcon: Icon(Icons.key_rounded, size: 20),
                      border: OutlineInputBorder(),
                      isDense: true,
                      hintText: WebDavSync.hasPassword ? '已设置（留空保持不变）' : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _dirCtrl,
              decoration: const InputDecoration(
                labelText: '保存目录（可选）',
                hintText: 'Apps/星漫匣',
                prefixIcon: Icon(Icons.folder_outlined, size: 20),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '加密同步文件（AES-256-GCM，口令不落盘）',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Switch(
                  value: _encrypt,
                  onChanged: (v) => setState(() => _encrypt = v),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存配置'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _busy
                            ? null
                            : () => _run(
                              '上传',
                              () => WebDavSync.push(),
                              ok: '已上传到 WebDAV',
                            ),
                    icon: const Icon(Icons.upload_rounded, size: 18),
                    label: const Text('上传同步'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _confirmPull(),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('从 WebDAV 拉取并覆盖本地'),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: (_statusOk ? scheme.primary : scheme.error).withValues(
                    alpha: 0.08,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      _statusOk
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 18,
                      color: _statusOk ? scheme.primary : scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status!,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmPull() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: const Text('拉取远端数据'),
            content: const Text(
              '将用 WebDAV 上的数据覆盖本地的收藏、历史、进度和设置。'
              '本地上传之后的新改动会被覆盖，确定继续？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('拉取并覆盖'),
              ),
            ],
          ),
    );
    if (ok != true || !mounted) return;
    await _run('拉取', () async {
      await WebDavSync.pull();
      await WebDavSync.recordPull();
    }, ok: '已从 WebDAV 恢复数据');
  }
}