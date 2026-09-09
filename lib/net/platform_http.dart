/// 平台 HTTP 线协议抽象：io 端保留 dart:io HttpClient 全部特性
/// （代理 / 优选 IP connectionFactory / gzip），web 端走 BrowserClient(fetch)。
/// Net 类的编排逻辑（重试 / Cronet 回退 / 限流 / 优选 IP 轮换）与平台无关，
/// 只在这里切换最后的"线上"实现。
library;

export 'platform_http_io.dart'
    if (dart.library.js_interop) 'platform_http_web.dart';
