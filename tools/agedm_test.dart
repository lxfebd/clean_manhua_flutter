import 'dart:convert';
import 'dart:io';

import 'package:xingmanxia/sources/agedm_video_source.dart';

Future<void> main() async {
  final source = AgedMVideoSource();
  // Fetch catalog page
  final html = await _fetch(
      'https://www.agedm.io/catalog/all-all-all-all-jp-time-1');
  print('CATALOG LEN=${html.length}');
  final items = await source.listByCategory('all', 1);
  print('ITEMS COUNT=${items.length}');
  if (items.isNotEmpty) {
    print('FIRST id=${items.first.id} title=${items.first.name}');
    print('  pic=${items.first.pic}');

    // Test detail
    final d = await source.detail(items.first.id);
    print('DETAIL title=${d.video.name}');
    print('  area=${d.area} type=${d.type}');
    print('  episodes=${d.episodes.length} (first=${d.episodes.isNotEmpty ? d.episodes.first.title : 'none'})');
    if (d.episodes.isNotEmpty) {
      // Test play URL
      final url = await source.playUrl(d.video.id,
          d.episodes.first.season, d.episodes.first.episode);
      print('PLAY URL=$url');
    }
  }
}

Future<String> _fetch(String url) async {
  final client = HttpClient();
  final req = await client.getUrl(Uri.parse(url));
  req.headers.set('User-Agent',
      'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile');
  req.headers.set('Cookie', 'adult=1');
  final r = await req.close();
  final body = await r.transform(utf8.decoder).join();
  client.close(force: true);
  return body;
}