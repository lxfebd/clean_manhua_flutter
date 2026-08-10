import 'package:flutter/material.dart';

import '../sources/picacg_source.dart';

/// 哔咔漫画注册页：邮箱 + 密码 + 昵称 + 安全问题 + 简介。
class PicaRegisterPage extends StatefulWidget {
  const PicaRegisterPage({super.key});

  @override
  State<PicaRegisterPage> createState() => _PicaRegisterPageState();
}

class _PicaRegisterPageState extends State<PicaRegisterPage> {
  final _email = TextEditingController();
  final _pwd = TextEditingController();
  final _name = TextEditingController();
  final _answer = TextEditingController();
  bool _busy = false;
  String? _msg;

  static const _questions = [
    '你的出生地？',
    '你最喜欢的漫画？',
    '你的宠物名字？',
    '你的小学名字？',
    '你最喜欢的颜色？',
  ];
  String _question = _questions.first;
  int _gender = 0;

  @override
  void dispose() {
    _email.dispose();
    _pwd.dispose();
    _name.dispose();
    _answer.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final email = _email.text.trim();
    final pwd = _pwd.text;
    final name = _name.text.trim();
    final answer = _answer.text.trim();
    if (email.isEmpty || pwd.isEmpty || name.isEmpty || answer.isEmpty) {
      setState(() => _msg = '请填完所有必填项');
      return;
    }
    if (!email.contains('@')) {
      setState(() => _msg = '请输入有效邮箱');
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      await PicacgSource().register(
        email: email,
        password: pwd,
        name: name,
        question: _question,
        answer: answer,
        gender: _gender,
        birth: '2000-01-01',
      );
      if (mounted) {
        setState(() => _msg = '注册成功！请前往邮箱激活账号后返回登录。');
      }
    } catch (e) {
      if (mounted) setState(() => _msg = '注册失败：\n$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('注册哔咔账号')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '哔咔账号可通过邮箱注册。注册成功后需前往邮箱激活，即可用于登录。',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
              ),
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
              const SizedBox(height: 14),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '昵称',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                value: _question,
                decoration: const InputDecoration(
                  labelText: '安全问题',
                  prefixIcon: Icon(Icons.security_outlined),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final q in _questions)
                    DropdownMenuItem(value: q, child: Text(q)),
                ],
                onChanged: (v) => setState(() => _question = v ?? _question),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _answer,
                decoration: const InputDecoration(
                  labelText: '安全问题答案',
                  prefixIcon: Icon(Icons.edit_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              Text('性别',
                  style: TextStyle(
                      fontSize: 13, color: theme.colorScheme.onSurface)),
              const SizedBox(height: 6),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('保密')),
                  ButtonSegment(value: 1, label: Text('男')),
                  ButtonSegment(value: 2, label: Text('女')),
                ],
                selected: {_gender},
                onSelectionChanged: (s) => setState(() => _gender = s.first),
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
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('注 册'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}