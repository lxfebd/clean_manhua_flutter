import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/source_registry.dart';
import '../sources/source_takdown.dart';
import 'responsive.dart';
import 'style_tokens.dart';

/// 源授权登记册页面（P0-06）。
///
/// ## 这个页面为什么存在
/// 本 App 内置第三方内容源。用户有权知道**每个源是谁在运营、内容从哪来、
/// 有没有授权依据、什么时候复核过、有没有被下架**。把这件事藏起来等于
/// 让用户替我们承担不知情的风险；写出来才是诚实的做法。
///
/// 同时它是**投诉下架入口**：权利人点进来就能看到投诉该走哪里、怎么写。
/// 审查清单要求「提供投诉下架入口」，本页就是那个入口。
///
/// ## 设计上的一个取舍
/// 绝大多数源只能标「授权状态未知」。页面**不试图把它说得好看**——
/// 未知就显示未知，并用醒目的提示说明这意味着什么。这比给个绿色的
/// 「已登记」徽章诚实得多。
class SourceRegistryPage extends StatelessWidget {
  const SourceRegistryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeader(context, theme),
                  Expanded(child: _buildBody(context, theme)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        10,
        Responsive.pagePadding(context),
        0,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: theme.colorScheme.onSurface),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '源授权登记',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme) {
    final byMedia = <String, List<SourceRegistration>>{};
    for (final r in kSourceRegistrations) {
      byMedia.putIfAbsent(r.mediaType, () => []).add(r);
    }
    const order = ['comic', 'video', 'novel'];
    const titles = {'comic': '漫画源', 'video': '动漫源', 'novel': '小说源'};

    return ListView(
      padding: EdgeInsets.fromLTRB(
        Responsive.pagePadding(context),
        8,
        Responsive.pagePadding(context),
        32,
      ),
      children: [
        _DisclaimerCard(theme: theme),
        const SizedBox(height: 14),
        for (final m in order)
          if (byMedia[m]?.isNotEmpty ?? false) ...[
            _SectionTitle(text: titles[m]!),
            const SizedBox(height: 8),
            for (final r in byMedia[m]!) ...[
              _RegistrationCard(
                reg: r,
                takdown: SourceTakdownStoreShadow.current.entryOf(r.sourceId),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 8),
          ],
        _ComplaintCard(theme: theme),
      ],
    );
  }
}

/// 让页面在一次构建里同步拿到下架条目（[SourceTakdownStore.load] 是异步的）。
///
/// 这里刻意做成"可能滞后一拍"的形态：页面主体是**静态登记信息**，
/// 下架条目只影响一行提示文案，不值得为它引入异步状态与加载态。
/// 真正的下架执行点在 [SourceManager._enabledSorted]，不依赖本类。
class SourceTakdownStoreShadow {
  static SourceTakdownList current = SourceTakdownList.empty;
}

/// 顶部免责说明：把「授权状态未知」的含义讲清楚，而不是含糊过去。
class _DisclaimerCard extends StatelessWidget {
  const _DisclaimerCard({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final warn = theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(
          StyleTokens.cardRadiusOr(context, 14),
        ),
        border: Border.all(color: warn.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: warn),
              const SizedBox(width: 6),
              Text(
                '关于授权状态',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: warn,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '「技术上能访问」不等于「已获授权」。本页面如实登记每个内置源的'
            '运营主体、内容范围与授权依据；多数第三方聚合站没有公开授权声明，'
            '因此标注为「授权状态未知」——这不是笔误，是事实。',
            style: theme.textTheme.bodySmall?.copyWith(
              height: 1.6,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '如你是权利人且认为某个源侵犯了你的权益，请使用页面底部的'
            '「投诉下架」入口。',
            style: theme.textTheme.bodySmall?.copyWith(
              height: 1.6,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w800,
        color: theme.colorScheme.onSurface,
      ),
    );
  }
}

/// 单个源的登记卡片。
class _RegistrationCard extends StatelessWidget {
  const _RegistrationCard({required this.reg, this.takdown});

  final SourceRegistration reg;
  final TakdownEntry? takdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final authorized = reg.hasExplicitAuthorization;
    final accent = authorized ? cs.primary : cs.error;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(
          StyleTokens.cardRadiusOr(context, 14),
        ),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  reg.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _Chip(
                text: reg.provenanceLabel,
                color: reg.provenance == SourceProvenance.official
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 6),
              _Chip(text: reg.stateLabel, color: accent),
            ],
          ),
          const SizedBox(height: 10),
          _kv(context, '运营方', reg.operator),
          _kv(context, '内容范围', reg.contentScope),
          _kv(context, '授权依据', reg.basis, valueColor: accent),
          _kv(context, '授权类型', reg.authLabel, valueColor: accent),
          _kv(context, '复核日期', reg.reviewedAt),
          _kv(context, '投诉联系', reg.contact),
          if (takdown != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: cs.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(
          StyleTokens.controlRadiusOr(context, 8),
        ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.gavel_rounded, size: 14, color: cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '下架清单 v${SourceTakdownStoreShadow.current.version}：'
                      '${takdown!.reason.isEmpty ? "已标记" : takdown!.reason}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        height: 1.5,
                        color: cs.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (reg.note != null) ...[
            const SizedBox(height: 8),
            Text(
              reg.note!,
              style: theme.textTheme.labelSmall?.copyWith(
                height: 1.6,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v, {Color? valueColor}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              k,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: theme.textTheme.labelSmall?.copyWith(
                height: 1.5,
                color: valueColor ??
                    theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(
          StyleTokens.controlRadiusOr(context, 8),
        ),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// 投诉下架入口：给出可直接用的投诉模板，支持一键复制。
///
/// 刻意不做「一键自动下架」——那会让任何人凭一句话就能让别人的源失效。
/// 投诉需要人工核实，本卡片负责把流程和材料准备好，不负责替我们做判断。
class _ComplaintCard extends StatelessWidget {
  const _ComplaintCard({required this.theme});

  final ThemeData theme;

  static const String _template = '''
【源下架投诉】

投诉对象源：（请填写源名称，可在上方登记表查到）
涉侵权内容：（作品名 / 具体链接）
权利依据：（著作权登记号 / 授权书 / 平台原始发布链接）
投诉人身份：（权利人本人 / 代理人，附证明）
联系方式：（邮箱，便于回复）
诉求：请从「源授权登记」中下架该源，并在禁用清单中停止其默认启用。

备注：本项目仅提供客户端，不托管任何内容；收到有效投诉后会评估并在
下一个禁用清单版本中处理，旧版本客户端也会通过清单更新停止默认启用。
''';

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(
          StyleTokens.cardRadiusOr(context, 14),
        ),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.outlined_flag_rounded, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                '投诉下架',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '本应用不托管、不存储任何漫画/动漫/小说内容，仅提供访问第三方站点的'
            '客户端能力。若你认为某个内置源侵犯了你的权益，请通过项目仓库的 '
            'issue 提交以下模板，并附权利证明。',
            style: theme.textTheme.bodySmall?.copyWith(
              height: 1.6,
              color: cs.onSurface.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () async {
                  await Clipboard.setData(
                      const ClipboardData(text: _template));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('投诉模板已复制')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: const Text('复制投诉模板'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '处理流程：收到投诉 → 核实权利证明 → 在登记册标记「复核中」/「已下架」'
            '→ 发布新版禁用清单 → 旧版本客户端启动后自动停止默认启用该源。',
            style: theme.textTheme.labelSmall?.copyWith(
              height: 1.6,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}
