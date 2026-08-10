import 'dart:async';
import 'dart:io';

/// 源请求的统一返回类型。
///
/// 对齐 Mihon 的 `SourceResult` / Ani 的 `ApiFailure` 设计：
/// 任何源调用都不再抛"裸异常"污染 UI，而是返回结构化结果，UI 据此给出可操作的反馈
/// （换源 / 去登录 / 重试 / 提示不可用），不白屏、不长时间转圈。
sealed class SourceResult<T> {
  const SourceResult();

  const factory SourceResult.ok(T data) = SourceOk<T>;
  const factory SourceResult.empty() = SourceEmpty<T>;
  const factory SourceResult.err(SourceError error) = SourceErr<T>;
}

final class SourceOk<T> extends SourceResult<T> {
  final T data;
  const SourceOk(this.data);
}

final class SourceEmpty<T> extends SourceResult<T> {
  const SourceEmpty();
}

final class SourceErr<T> extends SourceResult<T> {
  final SourceError error;
  const SourceErr(this.error);
}

/// 源错误类型。对齐 Mihon/Mangayomi 的结构化异常与 Ani 的 `BlockedException(BlockReason)`。
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

/// 源健康状态（对应 Ani 的 `ConnectionStatus`）。
enum ConnectionStatus { success, failed, unknown }

/// 运行一个源调用并自动归约为 [SourceResult]。
///
/// 常见异常会被映射到对应的错误类型，避免每个源都手写 try/catch：
/// - [SocketException]/[TimeoutException] → network
/// - [FormatException] → parse
/// - [HttpException] → service
/// - 已抛出的 [SourceError] → 直接透传
Future<SourceResult<T>> runCatching<T>(Future<T> Function() fn) async {
  try {
    return SourceResult.ok(await fn());
  } on SourceError catch (e) {
    return SourceResult.err(e);
  } on FormatException catch (e) {
    return SourceResult.err(SourceError.parse(e.message));
  } on TimeoutException catch (e) {
    return SourceResult.err(SourceError.network(e.message));
  } on SocketException catch (e) {
    return SourceResult.err(SourceError.network(e.message));
  } on HttpException catch (e) {
    return SourceResult.err(SourceError.service(e.message));
  } catch (e) {
    return SourceResult.err(SourceError.unknown(e.toString()));
  }
}
