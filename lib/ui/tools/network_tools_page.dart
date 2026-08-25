import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../net/cf_ip_picker.dart';
import '../../net/http_client.dart';
import '../../sources/source_config.dart';

/// 网络查询类工具：DNS 查询、Ping 测试、IP 归属地、天气。
class NetworkToolsPage extends StatefulWidget {
  const NetworkToolsPage({super.key});

  @override
  State<NetworkToolsPage> createState() => _NetworkToolsPageState();
}

class _NetworkToolsPageState extends State<NetworkToolsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _dnsCtrl = TextEditingController(text: 'www.baidu.com');
  String _dnsOut = '';
  bool _busyDns = false;

  final _pingCtrl = TextEditingController(text: 'www.baidu.com');
  String _pingOut = '';
  bool _busyPing = false;

  final _ipCtrl = TextEditingController();
  String _ipOut = '';
  bool _busyIp = false;

  final _cityCtrl = TextEditingController(text: '北京');
  String _weatherOut = '';
  bool _busyWeather = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 6, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    _dnsCtrl.dispose();
    _pingCtrl.dispose();
    _ipCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _dnsLookup() async {
    final host = _dnsCtrl.text.trim();
    if (host.isEmpty) return;
    setState(() {
      _busyDns = true;
      _dnsOut = '';
    });
    try {
      final sw = Stopwatch()..start();
      final addrs = await InternetAddress.lookup(host);
      sw.stop();
      if (!mounted) return;
      setState(() {
        _dnsOut = '域名：$host\n耗时：${sw.elapsedMilliseconds} ms\n'
            '共 ${addrs.length} 条记录：\n'
            '${addrs.map((a) => '• ${a.address} (${a.type.name})').join('\n')}';
        _busyDns = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dnsOut = '查询失败：$e';
        _busyDns = false;
      });
    }
  }

  Future<void> _ping() async {
    final host = _pingCtrl.text.trim();
    if (host.isEmpty) return;
    setState(() {
      _busyPing = true;
      _pingOut = '';
    });
    final results = <String>[];
    final swTotal = Stopwatch()..start();
    for (var i = 0; i < 4; i++) {
      final sw = Stopwatch()..start();
      try {
        final socket = await Socket.connect(
          host,
          443,
          timeout: const Duration(seconds: 4),
        );
        socket.destroy();
        sw.stop();
        results.add('包 $i：${sw.elapsedMilliseconds} ms');
      } catch (e) {
        sw.stop();
        results.add('包 $i：失败（${e.runtimeType}）');
      }
      if (!mounted) return;
    }
    swTotal.stop();
    if (!mounted) return;
    final ok = results.where((r) => !r.contains('失败')).length;
    setState(() {
      _pingOut =
          '目标：$host:443\n${results.join('\n')}\n成功 $ok/4，总耗时 ${swTotal.elapsedMilliseconds} ms';
      _busyPing = false;
    });
  }

  Future<void> _ipLookup() async {
    final ip = _ipCtrl.text.trim();
    setState(() {
      _busyIp = true;
      _ipOut = '';
    });
    try {
      final resp = await Net.get(
        ip.isEmpty ? 'https://ipinfo.io/json' : 'https://ipinfo.io/$ip/json',
      );
      final j = jsonDecode(resp) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _ipOut = [
          'IP：${j['ip'] ?? '-'}',
          '城市：${j['city'] ?? '-'}',
          '地区：${j['region'] ?? '-'}',
          '国家：${j['country'] ?? '-'}',
          '组织：${j['org'] ?? '-'}',
          '时区：${j['timezone'] ?? '-'}',
          '位置：${j['loc'] ?? '-'}',
        ].join('\n');
        _busyIp = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ipOut = '查询失败：$e';
        _busyIp = false;
      });
    }
  }

  Future<void> _weather() async {
    final city = _cityCtrl.text.trim();
    if (city.isEmpty) return;
    setState(() {
      _busyWeather = true;
      _weatherOut = '';
    });
    try {
      final resp = await Net.get(
        'https://api.open-meteo.com/v1/forecast?latitude=39.9&longitude=116.4'
        '&current_weather=true&timezone=auto',
      );
      final j = jsonDecode(resp) as Map<String, dynamic>;
      final cw = j['current_weather'] as Map<String, dynamic>?;
      if (!mounted) return;
      setState(() {
        _weatherOut = cw == null
            ? '未获取到天气数据'
            : '城市：$city（经纬度查询）\n'
                '温度：${cw['temperature']}°C\n'
                '风速：${cw['windspeed']} km/h\n'
                '风向：${cw['winddirection']}°\n'
                '天气码：${cw['weathercode']}\n'
                '时间：${cw['time']}';
        _busyWeather = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _weatherOut = '查询失败：$e';
        _busyWeather = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('网络工具'),
        backgroundColor: scheme.surfaceContainerLowest,
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'DNS'),
            Tab(text: 'Ping'),
            Tab(text: 'IP 归属地'),
            Tab(text: '天气'),
            Tab(text: '优选IP'),
            Tab(text: '源检测'),
          ],
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: TabBarView(
          controller: _tab,
          children: [
            _buildDns(scheme),
            _buildPing(scheme),
            _buildIp(scheme),
            _buildWeather(scheme),
            const _CfPickerTab(),
            const _SourceCheckTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildDns(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        TextField(
          controller: _dnsCtrl,
          decoration: const InputDecoration(
            hintText: '输入域名，如 www.baidu.com',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _busyDns ? null : _dnsLookup,
          icon: _busyDns
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search_rounded, size: 18),
          label: const Text('DNS 查询'),
        ),
        if (_dnsOut.isNotEmpty) _outBox(scheme, _dnsOut),
      ],
    );
  }

  Widget _buildPing(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        TextField(
          controller: _pingCtrl,
          decoration: const InputDecoration(
            hintText: '输入主机名 / IP',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _busyPing ? null : _ping,
          icon: _busyPing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_ping_rounded, size: 18),
          label: const Text('Ping 4 次（TCP 443）'),
        ),
        if (_pingOut.isNotEmpty) _outBox(scheme, _pingOut),
      ],
    );
  }

  Widget _buildIp(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        TextField(
          controller: _ipCtrl,
          decoration: const InputDecoration(
            hintText: '输入 IP（留空则查询本机外网 IP）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _busyIp ? null : _ipLookup,
          icon: _busyIp
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.public_rounded, size: 18),
          label: const Text('IP 归属地查询'),
        ),
        if (_ipOut.isNotEmpty) _outBox(scheme, _ipOut),
      ],
    );
  }

  Widget _buildWeather(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        TextField(
          controller: _cityCtrl,
          decoration: const InputDecoration(
            hintText: '输入城市（当前按北京坐标查询）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _busyWeather ? null : _weather,
          icon: _busyWeather
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wb_sunny_outlined, size: 18),
          label: const Text('查询天气'),
        ),
        if (_weatherOut.isNotEmpty) _outBox(scheme, _weatherOut),
      ],
    );
  }

  Widget _outBox(ColorScheme scheme, String text) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: scheme.onSurface.withValues(alpha: 0.85)),
      ),
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
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = [];
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('扫描失败：$e')));
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已应用 $take 个优选 IP 到 $host，并已保存')));
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
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
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
                label: Text(d, style: const TextStyle(fontSize: 12)),
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
            style: TextStyle(
                fontSize: 12, color: scheme.onSurface.withValues(alpha: 0.6)),
          ),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('扫描结果（按延迟升序，最多显示 15 个）',
              style: TextStyle(
                  fontSize: 12,
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
                          style: TextStyle(
                              fontSize: 12,
                              color: scheme.primary.withValues(alpha: 0.8))),
                    ),
                    title: Text(_results[i].ip,
                        style: const TextStyle(fontSize: 13)),
                    trailing: Text('${_results[i].latencyMs} ms',
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.7))),
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
              style: TextStyle(
                  fontSize: 12,
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
        style: TextStyle(
            fontSize: 13,
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
      if (!mounted) return;
      setState(() {
        _busy = false;
        _results = [];
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('检测失败：$e')));
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
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        Text(
          '检测所有启用源的 HTTPS 连通性与延迟（TCP 443 + TLS 握手）。'
          '不可达的源可到「源管理」换镜像，或到「优选IP」加速。',
          style: TextStyle(
              fontSize: 12.5,
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
              style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.6))),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('结果（可达 ${_results.where((r) => r.ok).length}/${_results.length}）',
              style: TextStyle(
                  fontSize: 12,
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
    final okColor = r.ok ? const Color(0xFF34C759) : scheme.error;
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
                style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 8),
          Text(
            r.ok ? '${r.latencyMs} ms' : (r.error ?? '不可达'),
            style: TextStyle(
                fontSize: 12,
                color: r.ok
                    ? scheme.onSurface.withValues(alpha: 0.7)
                    : okColor),
          ),
        ],
      ),
    );
  }
}
