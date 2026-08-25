import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../net/image_cache.dart';
import '../../utils/image_super_res.dart';

/// 带内存+磁盘缓存的网络图片（封面/列表图）。
///
/// 相比直接 [Image.network]：
/// - 首次加载后写入磁盘，二次打开秒开、离线可看；
/// - 有真正的 loading / error 态（原实现创建了占位组件却没用上）；
/// - 点错误图可重试；
/// - [superRes] = true 时走 Lanczos-3 算法对原图 2x 上采样（Isolate 执行，
///   不阻塞 UI 线程）；超分结果独立磁盘缓存，下次秒开。
class CachedImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final double radius;
  final double? width;
  final double? height;

  /// 是否启用真实超分辨率（2x Lanczos-3 重采样）。
  final bool superRes;

  const CachedImage(
    this.url, {
    super.key,
    this.fit = BoxFit.cover,
    this.radius = 0,
    this.width,
    this.height,
    this.superRes = false,
  });

  @override
  State<CachedImage> createState() => _CachedImageState();
}

class _CachedImageState extends State<CachedImage> {
  Uint8List? _bytes;
  bool _failed = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CachedImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.superRes != widget.superRes) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  String _superResKey() => '${widget.url}|${ImageSuperRes.algoVersion}';

  /// 图片请求加 Referer，避免部分 CDN（如 lain.bgm.tv）防盗链拒绝。
  static Map<String, String> _headersFor(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.contains('bgm.tv')) {
      return const {
        'Referer': 'https://bgm.tv/',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/120.0.0.0 Safari/537.36',
      };
    }
    return const {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/120.0.0.0 Safari/537.36',
    };
  }

  Future<void> _load() async {
    if (_loading || widget.url.isEmpty) return;
    _loading = true;
    if (mounted) setState(() => _failed = false);
    try {
      final headers = _headersFor(widget.url);
      if (widget.superRes) {
        final sr = await ImageCacheManager.load(_superResKey(),
            headers: headers,
            fetch: () async {
              final raw = await ImageCacheManager.load(widget.url,
                  headers: headers);
              return await ImageSuperRes.upscale2x(raw);
            }).timeout(const Duration(seconds: 8));
        if (mounted) {
          setState(() {
            _bytes = sr;
            _failed = false;
          });
        }
      } else {
        final b = await ImageCacheManager.load(widget.url, headers: headers)
            .timeout(const Duration(seconds: 8));
        if (mounted) {
          setState(() {
            _bytes = b;
            _failed = false;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget img;
    if (widget.url.isEmpty || _failed) {
      img = GestureDetector(
        onTap: _load,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/placeholder_cover.webp',
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
            if (_failed)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.refresh_rounded,
                      color: Colors.white70, size: 26),
                ),
              ),
          ],
        ),
      );
    } else if (_bytes != null) {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final cw = widget.width != null
          ? (widget.width! * dpr).toInt()
          : (MediaQuery.sizeOf(context).width * dpr).toInt();
      img = Image.memory(
        _bytes!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        cacheWidth: cw,
      );
    } else {
      img = Image.asset(
        'assets/placeholder_cover.webp',
        fit: BoxFit.cover,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
      );
    }

    if (widget.radius > 0) {
      img = ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: img);
    }
    return img;
  }
}