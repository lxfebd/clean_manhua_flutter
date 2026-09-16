// shader 版本化回归测试：老用户磁盘上的旧版 shader（如 WHEN 阈值 1.200）
// 不会被 existsSync 误判为「已就绪」，必须靠 `.version` 标记强制重写。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xingmanxia/utils/anime4k.dart';

/// mock rootBundle：把 anime4k 资产替换为带 BOM 的测试内容，
/// 验证「版本不匹配 → 重写 + 剥 BOM + 落盘版本号」的完整链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  final mockAssets = <String, List<int>>{
    // 首 3 字节是 UTF-8 BOM，正文含新版 WHEN 阈值 1.000
    'assets/anime4k/Anime4K_Restore_CNN_S.glsl': [
      0xEF, 0xBB, 0xBF, ...utf8.encode('//!WHEN OUTPUT.w MAIN.w / 1.000 > *'),
    ],
    'assets/anime4k/Anime4K_Upscale_CNN_x2_S.glsl': [
      0xEF, 0xBB, 0xBF, ...utf8.encode('//!WHEN OUTPUT.w MAIN.w / 1.000 > *'),
    ],
    // Restore_M（「均衡/极致」档用）
    'assets/anime4k/Anime4K_Restore_CNN_M.glsl': [
      0xEF, 0xBB, 0xBF, ...utf8.encode('//!WHEN OUTPUT.w MAIN.w / 1.000 > *'),
    ],
    'assets/anime4k/Anime4K_Upscale_CNN_x2_M.glsl': [
      0xEF, 0xBB, 0xBF, ...utf8.encode('//!WHEN OUTPUT.w MAIN.w / 1.000 > *'),
    ],
    // Restore_VL（「极致」档用）
    'assets/anime4k/Anime4K_Restore_CNN_VL.glsl': [
      0xEF, 0xBB, 0xBF, ...utf8.encode('//!WHEN OUTPUT.w MAIN.w / 1.000 > *'),
    ],
    'assets/anime4k/Anime4K_Upscale_CNN_x2_VL.glsl': [
      0xEF, 0xBB, 0xBF, ...utf8.encode('//!WHEN OUTPUT.w MAIN.w / 1.000 > *'),
    ],
  };

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('xm_shader_ver_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return tmp.path;
        }
        return null;
      },
    );
    // mock rootBundle：PlatformAssetBundle.load 走**裸字节通道**
    // `messenger.send('flutter/assets', ByteData(key的UTF-8字节))`，返回值
    // **直接就是 asset 字节**（不解析 envelope）。必须用 setMockMessageHandler
    // 而非 setMockMethodCallHandler：后者会用 StandardMethodCodec 把裸字节
    // 当方法消息解析（首字节是 key 的字符码，不是合法类型标记）
    // → FormatException: Message corrupted。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'flutter/assets',
      (ByteData? message) {
        final key = utf8.decode(message!.buffer.asUint8List(
            message.offsetInBytes, message.lengthInBytes));
        final data = mockAssets[key];
        if (data == null) return null;
        return SynchronousFuture<ByteData>(
            ByteData.sublistView(Uint8List.fromList(data)));
      },
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  String shaderPath() => '${tmp.path}/anime4k';

  void writeOldVersionFile(String name, String content) {
    final dir = Directory(shaderPath());
    dir.createSync(recursive: true);
    File('${shaderPath()}/$name').writeAsStringSync(content, flush: true);
  }

  void writeVersionMarker(String v) {
    final dir = Directory(shaderPath());
    dir.createSync(recursive: true);
    File('${shaderPath()}/.version').writeAsStringSync(v, flush: true);
  }

  group('Anime4KManager.ensureShaders 版本化重写', () {
    test('无 .version（老用户）→ 强制重写全部 shader 且剥 BOM', () async {
      Anime4KManager.resetShadersReadyForTest();
      // 模拟老用户磁盘：旧版 WHEN 1.200 + 无版本标记
      writeOldVersionFile(
          'Anime4K_Upscale_CNN_x2_S.glsl', '//!WHEN OUTPUT.w MAIN.w / 1.200 > *');
      expect(Directory(shaderPath()).existsSync(), isTrue);

      await Anime4KManager.ensureShaders();

      // 重写后磁盘内容应来自 assets（含 BOM 被剥离 → 首字节是 '/'）
      final written =
          File('${shaderPath()}/Anime4K_Upscale_CNN_x2_S.glsl').readAsBytesSync();
      expect(written[0], 0x2F, reason: 'BOM 应被剥离，首个字节是 ASCII /');
      final text = utf8.decode(written);
      expect(text, contains('1.000'), reason: 'WHEN 阈值应更新为新版');
      // 版本标记落盘
      expect(File('${shaderPath()}/.version').readAsStringSync(), isNotEmpty);
    });

    test('版本一致且文件齐全 → 不重写（幂等，无 IO 抖动）', () async {
      writeVersionMarker('2');
      // 预置「已是新版」的文件
      for (final preset in Anime4KManager.levels) {
        for (final name in preset.shaders) {
          writeOldVersionFile(name, '//!WHEN OUTPUT.w MAIN.w / 1.000 > *');
        }
      }
      final before =
          File('${shaderPath()}/Anime4K_Restore_CNN_S.glsl').readAsStringSync();

      await Anime4KManager.ensureShaders();

      final after =
          File('${shaderPath()}/Anime4K_Restore_CNN_S.glsl').readAsStringSync();
      expect(after, before, reason: '版本一致时不应重写已有文件');
      expect(File('${shaderPath()}/.version').readAsStringSync(), '2');
    });
  });
}
