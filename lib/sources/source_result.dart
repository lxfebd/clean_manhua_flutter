/// 源错误类型。对齐 Mihon/Mangayomi 的结构化异常与 Ani 的 `BlockedException(BlockReason)`。
///
/// 源接口失败时**直接 throw** 具体子类型（网络/服务/鉴权/风控/解析/未知），
/// UI 按类型给出可操作反馈（换源 / 去登录 / 重试 / 提示不可用），
/// 不白屏、不长时间转圈。由 [SourceHttp] 与 DSL 源的统一网络出口负责归约，
/// 其余代码不再经过「包上 SourceResult → 立刻拆开」的中间层。
sealed class SourceError {
  const SourceError();

  const factory SourceError.network([String? message]) = SourceNetwork;
  const factory SourceError.service([String? message]) = SourceService;
  const factory SourceError.unauthorized([String? message]) = SourceUnauthorized;
  const factory SourceError.blocked(BlockReason reason, [String? message]) =
      SourceBlocked;
  const factory SourceError.parse([String? message]) = SourceParse;
  const factory SourceError.unknown([String? message]) = SourceUnknown;
}

final class SourceNetwork extends SourceError {
  final String? message;
  const SourceNetwork([this.message]);
  @override
  String toString() => '网络错误${message != null ? ': $message' : ''}';
}

final class SourceService extends SourceError {
  final String? message;
  const SourceService([this.message]);
  @override
  String toString() => '服务不可用${message != null ? ': $message' : ''}';
}

final class SourceUnauthorized extends SourceError {
  final String? message;
  const SourceUnauthorized([this.message]);
  @override
  String toString() => '需要登录${message != null ? ': $message' : ''}';
}

final class SourceBlocked extends SourceError {
  final BlockReason reason;
  final String? message;
  const SourceBlocked(this.reason, [this.message]);
  @override
  String toString() =>
      '被拦截(${reason.name})${message != null ? ': $message' : ''}';
}

final class SourceParse extends SourceError {
  final String? message;
  const SourceParse([this.message]);
  @override
  String toString() => '解析失败${message != null ? ': $message' : ''}';
}

final class SourceUnknown extends SourceError {
  final String? message;
  const SourceUnknown([this.message]);
  @override
  String toString() => '未知错误${message != null ? ': $message' : ''}';
}

/// 拦截原因（对应 Ani 的 `BlockReason`）。
enum BlockReason { captcha, rateLimited, notFound }