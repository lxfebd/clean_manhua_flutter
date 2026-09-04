import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';

import '../responsive.dart';

/// 设备系统类工具：设备信息、屏幕测试、秒表、指南针。
class DeviceToolsPage extends StatefulWidget {
  const DeviceToolsPage({super.key});

  @override
  State<DeviceToolsPage> createState() => _DeviceToolsPageState();
}

class _DeviceToolsPageState extends State<DeviceToolsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  Map<String, String> _info = {};
  bool _infoLoaded = false;
  String _infoError = '';

  // 秒表
  Stopwatch? _sw;
  Timer? _swTimer;
  Duration _elapsed = Duration.zero;

  // 屏幕测试
  final List<Color> _testColors = [
    Colors.white, Colors.black, Colors.red, Colors.green,
    Colors.blue, Colors.yellow, Colors.cyan, Colors.pink,
  ];
  int _colorIdx = 0;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _loadInfo();
  }

  @override
  void dispose() {
    _tab.dispose();
    _swTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    try {
      final di = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await di.androidInfo;
        _info = {
          '品牌': a.brand,
          '型号': a.model,
          'Android': a.version.release,
          'SDK': '${a.version.sdkInt}',
          'CPU 架构': a.supportedAbis.join(', '),
          '序列号': a.serialNumber.isNotEmpty ? a.serialNumber : '-',
          '硬件': a.hardware.isNotEmpty ? a.hardware : '-',
          '设备': a.device.isNotEmpty ? a.device : '-',
          '指纹': a.fingerprint.isNotEmpty ? a.fingerprint : '-',
        };
      } else {
        final i = await di.iosInfo;
        _info = {
          '型号': i.utsname.machine,
          '系统': '${i.systemName} ${i.systemVersion}',
          '名称': i.name,
          '标识符': i.identifierForVendor ?? '-',
        };
      }
      if (mounted) {
        setState(() {
          _infoLoaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _infoError = '$e';
          _infoLoaded = true;
        });
      }
    }
  }

  void _toggleSw() {
    if (_sw == null) {
      _sw = Stopwatch()..start();
      _swTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        setState(() => _elapsed = _sw!.elapsed);
      });
    } else if (_sw!.isRunning) {
      _sw!.stop();
    } else {
      _sw!.start();
    }
    setState(() {});
  }

  void _resetSw() {
    _sw?.reset();
    _swTimer?.cancel();
    _sw = null;
    setState(() => _elapsed = Duration.zero);
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final ms = (d.inMilliseconds % 1000) ~/ 10;
    return '${two(d.inHours)}:${two(d.inMinutes)}:${two(d.inSeconds)}.$ms';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('设备工具'),
        backgroundColor: scheme.surfaceContainerLowest,
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '设备信息'),
            Tab(text: '屏幕测试'),
            Tab(text: '秒表'),
            Tab(text: '指南针'),
          ],
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: TabBarView(
          controller: _tab,
          children: [
            _buildInfo(scheme),
            _buildScreenTest(),
            _buildStopwatch(scheme),
            _buildCompass(scheme),
          ],
        ),
      ),
    );
  }

  Widget _buildInfo(ColorScheme scheme) {
    if (!_infoLoaded) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_infoError.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('获取设备信息失败：$_infoError',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.6))),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Responsive.pagePadding(context), 16,
          Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
      children: _info.entries
          .map((e) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: scheme.onSurface.withValues(alpha: 0.06)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 76,
                      child: Text(e.key,
                          style: TextStyle(
                              fontSize: 13,
                              color:
                                  scheme.onSurface.withValues(alpha: 0.5))),
                    ),
                    Expanded(
                      child: Text(e.value,
                          style: const TextStyle(fontSize: 13.5)),
                    ),
                  ],
                ),
              ))
          .toList(),
    );
  }

  Widget _buildScreenTest() {
    return GestureDetector(
      onTap: () => setState(() => _colorIdx = (_colorIdx + 1) % _testColors.length),
      onLongPress: () => setState(() => _colorIdx = 0),
      child: Container(
        color: _testColors[_colorIdx],
        alignment: Alignment.bottomCenter,
        padding: const EdgeInsets.only(bottom: 40),
        child: Text(
          '$_colorIdx${_colorIdx == 0 ? ' 点击切换 / 长按回到白色' : ''}',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: _testColors[_colorIdx] == Colors.white
                ? Colors.black54
                : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _buildStopwatch(ColorScheme scheme) {
    final running = _sw?.isRunning ?? false;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(_fmt(_elapsed),
              style: TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w300,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.onSurface)),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton(
                onPressed: _toggleSw,
                child: Text(running ? '暂停' : (_sw == null ? '开始' : '继续')),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _resetSw,
                child: const Text('复位'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCompass(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.explore_outlined, size: 72, color: scheme.primary),
            const SizedBox(height: 16),
            const Text('指南针'),
            const SizedBox(height: 6),
            Text(
              '需要设备磁力计（传感器）支持。\n当前环境 / 模拟器可能无法获取方向数据。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }
}
