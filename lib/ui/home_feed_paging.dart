import 'package:flutter/widgets.dart';

import '../models/comic_item.dart';

/// 首页系（漫画/动漫/小说首页）共享的分页判定与去重逻辑。
///
/// 三页各有一份逐字同构的 `_dedup`（按 id 去重）/ `_onScroll`（触底判定）
/// / `_maybeAutoLoadMore`（内容不满一屏自动续页，额度 3 次），
/// 收拢为纯函数 + 一个持有续页额度的小对象。
class HomeFeedPaging {
  HomeFeedPaging._();

  /// 滚动距底部多少像素内视为触底。
  static const double bottomThreshold = 400;

  /// 源站分页偶发返回重复条目（同一作品跨页重复）：按 id 去重后渲染。
  /// 同时避免网格内多个同 tag Hero 触发「multiple heroes」崩溃。
  static List<ComicItem> dedupById(List<ComicItem> items) {
    final seen = <String>{};
    return [for (final it in items) if (it.id.isNotEmpty && seen.add(it.id)) it];
  }

  /// 滚动是否进入触底加载区（距底部 [bottomThreshold] 内）。
  static bool nearBottom(ScrollController scrollCtrl) {
    if (!scrollCtrl.hasClients) return false;
    final pos = scrollCtrl.position;
    return pos.pixels > pos.maxScrollExtent - bottomThreshold;
  }
}

/// 内容不满一屏时的自动续页（post-frame 判定，最多 [maxAutoLoads] 次）。
///
/// 每个首页持有一个实例；刷新/切源/换搜索关键词时调用 [reset] 重置额度。
/// 额度上限的意义：封面加载慢/失败导致网格高度不足时，避免无限循环狂拉分页
/// 把请求队列打满（每页 20 张图并发加载 + 源站限流会明显卡顿）。
class AutoLoadMore {
  AutoLoadMore({this.maxAutoLoads = 3});

  final int maxAutoLoads;
  int _count = 0;

  /// 额度重置（新一轮列表/新源/搜索提交时调用）。
  void reset() => _count = 0;

  /// 帧后判定：[canLoad] 为真且内容不满一屏时触发 [onLoad]，
  /// 每次消耗一个额度。避免首屏太短时滚动分页不触发导致"很快到底"的错觉。
  void schedule({
    required bool Function() canLoad,
    required ScrollController scrollCtrl,
    required VoidCallback onLoad,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!canLoad()) return;
      if (!scrollCtrl.hasClients) return;
      if (scrollCtrl.position.maxScrollExtent > 0) return;
      if (_count >= maxAutoLoads) return;
      _count++;
      onLoad();
    });
  }
}