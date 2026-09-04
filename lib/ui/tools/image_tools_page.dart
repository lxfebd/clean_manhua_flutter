import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../responsive.dart';

/// 图片处理工具：压缩/转换/缩放、加水印、高斯模糊、九宫格切图。
class ImageToolsPage extends StatefulWidget {
  const ImageToolsPage({super.key});

  @override
  State<ImageToolsPage> createState() => _ImageToolsPageState();
}

class _ImageToolsPageState extends State<ImageToolsPage> {
  String _path = '';
  String _name = '';
  String _msg = '';
  bool _busy = false;
  final _watermarkCtrl = TextEditingController();
  String _saveDir = '';

  @override
  void initState() {
    super.initState();
    _initDir();
  }

  Future<void> _initDir() async {
    final dir = await getApplicationSupportDirectory();
    if (mounted) setState(() => _saveDir = '${dir.path}/toolbox_images');
  }

  Future<void> _pickImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final path = f.path;
    if (path == null || path.isEmpty) return;
    if (mounted) {
      setState(() {
        _path = path;
        _name = f.name;
        _msg = '';
      });
    }
  }

  Future<File?> _load() async {
    final file = File(_path);
    if (_path.isEmpty || !file.existsSync()) {
      setState(() => _msg = '请先选择图片');
      return null;
    }
    return file;
  }

  Future<File> _save(String ext, Uint8List bytes) async {
    final outDir = Directory(_saveDir);
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final outFile = File(
        '${outDir.path}/img_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await outFile.writeAsBytes(bytes, flush: true);
    return outFile;
  }

  String _sizeMsg(int origBytes, int savedBytes, String tag) {
    final o = (origBytes / 1024).round();
    final s = (savedBytes / 1024).round();
    return '$tag 已保存：$_saveDir\n原始 $o KB → $s KB';
  }

  Future<void> _run(Future<File> Function(img.Image, Uint8List) work,
      String tag) async {
    final file = await _load();
    if (file == null) return;
    setState(() {
      _busy = true;
      _msg = '处理中…';
    });
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        setState(() {
          _busy = false;
          _msg = '无法解码该图片';
        });
        return;
      }
      final out = await work(decoded, bytes);
      final outLen = await out.length();
      setState(() {
        _busy = false;
        _msg = _sizeMsg(bytes.length, outLen, tag);
      });
    } catch (e) {
      setState(() {
        _busy = false;
        _msg = '处理失败：$e';
      });
    }
  }

  void _convert(String format) {
    _run((decoded, bytes) async {
      final Uint8List encoded;
      if (format == 'png') {
        encoded = Uint8List.fromList(img.encodePng(decoded));
      } else {
        encoded = Uint8List.fromList(img.encodeJpg(decoded, quality: 82));
      }
      return _save(format, encoded);
    }, format.toUpperCase());
  }

  void _resize() {
    _run((decoded, bytes) async {
      final out = decoded.width > 1080
          ? img.copyResize(decoded, width: 1080)
          : decoded;
      return _save('jpg', Uint8List.fromList(img.encodeJpg(out, quality: 82)));
    }, '缩放≤1080');
  }

  void _watermark() {
    final text = _watermarkCtrl.text;
    _run((decoded, bytes) async {
      final out = img.Image.from(decoded);
      final wm = '${text.isNotEmpty ? '$text ' : ''}${DateTime.now().year}-'
          '${DateTime.now().month.toString().padLeft(2, '0')}-'
          '${DateTime.now().day.toString().padLeft(2, '0')}';
      final font = wm.length > 14 ? img.arial14 : img.arial24;
      final h = font.lineHeight + 8;
      var textW = 0;
      for (final c in wm.codeUnits) {
        final ch = font.characters[c];
        textW += ch?.xAdvance ?? 10;
      }
      img.fillRect(out,
          x1: 8,
          y1: decoded.height - h - 8,
          x2: 8 + textW + 12,
          y2: decoded.height - 8,
          color: img.ColorRgba8(0, 0, 0, 130));
      img.drawString(out, wm,
          font: font,
          x: 14,
          y: decoded.height - h + 2,
          color: img.ColorRgba8(255, 255, 255, 255));
      return _save('jpg', Uint8List.fromList(img.encodeJpg(out, quality: 92)));
    }, '水印');
  }

  void _blur() {
    _run((decoded, bytes) async {
      final out = img.gaussianBlur(decoded, radius: 6);
      return _save('jpg', Uint8List.fromList(img.encodeJpg(out, quality: 88)));
    }, '模糊');
  }

  void _gridCutter() {
    _run((decoded, bytes) async {
      final outDir = Directory(_saveDir);
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      var done = 0;
      File firstFile = File('$outDir.path/placeholder');
      for (var r = 0; r < 3; r++) {
        for (var c = 0; c < 3; c++) {
          final x = (decoded.width * c / 3).round();
          final y = (decoded.height * r / 3).round();
          final w = (decoded.width * (c + 1) / 3).round() - x;
          final h = (decoded.height * (r + 1) / 3).round() - y;
          final tile = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
          final f = File('${outDir.path}/grid_${stamp}_${r + 1}${c + 1}.jpg');
          await f.writeAsBytes(
              Uint8List.fromList(img.encodeJpg(tile, quality: 90)));
          done++;
          if (done == 1) {
            firstFile = f;
          }
        }
      }
      _msg = '九宫格切图完成：已生成 $done 张到 $_saveDir';
      return firstFile;
    }, '九宫格');
  }

  @override
  void dispose() {
    _watermarkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('图片处理'),
        backgroundColor: scheme.surfaceContainerLowest,
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              Responsive.pagePadding(context), 8,
              Responsive.pagePadding(context), (Responsive.isTablet(context) ? 24 : 110)),
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _pickImage,
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: Text(
                      _name.isEmpty ? '选择图片' : _name,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                ),
                if (_path.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.close_rounded,
                        color: scheme.onSurface.withValues(alpha: 0.5)),
                    onPressed:
                        _busy ? null : () => setState(() {
                              _path = '';
                              _name = '';
                              _msg = '';
                            }),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            _section(
              scheme,
              '转换 / 压缩',
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                      onPressed: _busy ? null : () => _convert('jpg'),
                      child: const Text('转 JPG(压缩)')),
                  ElevatedButton(
                      onPressed: _busy ? null : () => _convert('png'),
                      child: const Text('转 PNG')),
                  ElevatedButton(
                      onPressed: _busy ? null : _resize,
                      child: const Text('缩放≤1080宽')),
                ],
              ),
            ),
            _section(
              scheme,
              '水印 / 模糊 / 九宫格',
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _watermarkCtrl,
                    decoration: const InputDecoration(
                      hintText: '水印文字（可留空，默认时间戳）',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(
                          onPressed: _busy ? null : _watermark,
                          child: const Text('添加水印')),
                      ElevatedButton(
                          onPressed: _busy ? null : _blur,
                          child: const Text('高斯模糊')),
                      ElevatedButton(
                          onPressed: _busy ? null : _gridCutter,
                          child: const Text('九宫格切图')),
                    ],
                  ),
                ],
              ),
            ),
            if (_msg.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: scheme.onSurface.withValues(alpha: 0.06)),
                ),
                child: Text(_msg,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurface.withValues(alpha: 0.75))),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _section(
      ColorScheme scheme, String title, Widget body) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          body,
        ],
      ),
    );
  }
}
