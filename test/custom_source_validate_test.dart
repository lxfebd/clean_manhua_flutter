import 'package:flutter_test/flutter_test.dart';
import 'package:xingmanxia/sources/dsl/custom_source_def.dart';
import 'package:xingmanxia/sources/source_manager.dart';

/// P2-18 自定义源定义校验回归（纯函数，不联网）。
///
/// 覆盖两部分：
/// 1. **保留 id**：自定义源不得占用内置源 id（旧实现不查，导入一份 id=dm5 的
///    源就能把内置源顶掉或反之，且毫无提示）；
/// 2. 既有校验不回退：缺 id/name/baseUrl、type 非法、内网地址、规则缺失。
Map<String, dynamic> _base({String id = 'my_source'}) => {
      'id': id,
      'name': '我的源',
      'type': 'comic',
      'version': '1.0.0',
      'author': 'me',
      'baseUrl': 'https://example.com',
      'categoryListUrl': 'https://example.com/list/{page}.html',
      'categoryList': {
        'css': 'a.item',
        'id': 'href',
        'name': 'title',
        'pic': 'src',
      },
    };

void main() {
  group('validate() 既有规则（不回退）', () {
    test('合法定义 → 无错误', () {
      expect(CustomSourceDef.fromJson(_base()).validate(), isEmpty);
    });

    test('缺 id / name / baseUrl 各报一条', () {
      for (final k in ['id', 'name', 'baseUrl']) {
        final m = _base()..remove(k);
        expect(CustomSourceDef.fromJson(m).validate(), isNotEmpty,
            reason: '缺 $k 必须报错');
      }
    });

    test('type 非法 → 报错', () {
      final m = _base()..['type'] = 'audio';
      expect(CustomSourceDef.fromJson(m).validate(), isNotEmpty);
    });

    test('baseUrl 指向内网/本机 → 报错（P1 SSRF 既有规则）', () {
      for (final u in [
        'http://127.0.0.1/x',
        'http://localhost/x',
        'http://192.168.1.5/x',
        'http://[::1]/x',
      ]) {
        final m = _base()..['baseUrl'] = u;
        expect(CustomSourceDef.fromJson(m).validate(), isNotEmpty, reason: u);
      }
    });

    test('baseUrl 非 http(s) → 报错', () {
      final m = _base()..['baseUrl'] = 'ftp://example.com';
      expect(CustomSourceDef.fromJson(m).validate(), isNotEmpty);
    });

    test('一条内容规则都没有 → 报错', () {
      final m = _base()
        ..remove('categoryListUrl')
        ..remove('categoryList');
      expect(CustomSourceDef.fromJson(m).validate(), isNotEmpty);
    });

    test('非法正则 → 报错（可编译性预检）', () {
      final m = _base();
      m['categoryList'] = {
        'css': 'a.item',
        'id': 'href',
        'name': 'title',
        'pic': 'src',
        'regex': '(unclosed',
      };
      expect(CustomSourceDef.fromJson(m).validate(), isNotEmpty);
    });
  });

  group('保留 id（P2-18）', () {
    test('内置源 id 集合非空且含已知 id', () {
      final ids = CustomSourceDef.builtinSourceIds;
      expect(ids, isNotEmpty);
      for (final known in ['dm5', 'doubao', 'mangadex', 'jm', 'local']) {
        expect(ids.contains(known), isTrue, reason: known);
      }
    });

    test('每个内置 id 都被拒绝并给出可操作错误', () {
      for (final id in ['dm5', 'mangadex', 'jm', 'doubao', 'local']) {
        final errs = CustomSourceDef.fromJson(_base(id: id)).validate();
        expect(errs, isNotEmpty, reason: id);
        expect(errs.any((e) => e.contains('内置源冲突')), isTrue,
            reason: '$id 的错误信息要说明是 id 冲突：$errs');
      }
    });

    test('不冲突的自定义 id 通过', () {
      for (final id in ['my_source', 'wche_dm', 'ashan_yy']) {
        expect(CustomSourceDef.fromJson(_base(id: id)).validate(), isEmpty,
            reason: id);
      }
    });

    test('内置源 id 与 SourceManager 实际列表一致', () {
      final fromManager = <String>{
        for (final s in SourceManager.sources) s.id,
        for (final s in SourceManager.videoSources) s.id,
        for (final s in SourceManager.novelSources) s.id,
      };
      expect(CustomSourceDef.builtinSourceIds, fromManager,
          reason: '保留集必须实时反映内置源，新增内置源时自动生效');
    });
  });
}
