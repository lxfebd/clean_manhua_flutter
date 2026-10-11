import 'bookshelf_store.dart';
import 'local_store.dart';
import 'novel_shelf_store.dart';
import '../sources/dsl/custom_source_store.dart';
import '../sources/source_config.dart';

/// 备份恢复统一入口：本地导入（settings）与 WebDAV 下载恢复共用。
///
/// 三步顺序固定：
/// 1. 两个书架 Store 还原（含分类引用，必须先于 LocalStore 全量恢复之外
///    单独灌入——字段归属见 [LocalStore.restoreBackup] 注释）；
/// 2. [LocalStore.restoreBackup] 全量恢复（无键字段自动跳过）；
/// 3. 失效常驻缓存 + 重建自定义源插件——恢复的数据含源配置/自定义源/
///    插件启用态，走各自常驻内存缓存与注册表：不刷新则 ① 恢复进来的源
///    配置/自定义源不生效（读走旧缓存）；② 用户随后任意保存会把旧缓存
///    全量回写，静默覆盖刚恢复的数据。
///
/// 步骤 3 曾只在 WebDAV 路径实现、本地导入路径漏配（两处逐行复制产生
/// 漂移），故收口到本入口统一守护。
class BackupRestore {
  const BackupRestore._();

  /// 应用一份备份数据，返回实际恢复的 LocalStore 文件个数。
  static Future<int> apply(Map<String, dynamic> data) async {
    if (data['bookshelf'] is Map) {
      BookshelfStore.importData(data['bookshelf'] as Map<String, dynamic>);
    }
    if (data['novel_shelf'] is Map) {
      NovelShelfStore.importData(data['novel_shelf'] as Map<String, dynamic>);
    }
    final count = await LocalStore.restoreBackup(data);
    SourceConfigStore.invalidateCache();
    await CustomSourceStore.restorePlugins(replaceExisting: true);
    return count;
  }
}
