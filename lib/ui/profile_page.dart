import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sources/picacg_source.dart';
import '../sources/source_manager.dart';
import 'pica_login_page.dart';
import 'widgets/motion.dart';

/// 我的页面：登录状态、数据源列表、跳转入口。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  @override
  void initState() {
    super.initState();
    PicacgSource.bindTokenFile(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final loggedIn = PicacgSource.isLoggedIn;
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 110),
          children: [
            FadeSlideIn(
              duration: const Duration(milliseconds: 380),
              child: Text(
                  '我的',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
            ),
            const SizedBox(height: 20),
            // 账号卡
            FadeSlideIn(
              delay: const Duration(milliseconds: 80),
              child: _AccountCard(loggedIn: loggedIn, onTap: _onAccountTap),
            ),
            const SizedBox(height: 16),
            // 数据源列表
            FadeSlideIn(
              delay: const Duration(milliseconds: 160),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: scheme.onSurface.withValues(alpha: 0.06)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 3,
                          height: 13,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '数据源',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${SourceManager.sources.length}',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    for (var i = 0; i < SourceManager.sources.length; i++)
                      FadeSlideIn(
                        delay: Duration(milliseconds: 200 + 50 * i),
                        offset: 8,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: scheme.primary.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  _iconFor(SourceManager.sources[i].id),
                                  size: 16,
                                  color: scheme.primary,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                SourceManager.sources[i].name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FadeSlideIn(
              delay: const Duration(milliseconds: 240),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: scheme.onSurface.withValues(alpha: 0.06)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 3,
                          height: 13,
                          decoration: BoxDecoration(
                            color: scheme.secondary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '关于',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '「星漫匣」多源聚合阅读器。\n为热爱漫画/动漫的你，提供纯净的阅读体验。',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.7,
                        color: scheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String id) {
    switch (id) {
      case 'picacg':
        return Icons.vpn_key_outlined;
      case 'jm':
        return Icons.collections_bookmark_rounded;
      case 'mangadex':
        return Icons.public_rounded;
      case 'doubao':
        return Icons.menu_book_rounded;
      case 'yyfun':
        return Icons.translate_rounded;
      default:
        return Icons.source_outlined;
    }
  }

  Future<void> _onAccountTap() async {
    HapticFeedback.selectionClick();
    final loggedIn = PicacgSource.isLoggedIn;
    if (loggedIn) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          title: const Text('登出'),
          content: const Text('确定退出哔咔账号吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('登出'),
            ),
          ],
        ),
      );
      if (ok == true) {
        PicacgSource.logout();
        if (mounted) setState(() {});
      }
    } else {
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => const PicaLoginPage()));
      if (mounted) setState(() {});
    }
  }
}

class _AccountCard extends StatelessWidget {
  final bool loggedIn;
  final VoidCallback onTap;
  const _AccountCard({required this.loggedIn, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: loggedIn
                ? [scheme.primary, scheme.primary.withValues(alpha: 0.7)]
                : [
                    scheme.surfaceContainerHighest,
                    scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                  ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: loggedIn
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.30),
                    blurRadius: 18,
                    spreadRadius: -4,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: loggedIn
                    ? Colors.white.withValues(alpha: 0.25)
                    : scheme.primary.withValues(alpha: 0.18),
              ),
              child: Icon(
                loggedIn
                    ? Icons.bolt_rounded
                    : Icons.vpn_key_outlined,
                size: 28,
                color: loggedIn ? Colors.white : scheme.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loggedIn ? '哔咔账号' : '哔咔漫画',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: loggedIn
                          ? Colors.white
                          : scheme.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    loggedIn ? '已登录 · 点击查看账号信息' : '未登录 · 点击登录账号',
                    style: TextStyle(
                      fontSize: 11,
                      color: loggedIn
                          ? Colors.white.withValues(alpha: 0.85)
                          : scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (loggedIn)
              const Icon(Icons.chevron_right, color: Colors.white)
            else
              Icon(Icons.chevron_right,
                  color: scheme.onSurface.withValues(alpha: 0.5)),
          ],
        ),
      ),
    );
  }
}
