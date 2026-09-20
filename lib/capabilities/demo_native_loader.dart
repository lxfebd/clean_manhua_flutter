library;

export 'demo_native_loader_io.dart'
    if (dart.library.js_interop) 'demo_native_loader_web.dart';
