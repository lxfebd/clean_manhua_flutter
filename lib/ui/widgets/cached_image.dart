import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../net/image_cache.dart';

/// 带内存+磁盘缓存的网络图片（封面/列表图）。
///
/// 相比直接 [Image.network]：
/// - 首次加载后写入磁盘，二次打开秒开、离线可看；
/// - 有真正的 loading / error 态（原实现创建了占位组件却没用上）；
/// - 点错误图可重试。
class CachedImage extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final double radius;
  final double? width;
  final double? height;
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CachedImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    if (widget.url.isEmpty) return;
    try {
      final b = await ImageCacheManager.load(widget.url);
      if (mounted) {
        setState(() {
          _bytes = b;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget img;
    if (widget.url.isEmpty || _failed) {
      img = GestureDetector(
        onTap: _load,
        child: Container(
          color: scheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Icon(
            _failed
                ? Icons.refresh_rounded
                : Icons.image_not_supported_outlined,
            color: scheme.onSurface.withValues(alpha: 0.3),
            size: _failed ? 26 : 28,
          ),
        ),
      );
    } else if (_bytes != null) {
      img = Image.memory(
        _bytes!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: widget.superRes ? FilterQuality.high : FilterQuality.low,
      );
    } else {
      img = Container(
        color: scheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: scheme.primary.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    if (widget.radius > 0) {
      img = ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: img);
    }
    return img;
  }
}
