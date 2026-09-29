/// 能力构件落盘路径安全：白名单校验与路径包含判断。
///
/// 独立成文件的原因：`capability_artifact_store` 已经 import
/// `capability_plugin`（取 CapabilityArtifact/CapabilityWeight 类型），
/// 若 plugin 反向 import store 取校验函数就成了循环依赖。这里放零依赖的
/// 纯函数，三处调用方（store 落盘、市场索引解析、快照恢复）共用同一份
/// 白名单，避免各写一份正则后口径漂移。
library;

/// 段白名单：字母或数字开头，其后仅字母/数字/点/下划线/连字符，且不含 `..`。
///
/// 用于**直接拼进落盘路径**的远端可控字符串——能力 id、构件文件名、
/// 权重文件名。放开 `../` 会让恶意市场索引越界写文件/递归删目录（purge）；
/// 放行 `.` / `..` 会解析成父目录本身（`purge('.')` 清空整树）。
/// 必须字母或数字开头：`.` 开头即可被构造成 `.` / `..`。
bool isValidPathSegment(String s) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(s) && !s.contains('..');
