import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../net/http_client.dart';
import '../net/local_store.dart';
import '../net/self_signed_trust.dart';
import 'responsive.dart';
import 'style_tokens.dart';
import 'widgets/app_toast.dart';

/// 自签证书信任管理页（P1-27）。
///
/// ## 这个页面取代了什么
/// 旧版是一个「信任自签证书」总开关：打开后**所有主机**都不校验证书。
/// 用户为了连家里的 NAS 打开它，代价是 GitHub 更新包、源市场索引、全部
/// 内容源同时失去 MITM 防护——一个中间人伪造任意证书就能推送恶意更新包。
///
/// 现在改成按「主机 + 指纹」逐条登记：只有你明确核对过指纹的那一台机器
/// 才被信任，其它一切照旧严格。GitHub / 市场 / 更新链无论怎么登记都严格。
///
/// ## 怎么拿到指纹
/// 页面里给了命令（openssl / 浏览器导出），用户在自己电脑上执行，
/// 把结果粘贴进来。**不自动抓取**——自动抓等于"谁先连上就信谁"，
/// 那样这个功能就白做了。
class SelfSignedTrustPage extends StatefulWidget {
  const SelfSignedTrustPage({super.key});

  @override
  State<SelfSignedTrustPage> createState() => _SelfSignedTrustPageState();
}

class _SelfSignedTrustPageState extends State<SelfSignedTrustPage> {
  List<SelfSignedTrustRule> _rules = const [];

  @override
  void initState() {
    super.initState();
    _rules = SelfSignedTrust.rules;
  }

  Future<void> _persist() async {
    await LocalStore.writeJson(
        'self_signed_trust_rules', SelfSignedTrust.toJson());
  }

  Future<void> _add() async {
    final r = await showDialog<SelfSignedTrustRule>(
      context: context,
      builder: (_) => const _AddRuleDialog(),
    );
    if (r == null) return;
    // 永久严格主机的规则直接拒绝（Dialog 里也可能校验，这里再兜一层，
    // 因为规则也可能从备份恢复进来）。
    if (isAlwaysStrictHost(r.host)) {
      if (mounted) {
        AppToast.show(context, '${r.host} 属于更新/市场通道，不允许信任自签');
      }
      return;
    }
    final next = [
      ..._rules.where((e) => e.host != r.host), // 同主机覆盖
      r,
    ];
    SelfSignedTrust.replaceAll(next);
    await _persist();
    if (mounted) {
      setState(() => _rules = SelfSignedTrust.rules);
      AppToast.show(context, '已信任 ${r.host}');
    }
  }

  Future<void> _remove(SelfSignedTrustRule r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除信任'),
        content: Text('移除后 ${r.host} 将恢复严格证书校验。\n'
            '如果它是自签证书，连接会失败——这是预期行为。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    SelfSignedTrust.replaceAll(
        _rules.where((e) => e.host != r.host).toList());
    await _persist();
    if (mounted) setState(() => _rules = SelfSignedTrust.rules);
  }

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
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        Responsive.pagePadding(context), 10,
                        Responsive.pagePadding(context), 0),
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
                          child: Text('自签证书信任',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.displaySmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: theme.colorScheme.onSurface,
                              )),
                        ),
                        IconButton(
                          tooltip: '添加受信主机',
                          onPressed: _add,
                          icon: Icon(Icons.add_rounded,
                              size: 20, color: theme.colorScheme.primary),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(
                          Responsive.pagePadding(context), 8,
                          Responsive.pagePadding(context), 32),
                      children: [
                        _ExplainCard(theme: theme),
                        const SizedBox(height: 14),
                        if (Net.legacySelfSignedWasOn) ...[
                          _LegacyWarningCard(theme: theme),
                          const SizedBox(height: 14),
                        ],
                        if (_rules.isEmpty)
                          _EmptyCard(theme: theme)
                        else
                          for (final r in _rules) ...[
                            _RuleCard(
                              rule: r,
                              onRemove: () => _remove(r),
                            ),
                            const SizedBox(height: 8),
                          ],
                        const SizedBox(height: 14),
                        _HowToCard(theme: theme),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部说明：讲清楚为什么不再是开关。
class _ExplainCard extends StatelessWidget {
  const _ExplainCard({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.06),
        borderRadius:
            BorderRadius.circular(StyleTokens.cardRadiusOr(context, 14)),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.shield_outlined, size: 16, color: cs.primary),
            const SizedBox(width: 6),
            Text('按主机 + 指纹信任，不再是全局开关',
                style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700, color: cs.primary)),
          ]),
          const SizedBox(height: 8),
          Text(
            '旧版有一个「信任自签证书」总开关，打开后整个应用都不再校验'
            '服务器证书——包括更新包下载和源市场索引。那意味着一个中间人'
            '只要伪造证书，就能给你推送恶意更新包。\n\n'
            '现在改成逐条登记：只有你亲手核对过证书指纹的那台服务器'
            '（通常是家里的 NAS）才被信任，其它一切照旧严格校验。',
            style: theme.textTheme.bodySmall?.copyWith(
                height: 1.6, color: cs.onSurface.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }
}

