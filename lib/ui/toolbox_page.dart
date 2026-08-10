import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../net/image_cache.dart';
import '../net/local_store.dart';
import 'settings_page.dart';
import 'webview_page.dart';

/// 工具箱：本地实用工具集合。
/// - 下载管理增强：查看/清理已下载章节
/// - 缓存清理：清理图片缓存（封面/列表图）
/// - 图片工具：本地图片压缩 / 格式转换
/// - 文本工具：MD5 / Base64 / 字数统计
/// - 站点入口：NekoGAL 等（仅跳转，不托管内容）
class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key});

  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {
  // 下载
  List<DownloadRecord> _downloads = [];
  bool _busyDownloads = false;

  // 缓存
  int _cacheBytes = 0;
  bool _busyCache = false;

  // 图片工具
  final _imgPathCtrl = TextEditingController();
  String _imgMsg = '';
  bool _busyImg = false;

  // 文本工具
  final _textInCtrl = TextEditingController();
  String _textOut = '';

  static const String _nekogalUrl = 'https://www.xifan.moe/';

  @override
  void initState() {
    super.initState();
    _refreshDownloads();
    _refreshCacheSize();
  }

  Future<void> _refreshDownloads() async {
    final list = await LocalStore.downloads();
    if (mounted) setState(() => _downloads = list);
  }

  Future<void> _refreshCacheSize() async {
    final files = await ImageCacheManager.diskFiles();
    var sum = 0;
    for (final f in files) {
      try {
        sum += f.lengthSync();
      } catch (_) {}
    }
    if (mounted) setState(() => _cacheBytes = sum);
  }

  Future<void> _clearDownloads() async {
    setState(() => _busyDownloads = true);
    await LocalStore.clearDownloads();
    await _refreshDownloads();
    if (mounted) setState(() => _busyDownloads = false);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已清理已完成下载')));
    }
  }

  Future<void> _clearCache() async {
    setState(() => _busyCache = true);
    await ImageCacheManager.clear();
    try {
      PaintingBinding.instance.imageCache.clear();
    } catch (_) {}
    await _refreshCacheSize();
    if (mounted) setState(() => _busyCache = false);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图片缓存已清理')));
    }
  }

  Future<void> _processImage(String format, {int? maxWidth}) async {
    final p = _imgPathCtrl.text.trim();
    if (p.isEmpty) {
      setState(() => _imgMsg = '请填写本地图片路径');
      return;
    }
    final file = File(p);
    if (!file.existsSync()) {
      setState(() => _imgMsg = '文件不存在');
      return;
    }
    setState(() {
      _busyImg = true;
      _imgMsg = '处理中…';
    });
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        setState(() {
          _busyImg = false;
          _imgMsg = '无法解码该图片';
        });
        return;
      }
      img.Image out = decoded;
      if (maxWidth != null && decoded.width > maxWidth) {
        out = img.copyResize(decoded, width: maxWidth);
      }
      final Uint8List encoded;
      final ext = format == 'png' ? 'png' : 'jpg';
      if (format == 'png') {
        encoded = Uint8List.fromList(img.encodePng(out));
      } else {
        encoded = Uint8List.fromList(img.encodeJpg(out, quality: 82));
      }
      final dir = await getApplicationSupportDirectory();
      final outDir = Directory('${dir.path}/toolbox_images');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final name =
          'img_${DateTime.now().millisecondsSinceEpoch}.$ext';
      final outFile = File('${outDir.path}/$name');
      await outFile.writeAsBytes(encoded, flush: true);
      final saved = (encoded.length / 1024).round();
      final orig = (bytes.length / 1024).round();
      setState(() {
        _busyImg = false;
        _imgMsg =
            '已保存：${outFile.path}\n原始 $orig KB → $saved KB（${format.toUpperCase()}）';
      });
    } catch (e) {
      setState(() {
        _busyImg = false;
        _imgMsg = '处理失败：$e';
      });
    }
  }

  void _md5() {
    final t = _textInCtrl.text;
    if (t.isEmpty) return;
    setState(() => _textOut = md5.convert(utf8.encode(t)).toString());
  }

  void _b64(bool encode) {
    final t = _textInCtrl.text;
    if (t.isEmpty) return;
    try {
      setState(() => _textOut = encode
          ? base64Encode(utf8.encode(t))
          : utf8.decode(base64Decode(t)));
    } catch (e) {
      setState(() => _textOut = 'Base64 解码失败：$e');
    }
  }

  void _count() {
    final t = _textInCtrl.text;
    setState(() => _textOut =
        '字符数：${t.length}　不含空格：${t.replaceAll(RegExp(r'\s'), '').length}　行数：${t.split('\n').length}');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('工具箱'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(scheme, Icons.download_done_rounded, '下载管理',
              _buildDownloads()),
          const SizedBox(height: 14),
          _card(scheme, Icons.cleaning_services_outlined, '缓存清理',
              _buildCache()),
          const SizedBox(height: 14),
          _card(scheme, Icons.image_outlined, '图片工具', _buildImage()),
          const SizedBox(height: 14),
          _card(scheme, Icons.text_fields_rounded, '文本工具', _buildText()),
          const SizedBox(height: 14),
          _card(scheme, Icons.sports_esports_outlined, '站点入口',
              _buildSites(scheme)),
        ],
      ),
    );
  }

  Widget _card(ColorScheme scheme, IconData icon, String title, Widget body) {
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.onSurface.withValues(alpha: 0.06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          body,
        ],
      ),
    );
  }

  Widget _buildDownloads() {
    if (_downloads.isEmpty) {
      return const Text('暂无下载记录', style: TextStyle(color: Colors.grey));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ..._downloads.take(8).map((d) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    d.finished
                        ? Icons.check_circle_outline
                        : Icons.downloading_rounded,
                    size: 16,
                    color: d.finished ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${d.book.name} · ${d.chapterTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${d.done}/${d.total}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            )),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _busyDownloads ? null : _clearDownloads,
            icon: _busyDownloads
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('清理已完成'),
          ),
        ),
      ],
    );
  }

  Widget _buildCache() {
    final mb = (_cacheBytes / 1024 / 1024);
    final sizeStr = mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(_cacheBytes / 1024).round()} KB';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('当前图片缓存占用：$sizeStr',
            style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _busyCache ? null : _clearCache,
            icon: _busyCache
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cleaning_services_outlined, size: 18),
            label: const Text('清理图片缓存'),
          ),
        ),
      ],
    );
  }

  Widget _buildImage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _imgPathCtrl,
          decoration: const InputDecoration(
            hintText: '本地图片路径（如 /sdcard/Download/a.jpg）',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton(
              onPressed: _busyImg ? null : () => _processImage('jpg'),
              child: const Text('转 JPG(压缩)'),
            ),
            ElevatedButton(
              onPressed: _busyImg ? null : () => _processImage('png'),
              child: const Text('转 PNG'),
            ),
            ElevatedButton(
              onPressed: _busyImg ? null : () => _processImage('jpg', maxWidth: 1080),
              child: const Text('缩放≤1080宽'),
            ),
          ],
        ),
        if (_imgMsg.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_imgMsg,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ],
    );
  }

  Widget _buildText() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _textInCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '输入文本…',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton(onPressed: _md5, child: const Text('MD5')),
            ElevatedButton(
                onPressed: () => _b64(true), child: const Text('Base64 编码')),
            ElevatedButton(
                onPressed: () => _b64(false), child: const Text('Base64 解码')),
            ElevatedButton(onPressed: _count, child: const Text('字数统计')),
          ],
        ),
        if (_textOut.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(_textOut, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ],
    );
  }

  Widget _buildSites(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('仅作站点跳转入口，不解析/不托管第三方内容。',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.sports_esports_rounded, color: scheme.primary),
          title: const Text('NekoGAL'),
          subtitle: const Text('Galgame 平台（xifan.moe 入口）'),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    WebviewPage(url: _nekogalUrl, title: 'NekoGAL')),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _imgPathCtrl.dispose();
    _textInCtrl.dispose();
    super.dispose();
  }
}
