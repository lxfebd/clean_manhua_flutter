import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../net/cf_ip_picker.dart';
import '../../net/error_logger.dart';
import '../../net/http_client.dart';
import '../../sources/source_config.dart';
import '../responsive.dart';
import '../widgets/app_toast.dart';

part 'network_tools_widgets.dart';

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

  /// 全局代理状态（读取/清空实时刷新）。
  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 7, vsync: this);
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
      ErrorLogger.instance.warn('dns lookup failed: $e');
      if (!mounted) return;
      setState(() {
        _dnsOut = '查询失败，请检查网络';
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
      ErrorLogger.instance.warn('ip query failed: $e');
      if (!mounted) return;
      setState(() {
        _ipOut = '查询失败，请检查网络';
        _busyIp = false;
      });
    }
  }

  Future<void> _weather() async {
    final city = _cityCtrl.text.trim();
    if (city.isEmpty) {
      if (mounted) AppToast.info(context, '请输入城市名');
      return;
    }
    setState(() {
      _busyWeather = true;
      _weatherOut = '';
    });
    try {
      // 城市 → 经纬度：先用 open-meteo geocoding 解析城市名，
      // 再查当前天气。避免把固定北京坐标标注成用户输入的城市（数据错位）。
      final geo = await Net.get(
        'https://geocoding-api.open-meteo.com/v1/search'
        '?name=${Uri.encodeQueryComponent(city)}&count=1&language=zh',
      );
      final gj = jsonDecode(geo) as Map<String, dynamic>;
      final results = gj['results'] as List?;
      if (results == null || results.isEmpty) {
        if (mounted) {
          setState(() {
            _weatherOut = '未找到城市：$city';
            _busyWeather = false;
          });
        }
        return;
      }
      final first = results.first as Map<String, dynamic>;
      final lat = first['latitude'];
      final lon = first['longitude'];
      final resolvedName =
          (first['name'] as String?) ?? (first['admin1'] as String?) ?? city;
      final resp = await Net.get(
        'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon'
        '&current_weather=true&timezone=auto',
      );
      final j = jsonDecode(resp) as Map<String, dynamic>;
      final cw = j['current_weather'] as Map<String, dynamic>?;
      if (!mounted) return;
      setState(() {
        _weatherOut = cw == null
            ? '未获取到天气数据'
            : '城市：$resolvedName\n'
                '温度：${cw['temperature']}°C\n'
                '风速：${cw['windspeed']} km/h\n'
                '风向：${cw['winddirection']}°\n'
                '天气码：${cw['weathercode']}\n'
                '时间：${cw['time']}';
        _busyWeather = false;
      });
    } catch (e) {
      ErrorLogger.instance.warn('weather query failed: $e');
      if (!mounted) return;
      setState(() {
        _weatherOut = '查询失败，请检查网络';
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
            Tab(text: '代理'),
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
            _ProxyTab(proxy: Net.proxy, onChanged: _onProxyChanged),
            const _CfPickerTab(),
            const _SourceCheckTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildDns(ColorScheme scheme) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 16,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
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
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 16,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
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
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 16,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
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
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 16,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
      children: [
        TextField(
          controller: _cityCtrl,
          decoration: const InputDecoration(
            hintText: '输入城市，如 北京 / 上海 / Tokyo',
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

  Future<void> _onProxyChanged(String? v) async {
    await Net.setProxy(v);
    if (mounted) setState(() {});
  }
}
