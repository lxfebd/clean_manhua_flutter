/// 播放器墙钟速率判定（纯函数，可单测）。
///
/// 背景：mpv 的 `speed` 属性在显示时钟估算错误时恒读回 1.0（自认 1x），
/// 只有 time-pos 推进 / 墙钟流逝（诊断循环日志里的 `wrate=`）能看出实际
/// 倍速。诊断循环每 2 秒采样一次 wrate，这里判定是否需要强制切 audio 同步
/// 防倍速——这是 edisp 区间探测（_applySync）之外的兜底防线：edisp 即便落在
/// 30~250Hz 区间内也可能错（用户机器实测过 419~525Hz 的垃圾值）。
library;

/// 单拍 wrate 是否构成「漂移」：明显加速（> 1 + tolerance）且排除用户主动
/// 调速（speed 属性 != 1.0）、暂停/缓冲（wrate≈0 是减速不是倍速，且暂停时
/// time-pos 不推进）。
bool wrateIsDrifted(
  double wrate, {
  double speed = 1.0,
  bool paused = false,
  bool buffering = false,
  double tolerance = 0.15,
}) {
  // 用户自己开了 1.5x/2x 时 wrate 天然 >1，不是时钟漂移，不拦。
  if (speed > 1.05) return false;
  if (paused || buffering) return false;
  return wrate > 1.0 + tolerance;
}

/// 连拍计数：本拍漂移则 +1（钳到 [required]），否则清零。
/// 返回「达到 required 后继续钳住」的值，调用方用 `>= required` 判定触发。
int accumulateDrift(int current, bool driftedThisSample, {required int required}) {
  if (!driftedThisSample) return 0;
  final next = current + 1;
  return next >= required ? required : next;
}

/// wrate 是否已回到正常区间（用于降级后的观测确认：降到 audio 同步后
/// 确认时钟真的稳了再提示，避免提示了个寂寞）。
bool wrateRecovered(double wrate, {double lo = 0.9, double hi = 1.1}) =>
    wrate >= lo && wrate <= hi;
