import 'package:wakelock_plus/wakelock_plus.dart';

/// 屏幕常亮的**引用计数**守卫（P1-25）。
///
/// ## 为什么需要
/// 旧实现把常亮做成全局开关（`main.dart` 的 resumed/inactive 都 enable），
/// 于是首页/书架/详情/设置全都 30 秒不熄屏——白白耗电、OLED 烧屏风险，
/// 而用户并没有在阅读/播放。
///
/// 移除全局开关后，常亮改由「确实需要」的页面自己持有；但页面切换存在
/// **交错**：动漫播放页 `_fallbackSwitch` 用 `pushReplacement` 换成原生播放器，
/// 新页 `initState` 与旧页 `dispose` 的先后不由我们决定——若各页面直接
/// enable/disable，后跑的 dispose 会把新页刚拿到的常亮关掉。引用计数
/// 让「最后一个真正需要常亮的页面退出时才释放」。
///
/// 用法（页面级，成对出现）：
/// ```dart
/// @override
/// void initState() { super.initState(); WakelockGuard.instance.acquire(); }
/// @override
/// void dispose() { WakelockGuard.instance.release(); super.dispose(); }
/// ```
class WakelockGuard {
  WakelockGuard._();
  static final WakelockGuard instance = WakelockGuard._();

  int _refs = 0;

  /// 当前持有常亮的页面数（测试与诊断用）。
  int get refs => _refs;

  /// 是否正在持有常亮。
  bool get holding => _refs > 0;

  /// 进入「需要常亮」的页面。幂等：同一页面重复 acquire 会正确计数。
  void acquire() {
    _refs++;
    if (_refs == 1) _apply(true);
  }

  /// 离开「需要常亮」的页面。最后一个释放时才真正关掉常亮。
  /// 多余调用被夹紧到 0，不会把计数压成负数。
  void release() {
    if (_refs == 0) return;
    _refs--;
    if (_refs == 0) _apply(false);
  }

  /// 全部释放（杀进程/登出等场景）。
  void releaseAll() {
    if (_refs == 0) return;
    _refs = 0;
    _apply(false);
  }

  /// 平台调用集中在一处，便于测试替身与未来的 web 降级。
  ///
  /// 注意：WakelockPlus 的方法返回 Future，平台通道异常是**异步**抛出的
  /// （MissingPluginException 之类），同步 try/catch 抓不到——必须显式
  /// 消费掉 future 的错误，否则它会变成 unhandled async error 让测试红/污染
  /// 全局错误处理。
  void _apply(bool on) {
    final f = on ? WakelockPlus.enable() : WakelockPlus.disable();
    // ignore: unawaited_futures
    f.then((_) {}, onError: (Object _) {});
  }
}
