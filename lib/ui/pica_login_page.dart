import 'package:flutter/material.dart';

import '../sources/picacg_source.dart';
import 'pica_register_page.dart';

/// 哔咔漫画登录页：输入账号密码获取 token，成功后持久化。
class PicaLoginPage extends StatefulWidget {
  const PicaLoginPage({super.key});

  @override
  State<PicaLoginPage> createState() => _PicaLoginPageState();
}

class _PicaLoginPageState extends State<PicaLoginPage> {
  final _email = TextEditingController();
  final _pwd = TextEditingController();
  bool _busy = false;
  String? _msg;

  @override
  void dispose() {
    _email.dispose();
    _pwd.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    final email = _email.text.trim();
    final pwd = _pwd.text;
    if (email.isEmpty || pwd.isEmpty) {
      setState(() => _msg = '请输入邮箱和密码');
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final token = await PicacgSource().login(email, pwd);
      if (token.isNotEmpty) {
        if (mounted) {
          setState(() => _msg = '登录成功');
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('哔咔登录成功')));
          Navigator.of(context).pop(true);
        }
      } else {
        // login() 已修正：token 空时会 throw 真实错误，所以此分支一般不会触发。
        // 保留作为最后兜底提示。
        setState(() => _msg = '登录失败，未获取到 token');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _msg = '登录失败：\n$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('哔咔登录')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text('哔咔漫画（Picacg）需要登录后才能获取数据。',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.outline)),
              const SizedBox(height: 20),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: '邮箱',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _pwd,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码',
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              if (_msg != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_msg!,
                      style: TextStyle(
                          fontSize: 12,
                          color: _msg!.contains('成功')
                              ? Colors.green
                              : theme.colorScheme.error)),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _login,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('登 录'),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const PicaRegisterPage()),
                            );
                          },
                    icon: const Icon(Icons.person_add_alt_outlined, size: 18),
                    label: const Text('注册新账号'),
                  ),
                  TextButton.icon(
                    onPressed: () => _showForgotHelp(),
                    icon: const Icon(Icons.help_outline, size: 18),
                    label: const Text('忘记密码？'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showForgotHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('忘记哔咔密码了？'),
        content: const SingleChildScrollView(
          child: Text(
            '哔咔漫画官方不提供「找回密码」接口，只能通过以下方式：\n\n'
            '1. 在哔咔官网（picacomic.com）用注册邮箱找回密码；\n'
            '2. 若邮箱也忘了，只能重新注册一个新账号（右上角「注册新账号」）。\n\n'
            '温馨提示：注册成功后需要去邮箱点击激活链接，否则无法登录。',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}
