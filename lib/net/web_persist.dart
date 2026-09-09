/// Web 持久化抽象：web 端用浏览器 localStorage（同步 API），io 端不可用
/// （调用方只在 kIsWeb 时走这里，io 走真实 File）。
/// 条件导出：web 用 localStorage 实现，io 用抛错占位。
library;

export 'web_persist_stub.dart'
    if (dart.library.js_interop) 'web_persist_web.dart';