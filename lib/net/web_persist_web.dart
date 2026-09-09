import 'package:web/web.dart' as web;

/// web 端实现：localStorage（同步 API，浏览器持久化）。
/// key 统一加前缀避免与同源其他站点数据冲突。
class WebPersist {
  static const String _prefix = 'xm_';

  static String? read(String key) =>
      web.window.localStorage.getItem('$_prefix$key');

  static void write(String key, String value) {
    web.window.localStorage.setItem('$_prefix$key', value);
  }

  static void remove(String key) {
    web.window.localStorage.removeItem('$_prefix$key');
  }
}