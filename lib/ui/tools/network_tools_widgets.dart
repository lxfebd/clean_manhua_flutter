part of 'network_tools_page.dart';

class _ProxyTab extends StatefulWidget {
  final String? proxy;
  final ValueChanged<String?> onChanged;
  const _ProxyTab({required this.proxy, required this.onChanged});

  @override
  State<_ProxyTab> createState() => _ProxyTabState();
}

class _ProxyTabState extends State<_ProxyTab> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.proxy ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = (widget.proxy ?? '').isNotEmpty;
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 16,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
      children: [
        Text(
          '为全部网络请求设置代理（漫画/小说/视频/图片/下载）。'
          '格式：http://127.0.0.1:7890（仅支持 HTTP 隧道代理，'
          'dart:io 不支持 socks5/socks4，请勿填写 socks:// 地址）。'
          '启用代理后 Android 端自动跳过 Cronet 快速路径，保证代理生效。',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(
                height: 1.5,
                color: scheme.onSurface.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ctrl,
          decoration: InputDecoration(
            hintText: 'http://127.0.0.1:7890',
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: active
                ? IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.clear_rounded, size: 18),
                    onPressed: () {
                      _ctrl.clear();
                      widget.onChanged(null);
                    },
                  )
                : null,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  final v = _ctrl.text.trim();
                  if (v.isEmpty) return;
                  widget.onChanged(v);
                },
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('应用代理'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  _ctrl.clear();
                  widget.onChanged(null);
                },
                icon: const Icon(Icons.remove_circle_outline, size: 18),
                label: const Text('直连'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: active
                    ? scheme.primary.withValues(alpha: 0.35)
                    : scheme.onSurface.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              Icon(
                active ? Icons.vpn_key_rounded : Icons.link_off_rounded,
                size: 16,
                color:
                    active ? scheme.primary : scheme.onSurface.withValues(alpha: 0.4),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  active ? '代理已启用：${widget.proxy}' : '当前直连（未启用代理）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.85)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 优选 IP：对指定域名并发探测 Cloudflare 节点，挑选低延迟 IP 直连加速。
/// 应用结果写入 [Net.preferredHostIps] 并持久化，重启自动恢复。
class _CfPickerTab extends StatefulWidget {
  const _CfPickerTab();

  @override
  State<_CfPickerTab> createState() => _CfPickerTabState();
}

class _CfPickerTabState extends State<_CfPickerTab> {
  static const List<String> _knownDomains = ['www.tvtfun.net'];

  final _domainCtrl = TextEditingController(text: 'www.tvtfun.net');
  bool _busy = false;
  int _done = 0;
  int _total = 0;
  List<CfIpResult> _results = [];
  int _applyCount = 6;
  String _appliedDomain = '';
  List<String> _appliedIps = [];

  @override
  void initState() {
    super.initState();
    _refreshApplied();
  }

  @override
  void dispose() {
    _domainCtrl.dispose();
    super.dispose();
  }

  String get _host => _domainCtrl.text.trim();

  void _refreshApplied() {
    final host = _host;
    _appliedDomain = host;
    _appliedIps = Net.preferredHostIps[host] ?? [];
  }

  Future<void> _scan() async {
    final host = _host;
    if (host.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _results = [];
      _done = 0;
      _total = 0;
    });
    try {
      final ips = await CfIpPicker.candidateIps();
      if (!mounted) return;
      setState(() => _total = ips.length);
      final res = await CfIpPicker.probe(host, ips, onProgress: (d, t) {
        if (mounted) {
          setState(() {
            _done = d;
            _total = t;
          });
        }
      });
      if (!mounted) return;
      setState(() {
        _results = res.take(15).toList();
        _busy = false;
      });
    } catch (e) {
      ErrorLogger.instance.warn('lan scan failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = [];
      });
      AppToast.error(context, '扫描失败，请重试');
    }
  }

  Future<void> _apply() async {
    if (_results.isEmpty) return;
    final host = _host;
    if (host.isEmpty) return;
    final take = _applyCount > _results.length ? _results.length : _applyCount;
    final ips = _results.take(take).map((r) => r.ip).toList();
    Net.preferredHostIps[host] = ips;
    await Net.savePreferredHostIps();
    if (!mounted) return;
    setState(() {
      _appliedDomain = host;
      _appliedIps = ips;
    });
    AppToast.info(context, '已应用 $take 个优选 IP 到 $host，并已保存');
  }

  Future<void> _clearApplied() async {
    final host = _host;
    if (host.isEmpty) return;
    Net.preferredHostIps.remove(host);
    await Net.savePreferredHostIps();
    if (!mounted) return;
    setState(() {
      _appliedDomain = host;
      _appliedIps = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 16,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
      children: [
        TextField(
          controller: _domainCtrl,
          onChanged: (_) => setState(_refreshApplied),
          decoration: const InputDecoration(
            hintText: '输入需加速的域名，如 www.tvtfun.net',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final d in _knownDomains)
              ActionChip(
                label: Text(d,
                    style: Theme.of(context).textTheme.bodySmall),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _domainCtrl.text = d;
                  setState(_refreshApplied);
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _busy ? null : _scan,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_tethering_rounded, size: 18),
          label: Text(_busy ? '扫描中…' : '扫描优选 IP'),
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 6),
          Text(
            '已探测 $_done/$_total 个候选 IP',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('扫描结果（按延迟升序，最多显示 15 个）',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _results.length; i++)
                  ListTile(
                    dense: true,
                    leading: SizedBox(
                      width: 28,
                      child: Text('${i + 1}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: scheme.primary
                                      .withValues(alpha: 0.8))),
                    ),
                    title: Text(_results[i].ip,
                        style: Theme.of(context).textTheme.bodyMedium),
                    trailing: Text('${_results[i].latencyMs} ms',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                                color: scheme.onSurface
                                    .withValues(alpha: 0.7))),
                    onTap: () => setState(() => _applyCount = i + 1),
                    selected: i < _applyCount,
                    selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.4),
                    shape: i < _results.length - 1
                        ? Border(
                            bottom: BorderSide(
                                color:
                                    scheme.onSurface.withValues(alpha: 0.06)))
                        : null,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _apply,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text('应用前 $_applyCount 个'),
                ),
              ),
            ],
          ),
        ],
        if (_appliedIps.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('$_appliedDomain 当前直连 IP（$_appliedIps.length 个）',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 6),
          _outBox(scheme, _appliedIps.join('\n')),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _clearApplied,
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('清除该域名的优选 IP（恢复系统 DNS）'),
          ),
        ],
      ],
    );
  }

  Widget _outBox(ColorScheme scheme, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      child: SelectableText(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            height: 1.5,
            color: scheme.onSurface.withValues(alpha: 0.85)),
      ),
    );
  }
}

