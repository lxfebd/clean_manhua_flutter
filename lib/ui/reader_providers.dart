import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/local_store.dart';
import 'reader_mode_geometry.dart';

/// 阅读模式全局状态（Riverpod 渐进阶段5：以 provider 包住持久化偏好）。
///
/// [ReaderMode] 由 LocalStore 持久化（0=纵向滚动，1=单页横向，2=双页并排）。
/// 阅读器与设置页共用：任一页切换模式，另一页下次进入读到同一偏好；
/// 页面内部态（_doublePage/_userModeLocked 等派生交互标记）仍留页面。
class ReaderModeNotifier extends Notifier<ReaderMode> {
  /// 首帧默认值：单页横向（与 LocalStore.readerMode 的缺省一致）。
  @override
  ReaderMode build() => ReaderMode.single;

  /// 从持久化恢复（幂等，应用/页面 init 时调用一次）：
  /// 已 resume 过则直接返回当前值不重复读盘。
  Future<ReaderMode> resume() async {
    if (_resumed) return state;
    _resumed = true;
    state = ReaderMode.fromValue(await LocalStore.readerMode());
    return state;
  }

  bool _resumed = false;

  /// 切换阅读模式：写回持久化并更新全局状态。
  /// 相等短路避免无谓的写盘与重建；调用方（阅读器）在校验后自行
  /// 处理页面布局迁移（_switchReaderMode 按当前页锚点换算视图）。
  Future<void> setMode(ReaderMode next) async {
    if (next == state) return;
    state = next;
    await LocalStore.setReaderMode(next.value);
  }
}

/// 阅读模式全局 provider（懒加载：build 返回默认值，首次 resume 读盘）。
final readerModeProvider =
    NotifierProvider<ReaderModeNotifier, ReaderMode>(ReaderModeNotifier.new);