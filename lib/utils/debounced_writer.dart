import 'dart:async';

import '../net/error_logger.dart';

/// 防抖 + 串行写盘原语，供书架类存储复用。
///
/// BookshelfStore / NovelShelfStore 原先各自维护一份「300ms 防抖 Timer +
/// 串行 `_writeTail` 链 + 写盘失败日志」，逻辑完全同构，这里收口为单一实现。
/// 调用方只需给出「真正写什么」的闭包（web 走 WebPersist、io 走 writeAsString），
/// 防抖合并、写盘排队、失败可观测全部由本类承担。
///
/// 注意：local_store 的 [_enqueue]（`lib/net/local_store.dart`）**不**并入本类——
/// 它是 per-key 串行队列 + 读-改-写保护 + 返回值语义，与这里的「全量快照防抖落盘」
/// 是两回事；混用会让局部字段更新被整表覆盖。
class DebouncedSerialWriter {
  DebouncedSerialWriter({
    required this.debugName,
    this.onWriteError,
  });

  /// 日志上下文（写盘失败时用于区分是哪个书架）。
  final String debugName;

  /// 写盘失败回调（可选）：调度完成后 [act] 抛异常时同步调用一次，
  /// 书架/小说 store 可据此弹出「写入失败」toast 提示，避免用户长时间
  /// 无感后重启才发现数据未落盘。回调本身抛异常不会向外冒泡——写盘失败的
  /// 兜底仍然是 ErrorLogger.error，UI 层不能反过来打断落盘链路。
  ///
  /// 语义：
  /// - 参数 (Object e, StackTrace st) 与写盘异常一致；
  /// - 一次写失败 = 一次调用，多次防抖合并只调一次；
  /// - 不阻塞后续 schedule，队列继续排队。
  final void Function(Object error, StackTrace stack)? onWriteError;

  /// 防抖窗口：窗口内多次 [schedule] 合并为一次写入。
  static const Duration _delay = Duration(milliseconds: 300);

  Timer? _timer;

  /// 串行写盘队列：防抖触发后只允许一个写操作在途，
  /// 连点收藏/移出时不会并发写坏文件。
  Future<void> _tail = Future.value();

  /// 防抖后执行 [act] 一次，并按调度顺序串行排队。
  ///
  /// [act] 内抛出的写盘异常（磁盘满/权限）统一拦下记 ErrorLogger.error
  /// （原为 warn，静默吞掉导致进程被杀时内存改动永久丢失且无提示），并调用
  /// [onWriteError]（若已注入）让 UI 层有选择地提示用户。不打断主流程——
  /// 否则内存已更新但磁盘没落盘，下次启动数据丢失且无法追溯。
  void schedule(Future<void> Function() act) {
    _timer?.cancel();
    _timer = Timer(_delay, () {
      _tail = _tail.then((_) async {
        try {
          await act();
        } catch (e, st) {
          // 提级为 error：写盘失败是数据丢失风险，用户应能看到；
          // 同时保留 debugName 便于定位是哪个书架的写入失败。
          // ErrorLogger 自身异常（磁盘满、日志目录不可写）也静默兜底，
          // 避免「写日志本身」反过来打断后续写盘队列。
          try {
            ErrorLogger.instance.error(
              '$debugName 写盘失败（内存改动可能丢失）: $e',
              error: e,
            );
          } catch (_) {}
          // 可选回调：让 store/UI 层做提示，本身抛异常时静默兜底，
          // 避免 UI 侧的异常反过来打断后续写盘队列。
          final cb = onWriteError;
          if (cb != null) {
            try {
              cb(e, st);
            } catch (_) {}
          }
        }
      });
    });
  }
}