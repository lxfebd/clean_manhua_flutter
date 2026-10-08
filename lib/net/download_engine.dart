import 'dart:async';
import 'dart:io';

/// 泛型下载引擎（P0-1）：漫画批量图 / 视频 m3u8+AES / 更新 Range 续传 三个
/// 下载器共用的队列、取消、停滞守卫、进度节流、防抖持久化原语。
///
/// 各下载器的域逻辑（图片重编码 / 分片解密 / 镜像安装）留在各自的薄适配器，
/// 机械性控制流（并发上限、取消传播、进度节流、写盘合并）统一在本文件。

/// 带停滞超时的分块流：相邻两个块间隔超过 [stall] 即抛超时，
/// 避免「头已返回但 body 悬挂」的下载永远卡住。
/// （漫画批量图下载走 [Net.getBytesAuto] 自带超时，不需要此原语。）
Stream<List<int>> stallGuarded(
  HttpClientResponse resp, {
  Duration stall = const Duration(seconds: 20),
}) async* {
  await for (final chunk in resp.timeout(stall)) {
    yield chunk;
  }
}

/// 取消 token：统一三种取消语义，适配器按需取用子集。
///
/// - 批次代际（漫画批量下载）：[snapshot] 快照当前代号，[isBatchCancelled]
///   判断代号是否已被 [cancelAll] 递增失效；
/// - 单任务 per-key（漫画/视频）：[cancelTask] 打标记（只影响该 key），
///   [isTaskCancelled] 查询，[consumeTaskCancel] 任务开始时消费旧标记、
///   [clearTaskCancel] 显式清除（重试/删除后重新下载）；
/// - 全局开关（更新单下载）：[cancel]/[reset]/[isCancelled]。
///
/// 语义与历史实现逐条对齐（下载任务取消回归测试覆盖）：
/// [cancelAll] 递增代号使已派发批次失效并清空 per-key 标记——不清空则
/// 新任务一启动就把在途旧任务误判为已取消；[cancelTask] 的标记在任务
/// 开始处消费（remove），新任务不继承旧取消状态。
class CancelToken {
  int _gen = 0;
  final Map<String, int> _taskMarks = {};
  bool _flag = false;

  /// 快照当前批次代号（对应漫画侧 [snapshot]）。
  int snapshot() => _gen;

  /// 该批次代号是否已被 [cancelAll] 失效。
  bool isBatchCancelled(int gen) => gen != _gen;

  /// 全局取消（更新单下载用）：置位后 [isCancelled] 为 true。
  void cancel() => _flag = true;

  /// 复位全局取消（新下载开始时调用）。
  void reset() => _flag = false;

  /// 是否已全局取消。
  bool get isCancelled => _flag;

  /// 取消单个任务：只标记该 key，不影响其它任务。
  void cancelTask(String key) => _taskMarks[key] = _gen + 1;

  /// 该 key 是否被 [cancelTask] 标记。
  bool isTaskCancelled(String key) => _taskMarks.containsKey(key);

  /// 消费任务开始前的取消标记：返回是否预取消，并移除标记（新任务不继承）。
  bool consumeTaskCancel(String key) => _taskMarks.remove(key) != null;

  /// 清除某任务的取消标记（重试/删除后重新下载时调用）。
  void clearTaskCancel(String key) => _taskMarks.remove(key);

  /// 取消所有进行中的批次：递增代号使所有已派发批次失效，同时清空
  /// per-key 标记并复位全局开关，避免误取消新任务。
  void cancelAll() {
    _gen++;
    _taskMarks.clear();
    _flag = false;
  }
}

/// 总进度停滞看门狗：周期采样一次字节进度，连续 [maxTicks] 拍零增长
/// 即触发 [onStalled]。任一拍有增长即清零计数——慢速但持续增长的合法
/// 下载不受影响；[isActive] 为 false 时（任务已结束）停止计数。
class StallWatchdog {
  StallWatchdog({
    required this.bytesOf,
    required this.onStalled,
    this.tick = const Duration(seconds: 15),
    this.maxTicks = 6,
    bool Function()? isActive,
  }) : _isActive = isActive;