/// 单个源的连通性检测结果。
class _SrcCheck {
  final String name;
  final String host;
  final bool ok;
  final int latencyMs; // -1 = 不可达
  final String? error;

  const _SrcCheck(this.name, this.host, this.ok, this.latencyMs, this.error);
}

/// 源检测：并发探测所有启用源的主机（TCP 443 + TLS 握手），标记连通性与延迟。
/// 帮助用户快速判断当前网络下哪些源可用，配合多源回退使用。
class _SourceCheckTab extends StatefulWidget {
  const _SourceCheckTab();

  @override
  State<_SourceCheckTab> createState() => _SourceCheckTabState();
}

class _SourceCheckTabState extends State<_SourceCheckTab> {
  static const int _concurrency = 6;

  bool _busy = false;
  int _done = 0;
  int _total = 0;
  List<_SrcCheck> _results = [];

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _results = [];
      _done = 0;
      _total = 0;
    });
    try {
      final cfgs = await SourceConfigStore.all();
      final targets = <({String name, String host})>[];
      for (final c in cfgs) {
        if (!c.isEnabled || c.tier == SourceTier.disabled) continue;
        for (final h in c.hosts) {
          final host = Uri.tryParse(h)?.host;
          if (host == null || host.isEmpty) continue;
          targets.add((name: c.name, host: host));
        }
      }
      if (!mounted) return;
      setState(() => _total = targets.length);

      final results = <_SrcCheck>[];
      var next = 0;
      var done = 0;

      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= targets.length) return;
          final t = targets[i];
          final r = await _probe(t.name, t.host);
          results.add(r);
          done++;
          if (mounted) {
            setState(() => _done = done);
          }
        }
      }

      await Future.wait(List.generate(_concurrency, (_) => worker()));
      // 可达优先、延迟升序，再按名称分组
      results.sort((a, b) {
        if (a.ok != b.ok) return a.ok ? -1 : 1;
        if (a.latencyMs != b.latencyMs) return a.latencyMs.compareTo(b.latencyMs);
        return a.name.compareTo(b.name);
      });
      if (!mounted) return;
      setState(() {
        _results = results;
        _busy = false;
      });
    } catch (e) {
      ErrorLogger.instance.warn('src detect failed: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = [];
      });
      AppToast.error(context, '检测失败，请重试');
    }
  }

  /// 单主机探测：DNS 解析 + TCP 443 + TLS 握手（SNI=host，忽略证书校验）。
  Future<_SrcCheck> _probe(String name, String host) async {
    final sw = Stopwatch()..start();
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 4));
      if (addrs.isEmpty) {
        return _SrcCheck(name, host, false, -1, 'DNS 无记录');
      }
      final raw = await Socket.connect(addrs.first, 443,
              timeout: const Duration(seconds: 5));
      try {
        final secure = await SecureSocket.secure(raw,
                host: host, onBadCertificate: (_) => true)
            .timeout(const Duration(seconds: 5));
        sw.stop();
        secure.destroy();
        return _SrcCheck(name, host, true, sw.elapsedMilliseconds, null);
      } catch (e) {
        raw.destroy();
        return _SrcCheck(name, host, false, -1, _short(e));
      }
    } catch (e) {
      sw.stop();
      return _SrcCheck(name, host, false, -1, _short(e));
    }
  }

  String _short(Object e) {
    final s = e.toString();
    final idx = s.indexOf(':');
    return idx > 0 ? s.substring(0, idx) : s;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 16,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
      children: [
        Text(
          '检测所有启用源的 HTTPS 连通性与延迟（TCP 443 + TLS 握手）。'
          '不可达的源可到「源管理」换镜像，或到「优选IP」加速。',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(
                height: 1.5,
                color: scheme.onSurface.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _busy ? null : _check,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.health_and_safety_outlined, size: 18),
          label: Text(_busy ? '检测中…' : '开始检测'),
        ),
        if (_busy) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
              value: _total == 0 ? null : _done / _total),
          const SizedBox(height: 6),
          Text('已检测 $_done/$_total 个主机',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6))),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('结果（可达 ${_results.where((r) => r.ok).length}/${_results.length}）',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _results.length; i++)
                  _resultRow(scheme, _results[i],
                      isLast: i == _results.length - 1),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _resultRow(ColorScheme scheme, _SrcCheck r,
      {required bool isLast}) {
    final okColor = r.ok ? Colors.green : scheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: isLast
          ? null
          : BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: scheme.onSurface.withValues(alpha: 0.06)))),
      child: Row(
        children: [
          Icon(
            r.ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            size: 16,
            color: okColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${r.name} · ${r.host}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 8),
          Text(
            r.ok ? '${r.latencyMs} ms' : (r.error ?? '不可达'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: r.ok
                    ? scheme.onSurface.withValues(alpha: 0.7)
                    : okColor),
          ),
        ],
      ),
    );
  }
}
