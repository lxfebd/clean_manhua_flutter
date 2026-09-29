/// 能力构件落盘路径安全：白名单校验与路径包含判断。
///
/// 独立成文件的原因：`capability_artifact_store` 已经 import
/// `capability_plugin`（取 CapabilityArtifact/CapabilityWeight 类型），
/// 若 plugin 反向 import store 取校验函数就成了循环依赖。这里放零依赖的
/// 纯函数，三处调用方（store 落盘、市场索引解析、快照恢复）共用同一份
/// 白名单，避免各写一份正则后口径漂移。
library;

/// 段白名单：字母或数字开头，其后仅字母/数字（含 CJK 等 Unicode 字符）/
/// 点/下划线/连字符，且不含 `..`。
///
/// 用于**直接拼进落盘路径**的远端可控字符串——能力 id、构件文件名、
/// 权重文件名。放开 `../` 会让恶意市场索引越界写文件/递归删目录（purge）；
/// 放行 `.` / `..` 会解析成父目录本身（`purge('.')` 清空整树）。
/// 必须字母或数字开头：`.` 开头即可被构造成 `.` / `..`。
///
/// ⚠️ 中文兼容（2026-09-30 修）：此前的 ASCII-only 白名单会**拒绝中文权
/// 重名**（模型作者常用中文命名，如 `动漫线稿模型.bin`）——市场索引里
/// 完全合法的名称被静默拒掉，用户侧表现为"模型下载不了"。Windows/macOS/
/// 现代 Linux 文件系统都原生支持 UTF-8/UTF-16 文件名，Unicode 字母数字
/// 属于安全字符；真正要挡的只是路径分隔符（`/` `\`）、`.`/`..` 段与
/// 控制字符。Unicode 属性类 `\p{L}`/`\p{N}` 在 Dart 正则里默认开启。
///
/// 全部拒绝的分隔符：`/`、`\`（反斜杠在 Windows 也是路径分隔）、
/// 控制字符（`\x00-\x1f`）、`? * " < > |`（Windows 保留非法文件名字符）。
///
/// ⚠️ `\p{L}`/`\p{N}` 必须带 `unicode: true`：Dart 正则默认 legacy 模式，
/// `\p` 是 identity escape（字面 `p`），`^[\p{L}\p{N}]` 会匹配空集——
/// 所有 ASCII/CJK 名称全被拒（2026-09-30 曾踩：加中文兼容时漏了 unicode
/// 标志，能力 id/权重名全落盘失败）。
bool isValidPathSegment(String s) {
  if (s.isEmpty || s.length > 120) return false;
  if (!RegExp(r'^[\p{L}\p{N}]', unicode: true).hasMatch(s)) return false;
  if (s.contains('..')) return false;
  // 逐个字符排除：路径分隔/Windows 保留字符/控制字符。
  for (final c in s.codeUnits) {
    if (c < 0x20) return false;
    if (c == 0x7f) return false;
    if (c == 0x2f || c == 0x5c) return false; // '/' '\'
    if (c == 0x3a || c == 0x2a || c == 0x3f || c == 0x22 ||
        c == 0x3c || c == 0x3e || c == 0x7c) {
      return false; // : * ? " < > |
    }
  }
  // 其余字符（含 CJK、emoji、扩展区）放行；末尾不留点（Windows 忽略尾点）。
  if (s.endsWith('.') || s.endsWith(' ')) return false;
  return true;
}
