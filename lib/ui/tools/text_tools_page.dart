import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 文本加密类工具：加密(MD5/SHA/Base64)、摩斯密码、长度换算、二维码生成。
class TextToolsPage extends StatefulWidget {
  const TextToolsPage({super.key});

  @override
  State<TextToolsPage> createState() => _TextToolsPageState();
}

class _TextToolsPageState extends State<TextToolsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _encInCtrl = TextEditingController();
  String _encOut = '';
  final _morseInCtrl = TextEditingController();
  String _morseOut = '';
  final _lenNumCtrl = TextEditingController(text: '1');
  String _lenFrom = 'cm';
  String _lenTo = 'mm';
  String _lenOut = '';
  final _qrInCtrl = TextEditingController(text: 'https://');
  final GlobalKey _qrKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    _encInCtrl.dispose();
    _morseInCtrl.dispose();
    _lenNumCtrl.dispose();
    _qrInCtrl.dispose();
    super.dispose();
  }

  void _md5() {
    final t = _encInCtrl.text;
    setState(() => _encOut = md5.convert(utf8.encode(t)).toString());
  }

  void _sha(String alg) {
    final t = _encInCtrl.text;
    setState(() => _encOut = switch (alg) {
      'sha1' => sha1.convert(utf8.encode(t)).toString(),
      'sha256' => sha256.convert(utf8.encode(t)).toString(),
      _ => sha512.convert(utf8.encode(t)).toString(),
    });
  }

  void _b64(bool encode) {
    final t = _encInCtrl.text;
    try {
      setState(() => _encOut = encode
          ? base64Encode(utf8.encode(t))
          : utf8.decode(base64Decode(t)));
    } catch (e) {
      setState(() => _encOut = 'Base64 解码失败：$e');
    }
  }

  static const Map<String, String> _morseTable = {
    'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.', 'F': '..-.',
    'G': '--.', 'H': '....', 'I': '..', 'J': '.---', 'K': '-.-', 'L': '.-..',
    'M': '--', 'N': '-.', 'O': '---', 'P': '.--.', 'Q': '--.-', 'R': '.-.',
    'S': '...', 'T': '-', 'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-',
    'Y': '-.--', 'Z': '--..',
    '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
    '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
  };

  String _textToMorse(String t) {
    final sb = StringBuffer();
    for (final c in t.toUpperCase().split('')) {
      if (c == ' ') {
        sb.write(' / ');
      } else if (_morseTable.containsKey(c)) {
        sb.write('${_morseTable[c]} ');
      } else {
        sb.write('? ');
      }
    }
    return sb.toString().trim();
  }

  String _morseToText(String t) {
    final rev = {for (final e in _morseTable.entries) e.value: e.key};
    final sb = StringBuffer();
    for (final word in t.trim().split('/')) {
      for (final code in word.trim().split(RegExp(r'\s+'))) {
        if (code.isEmpty) continue;
        sb.write(rev[code] ?? '?');
      }
      sb.write(' ');
    }
    return sb.toString().trim();
  }

  void _toMorse() {
    setState(() => _morseOut = _textToMorse(_morseInCtrl.text));
  }

  void _fromMorse() {
    setState(() => _morseOut = _morseToText(_morseInCtrl.text));
  }

  void _convert() {
    const meters = {
      'mm': 0.001, 'cm': 0.01, 'm': 1.0, 'km': 1000.0,
      'in': 0.0254, 'ft': 0.3048, 'yd': 0.9144, 'mile': 1609.344,
    };
    final v = double.tryParse(_lenNumCtrl.text) ?? 0;
    final out = v * (meters[_lenFrom] ?? 1) / (meters[_lenTo] ?? 1);
    setState(() => _lenOut =
        '$v $_lenFrom = ${out.toStringAsFixed(4)} $_lenTo');
  }

  Future<void> _copy(String text) async {
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制')));
  }

  Future<void> _saveQr() async {
    if (_qrInCtrl.text.trim().isEmpty) return;
    final boundary = _qrKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 4);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final f = await _writeToGallery(bytes!.buffer.asUint8List());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存：${f.path}')));
  }

  Future<File> _writeToGallery(Uint8List bytes) async {
    final dir = await getApplicationSupportDirectory();
    final outDir = Directory('${dir.path}/toolbox_images');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final f = File(
        '${outDir.path}/qr_${DateTime.now().millisecondsSinceEpoch}.png');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('文本工具'),
        backgroundColor: scheme.surfaceContainerLowest,
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '加密'),
            Tab(text: '摩斯密码'),
            Tab(text: '长度换算'),
            Tab(text: '二维码'),
          ],
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: TabBarView(
          controller: _tab,
          children: [
            _buildEncrypt(scheme),
            _buildMorse(scheme),
            _buildLength(scheme),
            _buildQr(scheme),
          ],
        ),
      ),
    );
  }

  Widget _outBox(ColorScheme scheme, String text) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: SelectableText(text, style: const TextStyle(fontSize: 13))),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: const Icon(Icons.copy_rounded),
            tooltip: '复制',
            onPressed: () => _copy(text),
          ),
        ],
      ),
    );
  }

  Widget _buildEncrypt(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        TextField(
          controller: _encInCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '输入文本…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton(onPressed: _md5, child: const Text('MD5')),
            ElevatedButton(
                onPressed: () => _sha('sha1'), child: const Text('SHA-1')),
            ElevatedButton(
                onPressed: () => _sha('sha256'), child: const Text('SHA-256')),
            ElevatedButton(
                onPressed: () => _sha('sha512'), child: const Text('SHA-512')),
            ElevatedButton(
                onPressed: () => _b64(true), child: const Text('Base64 编码')),
            ElevatedButton(
                onPressed: () => _b64(false), child: const Text('Base64 解码')),
          ],
        ),
        _outBox(scheme, _encOut),
      ],
    );
  }

  Widget _buildMorse(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        TextField(
          controller: _morseInCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '输入文字或摩斯码（如 .- ...）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton(onPressed: _toMorse, child: const Text('文字 → 摩斯')),
            ElevatedButton(
                onPressed: _fromMorse, child: const Text('摩斯 → 文字')),
            TextButton.icon(
              onPressed: () => _morseInCtrl.clear(),
              icon: const Icon(Icons.clear_rounded, size: 18),
              label: const Text('清空'),
            ),
          ],
        ),
        _outBox(scheme, _morseOut),
      ],
    );
  }

  Widget _buildLength(ColorScheme scheme) {
    const units = ['mm', 'cm', 'm', 'km', 'in', 'ft', 'yd', 'mile'];
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        TextField(
          controller: _lenNumCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '数值',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _lenFrom,
          isDense: true,
          decoration: const InputDecoration(
            labelText: '从',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: units
              .map((u) => DropdownMenuItem(value: u, child: Text(u)))
              .toList(),
          onChanged: (v) => setState(() => _lenFrom = v ?? _lenFrom),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _lenTo,
          isDense: true,
          decoration: const InputDecoration(
            labelText: '到',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: units
              .map((u) => DropdownMenuItem(value: u, child: Text(u)))
              .toList(),
          onChanged: (v) => setState(() => _lenTo = v ?? _lenTo),
        ),
        const SizedBox(height: 12),
        ElevatedButton(onPressed: _convert, child: const Text('换算')),
        _outBox(scheme, _lenOut),
      ],
    );
  }

  Widget _buildQr(ColorScheme scheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 110),
      children: [
        TextField(
          controller: _qrInCtrl,
          decoration: const InputDecoration(
            hintText: '输入文本 / 链接…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: RepaintBoundary(
            key: _qrKey,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: QrImageView(
                data: _qrInCtrl.text.trim().isEmpty
                    ? 'empty'
                    : _qrInCtrl.text.trim(),
                version: QrVersions.auto,
                size: 220,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _saveQr,
          icon: const Icon(Icons.save_alt_rounded, size: 18),
          label: const Text('保存二维码'),
        ),
      ],
    );
  }
}
