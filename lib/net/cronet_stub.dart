import 'package:http/http.dart' as http;

/// web 等无 dart:io 平台实现：Cronet 是 Android-only，web 上没有；返回 null
/// 表示不可用，调用方会整体回退 dart:io 路径（web 上再回退到浏览器网络栈）。
class CronetHttp {
  static http.BaseClient? defaultCronetEngine() => null;
}