import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/source_market.dart';

/// 源市场索引解析的健壮性回归：远端索引是第三方可控输入，
/// 任一坏条目（字段类型错 / 校验失败）都不得把整个市场崩掉——
/// 坏条目跳过 + 日志，好条目照常保留。
void main() {
  Map<String, dynamic> goodSource() => {
        'id': 'ok_source',
        'name': '好源',
        'type': 'comic',
        'version': '1.0.0',
        'author': 'test',
        'baseUrl': 'https://example.com',
        'rankUrl': 'https://example.com/rank',
        'rank': {
          'list': '.item',
          'title': '.title',
        },
      };

  test('字段类型错的条目（id 为数字）跳过，不抛 TypeError 崩掉市场', () {
    final text = jsonEncode({
      'name': '测试市场',
      'sources': [
        {'id': 123, 'name': '坏源'}, // fromJson 严格 as String? 会抛
        goodSource(),
      ],
    });
    final parsed = SourceMarket.parseIndex(text);
    expect(parsed.length, 1, reason: '坏条目跳过、好条目保留');
    expect(parsed.single.id, 'ok_source');
  });

  test('校验失败的条目（缺 baseUrl）带原因跳过，好条目保留', () {
    final text = jsonEncode({
      'name': '测试市场',
      'sources': [
        {
          'id': 'no_burl',
          'name': '缺 baseUrl',
          'type': 'comic',
          'version': '1.0.0',
          'author': 'x',
        },
        goodSource(),
      ],
    });
    final parsed = SourceMarket.parseIndex(text);
    expect(parsed.length, 1);
    expect(parsed.single.id, 'ok_source');
  });

  test('非 Map 条目静默跳过（不阻塞）', () {
    final text = jsonEncode({
      'name': '测试市场',
      'sources': [42, 'str', goodSource()],
    });
    final parsed = SourceMarket.parseIndex(text);
    expect(parsed.length, 1);
    expect(parsed.single.id, 'ok_source');
  });
}