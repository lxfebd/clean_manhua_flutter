import 'package:cronet_http/cronet_http.dart' as cronet;

/// io 平台实现：直接透传 cronet_http（Android 原生 Cronet 引擎）。
class CronetHttp {
  static cronet.CronetClient defaultCronetEngine() =>
      cronet.CronetClient.defaultCronetEngine();
}