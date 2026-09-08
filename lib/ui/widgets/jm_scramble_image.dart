import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../net/http_client.dart';
import '../../net/image_cache.dart';
import '../../net/jm_scramble.dart';
import '../../sources/source_http.dart';

class JmScrambleImageWidget extends StatefulWidget {
  final String url;
  final BoxFit fit;
  final FilterQuality filterQuality;
  final bool horizontal;

  /// 所属源 ID（空则走全局代理/直连），用于单源代理透传。
  final String sourceId;

  const JmScrambleImageWidget({
    super.key,
    required this.url,
    required this.fit,
    required this.filterQuality,
    this.horizontal = false,
    this.sourceId = '',
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
    try {
      // 多级降级：原画（带 @jm: 解扰标记的 URL）失败后自动尝试备用 CDN 镜像
      // （注册表 jm 的镜像构建器保持同 CDN/Path，仅换域名）。缓存 key 一律按
      // 归一化主 URL 计算——镜像档成功后，下次原画/CDN 抖动也直接命中。
      final bytes = await ImageCacheManager.loadDegraded(
        widget.url,
        engineId: 'jm',
        loader: (u, i) async {
          final split = JmScramble.splitUrl(u);
          var raw = Uint8List.fromList(await Net.getBytesCronet(
            split.url,
            headers: {
              'User-Agent': Net.defaultUA,
              'Referer': _refererFor(split.url),
              'Accept': 'image/webp,image/*,*/*',
            },
            proxy: widget.sourceId.isEmpty
                ? null
                : await SourceHttp.proxyFor(widget.sourceId),
          ));
          if (JmScramble.parseAid(u) != null) {
            raw = await JmScramble.descrambleAsync(raw, u);
          }
          return raw;
        },
      );
      if (mounted) {
        setState(() {
          _bytes = bytes.bytes;
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
              Icon(Icons.broken_image_outlined,
                  color: Colors.white54, size: 34),
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
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cw = (MediaQuery.sizeOf(context).width * dpr).toInt();
    // 横向 contain：长条图在屏上只显示一屏高，按屏高限位解码，
    // 避免整张按原始几千像素高解码导致 OOM 卡死。
    final ch =
        widget.horizontal ? (MediaQuery.sizeOf(context).height * dpr).toInt() : null;
    return Image.memory(
      _bytes!,
      width: double.infinity,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
      cacheWidth: cw,
      cacheHeight: ch,
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