/// 旧开关曾开启的提示。
class _LegacyWarningCard extends StatelessWidget {
  const _LegacyWarningCard({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.07),
        borderRadius:
            BorderRadius.circular(StyleTokens.cardRadiusOr(context, 14)),
        border: Border.all(color: cs.error.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '你之前打开过旧版的「信任自签证书」开关。该开关已不再生效——'
              '如果某台自签服务器现在连不上，请在这里登记它的主机与指纹。',
              style: theme.textTheme.bodySmall?.copyWith(
                  height: 1.6, color: cs.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.03),
        borderRadius:
            BorderRadius.circular(StyleTokens.cardRadiusOr(context, 14)),
      ),
      child: Column(
        children: [
          Icon(Icons.verified_user_outlined,
              size: 28,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 10),
          Text('未登记任何受信主机',
              style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 4),
          Text('所有 HTTPS 都在严格校验（推荐状态）',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.45))),
        ],
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({required this.rule, required this.onRemove});
  final SelfSignedTrustRule rule;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.03),
        borderRadius:
            BorderRadius.circular(StyleTokens.cardRadiusOr(context, 14)),
        border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Icon(Icons.dns_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(rule.host,
                    style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700, color: cs.onSurface)),
                const SizedBox(height: 3),
                Text(
                  // 指纹太长，居中省略没意义，这里折叠展示首尾
                  _shortFingerprint(rule.fingerprint),
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: cs.onSurface.withValues(alpha: 0.55)),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '移除',
            onPressed: onRemove,
            icon: Icon(Icons.delete_outline_rounded, size: 18, color: cs.error),
          ),
        ],
      ),
    );
  }

  static String _shortFingerprint(String f) {
    if (f.length <= 17) return f;
    // 显示前 8 + … + 后 8，够用户比对来源，也不撑破布局
    return '${f.substring(0, 8)}…${f.substring(f.length - 8)}';
  }
}

/// 怎么获取指纹。
class _HowToCard extends StatelessWidget {
  const _HowToCard({required this.theme});
  final ThemeData theme;

  static const String _cmd =
      'openssl s_client -connect 你的NAS地址:5006 -servername 你的NAS地址 </dev/null 2>/dev/null \\\n'
      '  | openssl x509 -noout -fingerprint -sha1';

  @override
  Widget build(BuildContext context) {
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.03),
        borderRadius:
            BorderRadius.circular(StyleTokens.cardRadiusOr(context, 14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('如何获取证书指纹',
              style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700, color: cs.onSurface)),
          const SizedBox(height: 8),
          Text(
            '在电脑上执行下面这条命令，把输出的指纹粘到添加对话框里：',
            style: theme.textTheme.bodySmall?.copyWith(
                height: 1.6, color: cs.onSurface.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.06),
              borderRadius:
                  BorderRadius.circular(StyleTokens.controlRadiusOr(context, 8)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(_cmd,
                      style: theme.textTheme.labelSmall?.copyWith(
                          fontFamily: 'monospace', height: 1.5)),
                ),
                IconButton(
                  tooltip: '复制命令',
                  onPressed: () async {
                    await Clipboard.setData(const ClipboardData(text: _cmd));
                    if (!context.mounted) return;
                    AppToast.show(context, '命令已复制');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '注意：应用不会替你自动抓取指纹——自动抓等于"谁先连上就信谁"，'
            '那样这个功能就没有意义了。指纹必须由你在可信环境下核对。',
            style: theme.textTheme.labelSmall?.copyWith(
                height: 1.6, color: cs.onSurface.withValues(alpha: 0.5)),
          ),
        ],
      ),
    );
  }
}

/// 添加规则对话框。
class _AddRuleDialog extends StatefulWidget {
  const _AddRuleDialog();

  @override
  State<_AddRuleDialog> createState() => _AddRuleDialogState();
}

class _AddRuleDialogState extends State<_AddRuleDialog> {
  final _hostCtrl = TextEditingController();
  final _fpCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _hostCtrl.dispose();
    _fpCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _hostCtrl.text.trim().toLowerCase();
    final fp = normalizeFingerprint(_fpCtrl.text);
    if (host.isEmpty) {
      setState(() => _error = '请填写主机名（不含 https:// 与端口）');
      return;
    }
    if (host.contains('/') || host.contains(':')) {
      setState(() => _error = '只填主机名，例如 nas.local 或 192.168.1.10');
      return;
    }
    if (isAlwaysStrictHost(host)) {
      setState(() => _error = '$host 属于更新/市场通道，永远严格校验，不能登记');
      return;
    }
    if (fp.isEmpty) {
      setState(() => _error = '请填写证书指纹');
      return;
    }
    // SHA-1 十六进制 = 40 字符。长度不对直接拒绝，避免用户粘错内容。
    if (fp.length != 40 || !RegExp(r'^[0-9a-f]+$').hasMatch(fp)) {
      setState(() => _error = '指纹格式不对：应为 40 位十六进制（SHA-1）');
      return;
    }
    Navigator.pop(context,
        SelfSignedTrustRule(host: host, fingerprint: fp));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加受信主机'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _hostCtrl,
            decoration: const InputDecoration(
              labelText: '主机名',
              hintText: 'nas.local',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _fpCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '证书指纹（SHA-1）',
              hintText: 'AB:CD:EF:…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}
