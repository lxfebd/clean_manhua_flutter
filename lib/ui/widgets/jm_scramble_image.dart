import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../net/http_client.dart';
import '../../net/image_cache.dart';
import '../../net/jm_scramble.dart';

/// 禁漫图片渲染组件。
///
/// 禁漫对部分专辑（aid ≥ 220980）的图片做「纵向分块倒序」混淆（参考 JMComic 算法），
/// 本组件下载字节后用 [JmScramble.descramble] 还原，结果写入 [ImageCacheManager]
/// （缓存还原后的字节，避免重复解码）。无需还原的图片原样缓存。
class JmScrambleImageWidget extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final FilterQuality filterQuality;

  const JmScrambleImageWidget({
    super.key,
    required this.url,
    required this.fit,
    required this.filterQuality,
  });

  @override
  State<JmScrambleImageWidget> createState() => _JmScrambleImageWidgetState();
}

class _JmScrambleImageWidgetState extends State<JmScrambleImageWidget> {
  Uint8List? _bytes;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(JmScrambleImageWidget old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = null;
      _error = null;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    if (mounted) setState(() => _loading = true);
    final split = JmScramble.splitUrl(widget.url);
    final referer = _refererFor(split.url);
    try {
      final bytes = await ImageCacheManager.load(
        widget.url,
        fetch: () async {
          var raw = Uint8List.fromList(await Net.getBytes(
            split.url,
            headers: {
              'User-Agent': Net.defaultUA,
              'Referer': referer,
              'Accept': 'image/webp,image/*,*/*',
            },
          ));
          // 若 URL 含 aid（禁漫加扰图），按真实算法还原
          if (JmScramble.parseAid(widget.url) != null) {
            raw = JmScramble.descramble(raw, widget.url);
          }
          return raw;
        },
      );
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _error = null;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  String _refererFor(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}/';
    } catch (_) {
      return 'https://www.18comic.vg/';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 错误态：可点击重试，不白屏
    if (_error != null) {
      return GestureDetector(
        onTap: _load,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          color: Colors.black12,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.broken_image_outlined, color: Colors.white54, size: 34),
              SizedBox(height: 8),
              Text('加载失败，点击重试',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
      );
    }
    if (_bytes == null) {
      return SizedBox(
        width: double.infinity,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white54,
            ),
          ),
        ),
      );
    }
    return Image.memory(
      _bytes!,
      width: double.infinity,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
      errorBuilder: (_, __, ___) => GestureDetector(
        onTap: _load,
        behavior: HitTestBehavior.opaque,
        child: const Center(
          child: Icon(Icons.broken_image, color: Colors.white54, size: 32),
        ),
      ),
    );
  }
}
