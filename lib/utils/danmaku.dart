import 'dart:convert';

import '../net/http_client.dart';

/// 弹幕条目：出现时间（秒）、文本、颜色（ARGB）、类型。
class DanmakuItem {
  final double time;
  final String text;
  final int color;
  final int type; // 0=滚动 1=顶部 2=底部

  const DanmakuItem(this.time, this.text,
      {this.color = 0xFFFFFFFF, this.type = 0});
}

/// 弹幕显示设置（持久化到本地）。
class DanmakuSettings {
  final bool on;
  final double fontSize; // 12~22
  final double speed; // 1.0~3.0（倍率）
  final double opacity; // 0.2~1.0

  const DanmakuSettings({
    this.on = false,
    this.fontSize = 14,
    this.speed = 1.6,
    this.opacity = 0.9,
  });

  DanmakuSettings copyWith({bool? on, double? fontSize, double? speed, double? opacity}) =>
      DanmakuSettings(
        on: on ?? this.on,
        fontSize: fontSize ?? this.fontSize,
        speed: speed ?? this.speed,
        opacity: opacity ?? this.opacity,
      );

  Map<String, dynamic> toJson() => {
        'on': on,
        'fontSize': fontSize,
        'speed': speed,
        'opacity': opacity,
      };

  factory DanmakuSettings.fromJson(Map<String, dynamic> j) => DanmakuSettings(
        on: (j['on'] as bool?) ?? false,
        fontSize: ((j['fontSize'] as num?)?.toDouble()) ?? 14,
        speed: ((j['speed'] as num?)?.toDouble()) ?? 1.6,
        opacity: ((j['opacity'] as num?)?.toDouble()) ?? 0.9,
      );
}

/// 弹幕数据源：弹弹 play（DandanPlay）开放接口，按「番名 + 集数」匹配后拉取。
///
/// 网络不可达 / 无匹配时静默返回空列表，绝不抛错打断播放。
class DanmakuFetcher {
  static const String _host = 'https://api.dandanplay.net';

  static Future<List<DanmakuItem>> fetch(String title, int episode) async {
    try {
      final epId = await _match(title, episode);
      if (epId == null) return const [];
      return await _comments(epId);
    } catch (_) {
      return const [];
    }
  }

  static Future<int?> _match(String title, int episode) async {
    final body = await Net.post(
      '$_host/api/v2/match',
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'fileName': '$title 第$episode集'}),
    );
    final data = jsonDecode(body) as Map<String, dynamic>;
    final matches = (data['matches'] as List?) ?? const [];
    if (matches.isEmpty) return null;
    return (matches.first as Map<String, dynamic>)['episodeId'] as int?;
  }

  static Future<List<DanmakuItem>> _comments(int episodeId) async {
    final body = await Net.get('$_host/api/v2/comment/$episodeId');
    final data = jsonDecode(body) as Map<String, dynamic>;
    final list = (data['comments'] as List?) ?? const [];
    final out = <DanmakuItem>[];
    for (final c in list) {
      final m = c as Map<String, dynamic>;
      final p = ((m['p'] as String?) ?? '').split(',');
      final t = p.isNotEmpty ? double.tryParse(p[0]) ?? 0 : 0.0;
      final type = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
      final color = p.length > 3 ? int.tryParse(p[3]) ?? 0xFFFFFF : 0xFFFFFF;
      final text = ((m['m'] as String?) ?? '').trim();
      if (text.isEmpty || t < 0) continue;
      out.add(DanmakuItem(t, text,
          color: 0xFF000000 | (color & 0xFFFFFF), type: type));
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }
}
