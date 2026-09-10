import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'colorizer.dart';
import 'colorizer_backend.dart';
import '../net/error_logger.dart';
import '../net/local_store.dart';

/// 漫画上色管理：负责模型文件的检测/加载/卸载、互斥锁保护、超时降级。
///
/// 模型文件不内置（体积大 + 授权不明），由用户放到应用文档目录
/// `colorizer/model.tflite`（或通过 UI 从文件选择器导入）。
/// - 缺模型 / web 平台 / 加载失败 → [isAvailable] false，UI 禁用入口；
/// - [colorize] 全程互斥锁 + 超时（照 image_super_res 模板），
///   失败（超时/模型坏/推理异常）时降级返回原图并记日志，不抛到 UI。
/// - 默认关闭；仅 io 平台 + 存在模型 + RAM≥4GB 时入口可用
///   （低端机隐藏，用户评审要求）。
class ColorizerManager {
  ColorizerManager._();
  static final ColorizerManager instance = ColorizerManager._();

  static const _modelDir = 'colorizer';
  static const _modelFile = 'model.tflite';

  /// 推理互斥锁：同刻只跑一个推理（模型非线程安全 + 控内存峰值）。
  Completer<void>? _mutex;
  ColorizerBackend? _backend;
  bool _available = false;
  String? _modelPath;
  bool _enableChecked = false;
  bool _enable = false;

  /// 推理最坏耗时（compute 超时）。
  static const Duration _computeTimeout = Duration(minutes: 2);
  /// 锁等待超时：必须 > [_computeTimeout]（照超分模板防锁对象覆盖错配）。
  static const Duration _acquireTimeout = Duration(minutes: 2, seconds: 30);

  /// 是否可用（模型已加载且引擎就绪）。
  bool get isAvailable => _available;

  /// 当前已加载模型路径（用于 UI 显示）。
  String? get modelPath => _modelPath;

  /// 是否启用（设置项；默认关）。
  bool get enabled => _enable;
  Future<void> setEnabled(bool on) async {
    _enable = on;
    await LocalStore.writeJson('colorizer_enabled', on);
  }

  /// 启动时恢复开关状态（main 调用一次）。
  Future<void> restore() async {
    try {
      final j = await LocalStore.readJson('colorizer_enabled');
      _enable = j is bool ? j : false;
    } catch (_) {
      _enable = false;
    }
  }

  /// 探测模型文件是否存在（懒调用；存在则 load，失败降级为不可用）。
  /// 同时恢复开关状态（UI 可能先于设置页触发，如阅读器 initState）。
  Future<void> ensureLoaded() async {
    if (_enableChecked) return;
    _enableChecked = true;
    await restore();
    if (kIsWeb) {
      // web 条件导出即 stub：createColorizerBackend 返回永远不可用的空实现。
      _backend ??= createColorizerBackend();
      _available = false;
      return;
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$_modelDir/$_modelFile');
      if (!f.existsSync()) {
        _available = false;
        return;
      }
      _backend ??= createColorizerBackend();
      _backend!.load(f.path);
      await _backend!.loadAsync();
      _modelPath = f.path;
      _available = _backend!.isAvailable;
    } catch (e) {
      ErrorLogger.instance.warn('Colorizer 模型加载失败: $e');
      _available = false;
    }
  }

  /// 从用户选择的文件导入模型（复制到应用文档目录）。
  Future<bool> importModel(String sourcePath) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final d = Directory('${dir.path}/$_modelDir');
      if (!d.existsSync()) d.createSync(recursive: true);
      final target = File('${d.path}/$_modelFile');
      File(sourcePath).copySync(target.path);
      _enableChecked = false;
      await ensureLoaded();
      return _available;
    } catch (e) {
      ErrorLogger.instance.warn('Colorizer 模型导入失败: $e');
      _available = false;
      return false;
    }
  }

  /// 卸载模型（释放内存）。
  Future<void> unload() async {
    _backend?.dispose();
    _backend = null;
    _available = false;
    _modelPath = null;
    _enableChecked = false;
  }

  /// 对单张图执行上色：入参为解码后的 RGB 像素（长度 w*h*3，无 alpha）。
  /// 返回同尺寸 RGB 像素（长度 w*h*3）。失败/超时/未加载 → 返回 null
  /// （调用方降级原图）。
  /// 注意：输入必须是 RGB（3 字节/像素），RGBA 需先由调用方剥离 alpha。
  Future<Uint8List?> colorize(Uint8List rgba, int w, int h) async {
    if (!_available || _backend == null) return null;
    final m = _mutex;
    if (m != null && !m.isCompleted) {
      // 已有推理在跑：等待（超时保护，防止持锁方异常导致永等）。
      var timedOut = false;
      await m.future.timeout(_acquireTimeout, onTimeout: () {
        timedOut = true;
      });
      if (timedOut) {
        ErrorLogger.instance.warn('Colorizer 等待推理锁超时，跳过本次');
        return null;
      }
    }
    final mutex = _mutex = Completer<void>();
    try {
      // 推理本体放独立 async 包一层，超时由调用方（图片管线）兜底降级。
      return await _timedInfer(rgba, w, h);
    } finally {
      mutex.complete();
      if (identical(_mutex, mutex)) _mutex = null;
    }
  }

  Future<Uint8List?> _timedInfer(Uint8List rgba, int w, int h) async {
    try {
      return await Future<Uint8List?>.delayed(
        Duration.zero,
        () => _backend!.infer(rgba, w, h),
      ).timeout(_computeTimeout, onTimeout: () {
        ErrorLogger.instance.warn('Colorizer 推理超时，降级原图');
        return null;
      });
    } catch (e) {
      ErrorLogger.instance.warn('Colorizer 推理失败: $e');
      return null;
    }
  }

  /// 低端机（RAM < 4GB）隐藏入口（用户评审要求）。
  static Future<bool> isLowEndDevice() async {
    try {
      final sys = await _totalRamBytes();
      return sys != null && sys < 4 * 1024 * 1024 * 1024;
    } catch (_) {
      return false;
    }
  }

  static Future<int?> _totalRamBytes() async {
    // io 平台：读取 /proc/meminfo（Android/Linux）或 sysctl（macOS/Windows）。
    if (kIsWeb) return null;
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final f = File('/proc/meminfo');
        if (f.existsSync()) {
          for (final line in f.readAsLinesSync()) {
            if (line.startsWith('MemTotal:')) {
              final kb = int.tryParse(
                  line.replaceAll(RegExp(r'[^0-9]'), ''));
              if (kb != null) return kb * 1024;
            }
          }
        }
      } else if (Platform.isMacOS) {
        final r = await Process.run('sysctl', ['hw.memsize']);
        if (r.exitCode == 0) {
          return int.tryParse(r.stdout.toString().trim().split(' ').last);
        }
      }
    } catch (_) {}
    return null;
  }
}