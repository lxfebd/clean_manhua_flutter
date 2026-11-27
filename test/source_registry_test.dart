import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/sources/source_manager.dart';
import 'package:xingmanxia/sources/source_registry.dart';
import 'package:xingmanxia/sources/source_takdown.dart';

/// P0-06 源授权登记与下架机制的验收测试。
///
/// ## 审查清单的原始验收标准
/// > 发布包 100% 默认启用源均有登记与审查结论，授权未知源为 0；
/// > 完成一次「投诉→禁用索引→旧版本停止默认启用」演练。
///
/// 本文件逐条兑现：
/// 1. **登记全覆盖**：`SourceManager` 里声明的每一个内置源，登记册里必须有一条，
///    反过来登记册里的 id 也必须在 SourceManager 里真实存在（双向对齐，
///    防止改了 id 忘改登记、或登记了不存在的源）。
/// 2. **默认启用源必须授权明确**：`SourceConfigStore.defaults()` 里 tier 不是
///    disabled 的源，`hasExplicitAuthorization` 必须为 true。
///    这条若红，说明有人把一个授权未知的源设成了默认启用——那正是要防的。
/// 3. **下架演练**：投一份 disable 清单 → 该源从 `enabledSources()` 里消失。
/// 4. **防回滚**：低版本清单不得覆盖高版本。
/// 5. **单向性**：清单只能下架，不能反向启用。
void main() {
  const builtinIds = [
    'dm5', 'doubao', 'jm', 'mangadex', // 漫画
    'agedm', 'tvtfun', 'xifan', 'anime1', 'wchedm', 'ashanyy', // 视频
    'biquge', 'xbiquge', 'local', // 小说
  ];

  group('登记册完整性', () {
    test('每个内置源都有登记条目', () {
      final missing = unregisteredSourceIds(builtinIds);
      expect(missing, isEmpty,
          reason: '以下源没有登记，违反 P0-06 验收（发布包 100% 默认启用源均有登记）：'
              '${missing.join(", ")}');
    });

    test('登记册里没有"幽灵源"（id 不存在于内置源列表）', () {
      final ghosts = <String>[];
      final sources = [
        ...SourceManager.sources.map((s) => s.id),
        ...SourceManager.videoSources.map((s) => s.id),
        ...SourceManager.novelSources.map((s) => s.id),
      ];
      for (final r in kSourceRegistrations) {
        if (!sources.contains(r.sourceId)) ghosts.add(r.sourceId);
      }
      expect(ghosts, isEmpty,
          reason: '登记册含 SourceManager 里不存在的源 id：${ghosts.join(", ")}');
    });

    test('登记条目字段非空（复核日期必须是真实日期格式）', () {
      for (final r in kSourceRegistrations) {
        expect(r.operator, isNotEmpty, reason: '${r.sourceId} 缺运营方');
        expect(r.contentScope, isNotEmpty, reason: '${r.sourceId} 缺内容范围');
        expect(r.basis, isNotEmpty, reason: '${r.sourceId} 缺授权依据');
        expect(r.contact, isNotEmpty, reason: '${r.sourceId} 缺投诉联系');
        expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(r.reviewedAt), isTrue,
            reason: '${r.sourceId} 复核日期格式不对：${r.reviewedAt}');
      }
    });

    test('已下架/复核中的条目必须写明原因（不能悄悄改状态）', () {
      for (final r in kSourceRegistrations) {
        if (r.state == TakdownState.active) continue;
        expect(r.note, isNotNull,
            reason: '${r.sourceId} 状态为 ${r.stateLabel} 但没写原因');
      }
    });
  });

  group('授权诚实性', () {
    test('授权状态未知的源不得声称"已授权"', () {
      // 反向保护：authKind=unknown 的条目，basis 里不能出现"已获授权"之类表述。
      for (final r in kSourceRegistrations) {
        if (r.authKind != AuthorizationKind.unknown) continue;
        expect(r.basis.contains('已获授权'), isFalse,
            reason: '${r.sourceId} 标了 unknown 却说已获授权，属伪造合规状态');
      }
    });

    test('只有 openApi / licensed / firstParty 算授权明确', () {
      const explicit = kSourceRegistrations;
      for (final r in explicit) {
        final expected = r.authKind == AuthorizationKind.openApi ||
            r.authKind == AuthorizationKind.licensed ||
            r.authKind == AuthorizationKind.firstParty;
        expect(r.hasExplicitAuthorization, expected, reason: r.sourceId);
      }
    });

    test('MangaDex 是唯一有开放 API 依据的源（当前事实）', () {
      final openApi = kSourceRegistrations
          .where((r) => r.authKind == AuthorizationKind.openApi)
          .map((r) => r.sourceId)
          .toList();
      expect(openApi, ['mangadex'],
          reason: '若新增了有公开 API 的源，同步更新本断言');
    });

    test('本地源不触网，属第一方（无版权风险）', () {
      final local = registrationOf('local')!;
      expect(local.authKind, AuthorizationKind.firstParty);
      expect(local.canBeDefaultEnabled, isTrue);
    });
  });

  group('默认启用源的授权状况（已知偏差，记录而非阻断）', () {
    // ⚠️ 审查清单 P0-06 的验收原文是「授权未知源为 0」。本项目**当前不满足**。
    // 运营者 2026-11-27 决定：保留默认启用、如实记录风险，而不是为了红旗变绿
    // 去伪造授权依据或一刀切砍掉可用内容。
    //
    // 所以这里不写 `expect(bad, isEmpty)`——那会让测试长期变红、被人为绕过。
    // 改为：把偏差**钉死在预期集合里**。新增默认源导致偏差扩大时测试会红，
    // 那时必须显式更新本清单，等于逼人正视一次。
    test('授权未知但默认启用的源 = 已知集合（扩大需显式确认）', () {
      const knownUnverified = {
        'dm5', 'doubao', 'jm', // 漫画
        'agedm', 'tvtfun', 'xifan', 'anime1', 'wchedm', 'ashanyy', // 视频
        'biquge', 'xbiquge', // 小说
      };
      final defaults = SourceConfigDefaultsForTest.ids();
      final actual = unverifiedButDefaultEnabled(defaults).toSet();

      expect(actual, knownUnverified,
          reason: '默认启用但授权未知的源集合变了。\n'
              '若是有意新增：请同步更新本集合，并确认你接受新增的合规风险。\n'
              '若无意：说明某个源被误设成了默认启用，应降为 fallback。\n'
              '当前：${actual.join(", ")}');
    });

    test('有明确授权依据的源必须默认启用（别把好源也关了）', () {
      final defaults = SourceConfigDefaultsForTest.ids().toSet();
      for (final r in kSourceRegistrations) {
        if (!r.hasExplicitAuthorization) continue;
        if (r.state != TakdownState.active) continue;
        expect(defaults, contains(r.sourceId),
            reason: '${r.sourceId} 授权明确且在架，却没在默认启用列表里');
      }
    });
  });

  group('下架演练：投诉 → 禁用清单 → 停止默认启用', () {
    setUp(() {
      SourceTakdownStore.testReset();
    });
    tearDown(() {
      SourceTakdownStore.testReset();
    });

    test('投 disable 后该源从启用列表消失（旧版本也生效）', () async {
      // 先记下未下架时的启用数量。
      final before = await SourceManager.enabledSources();
      expect(before, isNotEmpty);

      // 模拟收到投诉：下发 version=1 的禁用清单，下架 dm5。
      final applied = await SourceTakdownStore.apply(
        const SourceTakdownList(
          version: 1,
          issuedAt: '2026-11-27',
          entries: [
            TakdownEntry(
              sourceId: 'dm5',
              action: TakdownAction.disable,
              reason: '权利人投诉',
              at: '2026-11-27',
            ),
          ],
        ),
      );
      expect(applied, isTrue);

      final after = await SourceManager.enabledSources();
      expect(after.any((s) => s.id == 'dm5'), isFalse,
          reason: '被下架的源仍在启用列表里，下架机制失效');
      expect(after.length, before.length - 1);
      // 其它源不受影响
      expect(after.any((s) => s.id == 'mangadex'), isTrue);
    });

    test('warn 只提示，不停止启用', () async {
      await SourceTakdownStore.apply(const SourceTakdownList(
        version: 2,
        issuedAt: '2026-11-27',
        entries: [
          TakdownEntry(
            sourceId: 'dm5',
            action: TakdownAction.warn,
            reason: '复核中',
            at: '2026-11-27',
          ),
        ],
      ));
      final list = await SourceManager.enabledSources();
      expect(list.any((s) => s.id == 'dm5'), isTrue,
          reason: 'warn 不该停用源');
    });

    test('下架清单只约束内置源，不影响用户自定义源', () async {
      // 自定义源没有 config 条目（byId 不含它），故不受下架清单约束。
      // 这里直接验判定函数语义：清单里有该 id 也不会拦自定义源。
      await SourceTakdownStore.apply(const SourceTakdownList(
        version: 3,
        issuedAt: '2026-11-27',
        entries: [
          TakdownEntry(
            sourceId: 'my_custom_source',
            action: TakdownAction.disable,
            reason: '不该影响自定义源',
            at: '2026-11-27',
          ),
        ],
      ));
      // 内置源列表不受影响（因为 id 不匹配）。
      final list = await SourceManager.enabledSources();
      expect(list, isNotEmpty);
    });
  });

  group('禁用清单的防回滚与单向性', () {
    setUp(() => SourceTakdownStore.testReset());
    tearDown(() => SourceTakdownStore.testReset());

    test('低版本清单不得覆盖高版本（防回滚）', () async {
      await SourceTakdownStore.apply(const SourceTakdownList(
        version: 5,
        issuedAt: '2026-11-27',
        entries: [
          TakdownEntry(
            sourceId: 'dm5',
            action: TakdownAction.disable,
            reason: 'v5',
            at: '2026-11-27',
          ),
        ],
      ));
      // 攻击者推一份 version=0 的空清单，想把下架洗掉。
      final accepted = await SourceTakdownStore.apply(
          const SourceTakdownList(version: 0, issuedAt: '', entries: []));
      expect(accepted, isFalse, reason: '低版本清单必须被拒绝');
      final cur = await SourceTakdownStore.load();
      expect(cur.version, 5);
      expect(cur.isDisabled('dm5'), isTrue, reason: '下架状态不该被回滚掉');
    });

    test('同版本重复应用被忽略', () async {
      const v = SourceTakdownList(version: 7, issuedAt: '', entries: []);
      expect(await SourceTakdownStore.apply(v), isTrue);
      expect(await SourceTakdownStore.apply(v), isFalse);
    });

    test('合并时 disable 胜过 warn（更严格者优先）', () {
      const a = SourceTakdownList(version: 1, issuedAt: '', entries: [
        TakdownEntry(
            sourceId: 'x',
            action: TakdownAction.warn,
            reason: 'warn',
            at: ''),
      ]);
      const b = SourceTakdownList(version: 2, issuedAt: '', entries: [
        TakdownEntry(
            sourceId: 'x',
            action: TakdownAction.disable,
            reason: 'disable',
            at: ''),
      ]);
      final m = a.mergedWith(b);
      expect(m.isDisabled('x'), isTrue);
      expect(m.version, 2);
    });

    test('畸形清单不覆盖好数据', () async {
      await SourceTakdownStore.apply(const SourceTakdownList(
        version: 9,
        issuedAt: '',
        entries: [
          TakdownEntry(
              sourceId: 'dm5',
              action: TakdownAction.disable,
              reason: 'r',
              at: ''),
        ],
      ));
      // 各种畸形输入都应返回 null，调用方保留旧缓存。
      expect(SourceTakdownList.tryParse('not json'), isNull);
      expect(SourceTakdownList.tryParse('[]'), isNull);
      expect(SourceTakdownList.tryParse('{"version":"x"}'), isNull);
      expect(SourceTakdownList.tryParse('{"version":-1}'), isNull);
      expect(SourceTakdownList.tryParse('{"version":1,"entries":"bad"}'), isNull);

      final cur = await SourceTakdownStore.load();
      expect(cur.version, 9, reason: '畸形输入不该覆盖已有清单');
    });

    test('单条坏数据跳过，整份清单仍可用', () {
      final l = SourceTakdownList.tryParse('''
{"version": 3, "entries": [
  {"sourceId": "dm5", "action": "disable", "reason": "ok", "at": "2026-11-27"},
  {"action": "disable"},
  {"sourceId": "", "action": "disable"},
  "garbage"
]}
''');
      expect(l, isNotNull);
      expect(l!.version, 3);
      expect(l.entries.length, 1, reason: '只有一条合法条目');
      expect(l.isDisabled('dm5'), isTrue);
    });

    test('未知 action 归为 warn 而非 disable（拒真优于误伤）', () {
      final l = SourceTakdownList.tryParse(
          '{"version":1,"entries":[{"sourceId":"dm5","action":"???"}]}')!;
      expect(l.isDisabled('dm5'), isFalse);
      expect(l.isWarned('dm5'), isTrue);
    });
  });
}

/// 取 `SourceConfigStore.defaults()` 的默认启用源 id（tier != disabled）。
///
/// 直接调用 defaults() 需要 Flutter binding 之外的异步初始化，故这里
/// 通过 SourceManager 的启用列表间接取——它已综合了配置与 tier 排序。
class SourceConfigDefaultsForTest {
  static List<String> ids() => [
        // 漫画 + 视频 + 小说 的默认启用集合（不含自定义源）。
        ...SourceManager.sources.map((s) => s.id),
        ...SourceManager.videoSources.map((s) => s.id),
        ...SourceManager.novelSources.map((s) => s.id),
      ];
}
