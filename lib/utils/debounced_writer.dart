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
  DebouncedSerialWriter({required this.debugName});

  /// 日志上下文（写盘失败时用于区分是哪个书架）。
  final String debugName;

  /// 防抖窗口：窗口内多次 [schedule] 合并为一次写入。
  static const Duration _delay = Duration(milliseconds: 300);

  Timer? _timer;

  /// 串行写盘队列：防抖触发后只允许一个写操作在途，
  /// 连点收藏/移出时不会并发写坏文件。
  Future<void> _tail = Future.value();

  /// 防抖后执行 [act] 一次，并按调度顺序串行排队。
  ///
  /// [act] 内抛出的写盘异常（磁盘满/权限）统一拦下记日志，不打断主流程——
  /// 否则内存已更新但磁盘没落盘，下次启动数据丢失且无法追溯。
  void schedule(Future<void> Function() act) {
    _timer?.cancel();
    _timer = Timer(_delay, () {
      _tail = _tail.then((_) => act()).catchError((Object e) {
        ErrorLogger.instance.warn('$debugName 写盘失败: $e');
      });
    });
  }
}