/// 漫画上色后端极简接口：io 端真 TFLite 推理，web 端不可用桩。
/// 具体实现按平台条件导出，调用方只依赖统一的 [ColorizerBackend] 类型。
library;

export 'colorizer_io.dart'
    if (dart.library.js_interop) 'colorizer_stub.dart';