  final int Function() bytesOf;
  final void Function() onStalled;
  final Duration tick;
  final int maxTicks;
  final bool Function()? _isActive;

  Timer? _timer;
  int _lastBytes = -1;
  int _stallTicks = 0;

  void start() {
    _lastBytes = bytesOf();
    _stallTicks = 0;
    _timer?.cancel();
    _timer = Timer.periodic(tick, (_) {
      if (_isActive != null && !_isActive!()) return;
      final b = bytesOf();
      if (b == _lastBytes) {
        _stallTicks++;
        if (_stallTicks >= maxTicks) onStalled();
      } else {
        _stallTicks = 0;
        _lastBytes = b;
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 进度通知节流：距上次放行不足 [interval] 的调用返回 false（被丢弃）。
/// 与历史实现一致：只有真正放行时才刷新计时点，连续被丢弃的调用不推迟
/// 下一次放行。
class ProgressThrottle {
  ProgressThrottle(this.interval);

  final Duration interval;
  DateTime? _last;

  /// 是否应发出本次通知。[force] 为 true 时无条件放行（完成/失败通知）。
  bool allow({bool force = false}) {
    if (force) {
      _last = DateTime.now();
      return true;
    }
    final now = DateTime.now();
    final last = _last;
    if (last != null && now.difference(last) < interval) return false;
    _last = now;
    return true;
  }
}

/// 防抖持久化：连续 [request] 合并到 [debounce] 窗口末尾写一次；
/// [flush] 立即写（供应用切后台/退出前的关键路径显式调用）。
class DebouncedPersist {
  DebouncedPersist({required this.debounce, required this.write});

  final Duration debounce;
  final Future<void> Function() write;
  Timer? _timer;

  void request() {
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      unawaited(write());
    });
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    unawaited(write());
  }
}

/// 有界任务队列：在途任务未达 [maxConcurrent] 立即运行，否则排队等待；
/// 运行中的任务结束后自动拉起下一个排队任务（视频下载队列语义）。
class TaskQueue<K> {
  TaskQueue({required this.maxConcurrent, required this.run});

  final int maxConcurrent;
  final Future<void> Function(K key) run;

  final List<K> _pending = [];
  final Set<K> _running = <K>{};

  int get runningCount => _running.length;
  bool isRunning(K key) => _running.contains(key);

  /// 提交一个任务：有槽位立即执行，否则入队。
  void submit(K key) {
    if (_running.length < maxConcurrent) {
      _running.add(key);
      unawaited(_wrap(key));
    } else {
      _pending.add(key);
    }
  }

  Future<void> _wrap(K key) async {
    try {
      await run(key);
    } finally {
      complete(key);
    }
  }

  /// 让出运行槽位（任务结束或被删除时），不立即拉起排队任务。
  /// 返回该任务是否确实在运行集合里（删除场景用于判断是否抢到槽位）。
  bool release(K key) => _running.remove(key);

  /// 拉起排队任务直到满槽。任务正常结束时由 [complete] 调用；
  /// 适配器主动释放槽位（如删除任务）后可自行调用补位。
  void drain() {
    while (_pending.isNotEmpty && _running.length < maxConcurrent) {
      final next = _pending.removeAt(0);
      _running.add(next);
      unawaited(_wrap(next));
    }
  }

  /// 任务结束（含异常）：释放槽位并拉起下一个排队任务。
  void complete(K key) {
    release(key);
    drain();
  }

  /// 把仍排队的任务移出队列（取消/删除排队中的任务用）。返回是否真的在队里。
  bool removePending(K key) => _pending.remove(key);

  /// 清空排队任务（不打断在途任务）。
  void clearPending() => _pending.clear();
}
