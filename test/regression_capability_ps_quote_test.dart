import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/capabilities/process_timeout.dart';

/// H1 回归：PowerShell 命令串不得把远端可控路径按双引号插值。
///
/// zip 路径的文件名段来自远端 URL，恶意市场索引可构造含 `$(...)` 的文件名；
/// 双引号串在 PowerShell 里会求值 `$(...)`（命令注入），单引号串不会。
void main() {
  group('psSingleQuote（PowerShell 字面量）', () {
    test('包裹为单引号串', () {
      expect(psSingleQuote(r'C:\a\b.zip'), r"'C:\a\b.zip'");
    });

    test('内部单引号加倍转义（PowerShell 规则）', () {
      expect(psSingleQuote("a'b"), "'a''b'");
      expect(psSingleQuote("it's a 'test'"), "'it''s a ''test'''");
    });

    test(r'$() 与反引号原样保留（单引号串不求值、不转义）', () {
      expect(psSingleQuote(r'$(calc).zip'), r"'$(calc).zip'");
      expect(psSingleQuote(r'a`b.zip'), r"'a`b.zip'");
    });
  });

  group('psExpandArchiveCommand（防注入）', () {
    test('两条路径都经单引号包裹', () {
      final cmd = psExpandArchiveCommand(r'C:\tmp\a.zip', r'C:\out');
      expect(cmd, r"Expand-Archive -LiteralPath 'C:\tmp\a.zip' "
          r"-DestinationPath 'C:\out' -Force");
    });

    test(r'含 $() 的恶意文件名被引号锁死，不构成子表达式', () {
      final cmd = psExpandArchiveCommand(
        r'C:\tmp\$(Start-Process calc).zip',
        r'C:\out',
      );
      // 关键：$( 前面必须是单引号而非双引号——双引号串会执行它。
      expect(cmd, contains(r"-LiteralPath 'C:\tmp\$(Start-Process calc).zip'"));
      expect(cmd.contains('"'), isFalse, reason: '命令串不得含双引号插值');
    });

    test('路径含空格仍保持单个参数（引号不丢）', () {
      final cmd = psExpandArchiveCommand(r'C:\my tmp\arch ive.zip', r'C:\out');
      expect(cmd, contains(r"'C:\my tmp\arch ive.zip'"));
      expect(cmd, contains(r"'C:\out'"));
    });
  });
}
