import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'error_logger.dart';
import 'local_store.dart';
import 'update_checker.dart';
import 'http_client.dart';

/// 后台更新下载状态。
class UpdateDownloadState {
  final int received;
  final int total;
  final String speed;
  final bool done;
  final String? error;
  const UpdateDownloadState({
    this.received = 0,
    this.total = 0,
    this.speed = '',
    this.done = false,
    this.error,
  });

  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
}

/// 全局更新下载管理器（单例）。下载脱离 Dialog 生命周期，
/// 用户返回界面或退出 App 时下载仍在后台进行，通知栏显示进度。
///
/// GitHub 下载加速：自动尝试多个镜像源，选可用的。
class UpdateDownloadManager {
  UpdateDownloadManager._();
  static final UpdateDownloadManager instance = UpdateDownloadManager._();

  static const _channel = MethodChannel('xingmanxia/update_notification');

  final _stateCtrl = StreamController<UpdateDownloadState>.broadcast();
  Stream<UpdateDownloadState> get stateStream => _stateCtrl.stream;
  UpdateDownloadState _state = const UpdateDownloadState();
  UpdateDownloadState get state => _state;

  /// 本次下载完成后是否会真正自动触发安装（与 [_downloadWithMirrors] 的安装
  /// 分支判定保持一致）：Android 恒自动（系统安装器）；Windows 仅当拿到 exe
  /// 安装包时自动（NSIS 静默安装），zip 不自动；macOS 走手动挂载 dmg。
  /// 供弹窗文案使用，避免「下载 zip 却提示即将自动安装」的误导。
  bool get willAutoInstall {
    if (Platform.isAndroid) return true;
    if (Platform.isWindows) return _fileName.endsWith('.exe');
    return false;
  }

  bool _running = false;
  bool _cancelled = false;
  String? _downloadedPath;
  String? _dlPath;
  String _fileName = 'xingmanxia_update.apk';
  int _totalSize = 0;

  /// 更新包下载的镜像候选与更新检查共用 [UpdateChecker.githubMirrors]
  /// （同一份事实，避免两处维护分叉：检查用镜像抓 release 页、下载用镜像
  /// 拉附件，孰优孰劣一致）。镜像拼装与双层前缀防御见 [mirrorCandidates]。

  /// 慢速阈值：5 秒内平均速度低于此值则放弃当前镜像换下一个。
  static const int _minSpeedBytesPerSec = 200 * 1024; // 200 KB/s
  static const Duration _speedCheckDuration = Duration(seconds: 5);

  /// 启动后台下载（去重，已在跑就直接返回）。
  /// [fileName] 为附件文件名（含后缀，用于桌面端手动安装识别）。
  Future<void> start(String apkUrl, {String? fileName}) async {
    if (_running) return;
    _running = true;
    _cancelled = false;
    _downloadedPath = null;
    _totalSize = 0;
    // 附件名缺失时兜底：后缀从下载 URL 推断（.exe/.zip/.apk…），
    // 保证 Windows 下即便没拿到 assetName，exe 链接也能触发自动安装。
    _fileName =
        (fileName != null && fileName.isNotEmpty)
            ? fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
            : fallbackFileName(apkUrl, UpdateChecker.currentPlatformKey());
    // 更新包存放到应用的规范下载目录（LocalStore.downloadDir，
    // 即 .../files/data/downloads/），与漫画下载同一目录、统一管理；
    // 应用私有目录可被 FileProvider 的 files-path 正常分享用于安装。
    final dl = await LocalStore.downloadDir();
    await dl.create(recursive: true);
    // 按 release tag 分目录隔离不同版本：断点续传的残留文件与当前版本严格
    // 一一对应，杜绝「上一版半截包撞上新版本长度拼出损坏安装包」。
    final tag = updateTagFromUrl(apkUrl);
    final dir = tag == null ? dl : Directory('${dl.path}/update/$tag');
    await dir.create(recursive: true);
    _dlPath = '${dir.path}/$_fileName';
    _notify('更新下载', '开始下载…', 0, 0, false);
    _downloadWithMirrors(apkUrl);
  }

  /// 取消下载。
  void cancel() {
    _cancelled = true;
    _running = false;
    _state = const UpdateDownloadState(error: '已取消');
    _stateCtrl.add(_state);
    _cancelNotif();
    final p = _dlPath;
    if (p != null) {
      final f = File(p);
      // 下载循环可能仍在写同一文件（Windows 上文件被占用/权限拒绝），
      // 删除失败仅记日志，不向上抛（cancel 是用户主动触发的收尾操作）。
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        ErrorLogger.instance.warn('更新下载取消清理失败: $e');
      }
    }
  }

  /// 本轮下载各镜像失败原因摘要（中文前缀 + 状态码），按尝试顺序追加；
  /// 全部失败时取最后一条上屏，帮助用户判断是网络/镜像问题还是直连问题。
  final List<String> _mirrorFailures = [];

  Future<void> _downloadWithMirrors(String originalUrl) async {
    _mirrorFailures.clear();
    for (final c in mirrorCandidates(originalUrl)) {
      if (_cancelled) break;
      try {
        final path = await _downloadOne(c.url, label: c.label);
        if (_cancelled) return;
        _downloadedPath = path;
        _state = UpdateDownloadState(
          received: _totalSize > 0 ? _totalSize : await File(path).length(),
          total: _totalSize > 0 ? _totalSize : await File(path).length(),
          done: true,
        );
        _stateCtrl.add(_state);
        _notifyDone();
        // Android 拉起系统安装器；Windows 有 NSIS 静默安装器（exe 附件）
        // 则直接覆盖安装并自动重启到新版；macOS 无安装器，仅提示手动挂载 dmg。
        if (Platform.isAndroid) {
          await _triggerInstall();
        } else if (Platform.isWindows && _fileName.endsWith('.exe')) {
          _triggerWindowsInstall();
        }
        _running = false;
        return;
      } catch (e) {
        ErrorLogger.instance.warn(
          'update dl mirror ${c.label} failed: ${e is Exception ? e : e.toString()}',
        );
        _mirrorFailures.add(_mirrorFailSummary(e));
      }
    }
    if (_cancelled) return;
    // 把最后一条镜像的具体失败原因带上屏：用户需要知道是「直连超时」
    // 还是「镜像证书失败」才能决定是否换网络/换时间重试。原始异常本体
    // （可能带 URL/长堆栈）不进 UI，只取中文前缀与关键状态码。
    final lastErr = _mirrorFailures.isNotEmpty
        ? _mirrorFailures.last
        : '未知错误';
    _state = UpdateDownloadState(error: '全部镜像下载失败（$lastErr），请稍后重试');
    _stateCtrl.add(_state);
    _notifyError();
    _running = false;
  }

  /// 下载单个 URL（带 Range 断点续传 + 速度计算）。
  /// 使用固定路径文件，切换镜像/重试时可续传。
  Future<String> _downloadOne(String url, {required String label}) async {
    final path = _dlPath;
    if (path == null) throw Exception('下载路径未初始化');
    final file = File(path);

    var received = 0;
    if (file.existsSync()) {
      received = await file.length();
    }

    // 复用统一连接策略：代理 / 优选 IP / 信任自签证书
    final client = Net.clientForRequest(Uri.parse(url).host);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      req.headers.set('User-Agent', 'xingmanxia-android');
      if (received > 0) req.headers.set('Range', 'bytes=$received-');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 && res.statusCode != 206) {
        throw Exception('HTTP ${res.statusCode} ($label)');
      }

      // 服务器不支持 Range（200 且 received>0）：清空文件从头下，避免追加损坏
      if (res.statusCode == 200 && received > 0) {
        received = 0;
        if (file.existsSync()) await file.delete();
      }

      // 206 时校验 Content-Range 起始字节与本地长度一致，防止同路径下残留
      // 文件内容与服务器当前内容错位（跨版本/缓存的半截包）导致拼接损坏。
      // 不一致则作废本地文件并中止本次尝试：响应体是从 crStart 开始的
      // 中段字节，直接追加会让新文件以错误偏移开头，必须让下一个镜像从头下。
      final cr = res.headers.value('content-range');
      final crStart = cr != null ? _contentRangeStart(cr) : -1;
      if (res.statusCode == 206 && crStart >= 0 && received > 0 && crStart != received) {
        if (file.existsSync()) await file.delete();
        throw Exception('续传位置与本地文件不一致，重新下载 ($label)');
      }

      // 总大小只设一次（第一个返回 content-length 的镜像），后续镜像不覆盖
      final respTotal =
          res.contentLength > 0
              ? received + res.contentLength
              : (cr != null
                  ? _contentRangeTotal(cr)
                  : 0);
      if (respTotal > 0 && _totalSize == 0) {
        _totalSize = respTotal;
      }
      final total = _totalSize > 0 ? _totalSize : respTotal;

      final sink = file.openWrite(mode: FileMode.append);
      // 本次镜像会话起点：续传时 received 含已下字节，速度必须用增量算
      // （旧版 avgSpeed = received / 耗时 在续传时恒虚高，慢速换镜像失效）。
      final sessionStart = received;
      var lastTick = DateTime.now();
      var lastBytes = received;
      final startTime = DateTime.now();
      var speedCheckPassed = false;
      // 停滞守护（与视频下载同一原语）：相邻数据块间隔超 45s 视为悬挂，
      // 抛超时让外层切下一个镜像——避免「头已返回但 body 悬挂」的下载
      // 永远卡住（Range 续传 + 镜像回退保证悬挂后能续上）。
      await for (final chunk in _stallGuarded(res, stall: const Duration(seconds: 45))) {
        if (_cancelled) {
          await sink.close();
          throw Exception('已取消');
        }
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        final dt = now.difference(lastTick).inMilliseconds;
        if (dt >= 500) {
          final speedBytes = (received - lastBytes) / (dt / 1000);
          lastBytes = received;
          lastTick = now;
          // 慢速检测：前 10 秒内平均速度 < 50KB/s 则放弃当前镜像换下一个。
          // 不删除已下载文件，下一个镜像用 Range 续传。
          // 用会话增量（received - sessionStart）算，续传时不被历史字节虚高。
          if (!speedCheckPassed &&
              now.difference(startTime).inMilliseconds >=
                  _speedCheckDuration.inMilliseconds) {
            final elapsed = now.difference(startTime).inMilliseconds;
            final avgSpeed =
                elapsed <= 0 ? 0.0 : (received - sessionStart) / elapsed * 1000;
            if (avgSpeed < _minSpeedBytesPerSec) {
              await sink.close();
              throw Exception('速度太慢 ${_fmtSpeed(avgSpeed)} ($label)');
            }
            speedCheckPassed = true;
          }
          final speedStr = _fmtSpeed(speedBytes);
          _state = UpdateDownloadState(
            received: received,
            total: total,
            speed: speedStr,
          );
          _stateCtrl.add(_state);
          _notify('更新下载', '$label $speedStr', received, total, false);
        }
      }
      await sink.close();
      // 完整度对账：已知目标大小时，收到的字节数必须啃够；否则说明
      // 服务器提前断流/长度变化，不能拿残缺包去安装。
      if (total > 0 && received != total) {
        throw Exception('下载不完整 $received/$total ($label)');
      }
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  /// 解析 Content-Range: `bytes=<start>-<end>/<total>` 的起始字节，解析失败返回 -1。
  static int _contentRangeStart(String cr) => contentRangeStart(cr);

  /// 解析 Content-Range 的完整总大小（斜杠后的值），解析失败返回 0。
  static int _contentRangeTotal(String cr) => contentRangeTotal(cr);

  /// 带停滞超时的分块流：相邻两个块间隔超过 [stall] 即抛超时
  /// （与 [VideoDownloadManager] 同一原语，避免悬挂流永远卡住）。
  Stream<List<int>> _stallGuarded(HttpClientResponse resp,
      {Duration stall = const Duration(seconds: 20)}) async* {
    await for (final chunk in resp.timeout(stall)) {
      yield chunk;
    }
  }

  /// 单个镜像失败 → 可上屏的短摘要（≤80 字符）：截异常首行、剥掉
  /// 长 URL（`https://...` 整段替换为省略号），保留 HTTP 状态码/超时等关键信息。
  static String _mirrorFailSummary(Object e) {
    var s = e.toString().split('\n').first.trim();
    s = s.replaceAll(RegExp(r'https?://\S+'), '…');
    if (s.length > 80) s = '${s.substring(0, 80)}…';
    return s;
  }

  /// 通过 MethodChannel 调用原生通知（进度条）。
  /// 进度通知节流：更新下载每秒可达多次分块，通知栏 500ms 刷新一次太频繁
  /// （闪烁/卡顿），进度类通知（done=false）至少间隔 [_notifyMinInterval]；
  /// 首次与完成通知不节流。
  static const Duration _notifyMinInterval = Duration(seconds: 2);
  DateTime? _lastNotifyAt;
  Future<void> _notify(
    String title,
    String text,
    int received,
    int total,
    bool done,
  ) async {
    if (!done) {
      final now = DateTime.now();
      final last = _lastNotifyAt;
      if (last != null && now.difference(last) < _notifyMinInterval) return;
      _lastNotifyAt = now;
    }
    try {
      await _channel.invokeMethod('showProgress', {
        'title': title,
        'text': text,
        'received': received,
        'total': total,
        'done': done,
      });
    } catch (_) {}
  }

  Future<void> _notifyDone() async {
    try {
      await _channel.invokeMethod('showDone', {
        'title': '更新下载完成',
        'text': '点击安装新版本',
        'path': _downloadedPath ?? '',
      });
    } catch (_) {}
  }

  Future<void> _notifyError() async {
    try {
      await _channel.invokeMethod('showError', {
        'title': '更新下载失败',
        'text': '所有镜像均失败，请稍后重试或手动下载',
      });
    } catch (e) {
      ErrorLogger.instance.warn('更新下载失败通知发送失败: $e');
    }
  }

  Future<void> _cancelNotif() async {
    try {
      await _channel.invokeMethod('cancel');
    } catch (_) {}
  }

  Future<void> _triggerInstall() async {
    final path = _downloadedPath;
    if (path == null) return;
    try {
      await UpdateChecker.installApk(path);
    } catch (e) {
      ErrorLogger.instance.warn('apk install failed: $e');
      _state = UpdateDownloadState(error: '自动安装失败，可到文件管理器手动安装');
      _stateCtrl.add(_state);
      _notifyInstall(path);
      _running = false;
    }
  }

  /// 发送可点击安装的通知（自动安装失败时备用）。
  Future<void> _notifyInstall(String path) async {
    try {
      await _channel.invokeMethod('showInstall', {'path': path});
    } catch (e) {
      ErrorLogger.instance.warn('更新安装引导通知发送失败: $e');
    }
  }

  /// Windows NSIS 静默自动升级：启动安装器 → 等它起来 → 退出自身 → 安装器接管。
  ///
  /// NSIS 参数约定：/S 静默模式，/D= 指定安装目录且必须是最后一个参数、
  /// 不能带引号。安装目标用当前运行 exe 所在目录 —— 与已安装位置一致，
  /// 升级是原地覆盖；安装器内部先 Sleep 等待进程退出释放文件锁，再 RMDir
  /// 清掉旧文件，File /r 拷入新版，最后 Section -Post 自动 Exec 新版 exe。
  ///
  /// 本方法不 await 安装器/退出流程：启动后立即返回，安装与重启由 NSIS
  /// 脚本在后台完成（这是「全自动」的关键 —— 用户全程无感）。
  void _triggerWindowsInstall() {
    final installer = _downloadedPath;
    if (installer == null) return;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    _triggerWindowsInstallAsync(installer, exeDir);
  }

  Future<void> _triggerWindowsInstallAsync(
    String installer,
    String exeDir,
  ) async {
    try {
      // 直接启动 NSIS 安装器（不经 cmd/shell，避免引号与 /D 末位被改写）。
      // Windows 子进程默认不受父进程退出影响，因此 fire-and-forget，
      // 不 await 退出，安装与重启交给 NSIS 脚本。
      await Process.start(installer, ['/S', '/D=$exeDir']);
    } catch (e) {
      _state = UpdateDownloadState(error: '安装器启动失败：$e（可双击安装包手动安装）');
      _stateCtrl.add(_state);
      _notifyInstall(installer);
      return;
    }
    // 等安装器真正起来（进程探测免初始化），再退出自身；
    // 过早退出会让 cmd 的 start 失去父进程。
    await Future<void>.delayed(const Duration(seconds: 1));
    // 落盘待写队列，避免退出时丢数据。
    await LocalStore.flushAll();
    // 退出自身 → NSIS Sleep 等待文件锁释放 → RMDir/File 覆盖 → Exec 新版。
    await UpdateChecker.quit();
  }

  String _fmtSpeed(double bytesPerSec) {
    if (bytesPerSec >= 1048576) {
      return '${(bytesPerSec / 1048576).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSec >= 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${bytesPerSec.round()} B/s';
  }
}

/// 附件名缺失时的兜底文件名：后缀从下载 URL 推断（.exe/.zip/.apk…），
/// 保证 Windows 下即便没拿到 assetName，exe 链接也能触发自动安装。
@visibleForTesting
String fallbackFileName(String apkUrl, String platformKey) {
  var fallbackExt = 'apk';
  final seg = Uri.tryParse(apkUrl)?.pathSegments.last ?? '';
  final dot = seg.lastIndexOf('.');
  if (dot >= 0 && dot < seg.length - 1 && seg.length - dot - 1 <= 4) {
    final cand = seg.substring(dot + 1);
    if (RegExp(r'^[a-zA-Z0-9]+$').hasMatch(cand)) fallbackExt = cand;
  }
  return 'xingmanxia_update$platformKey.$fallbackExt';
}

/// 从 GitHub releases 下载 URL 提取 release tag（`/releases/download/<tag>/…`），
/// 用于按版本隔离下载目录。非 GitHub 直链（镜像也会保留原路径）或解析失败
/// 返回 null，此时退回到下载根目录。
@visibleForTesting
String? updateTagFromUrl(String url) {
  const marker = '/releases/download/';
  final idx = url.indexOf(marker);
  if (idx < 0) return null;
  final rest = url.substring(idx + marker.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  return rest.substring(0, slash).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}

/// 解析 Content-Range: `bytes=<start>-<end>/<total>` 的起始字节，解析失败返回 -1。
@visibleForTesting
int contentRangeStart(String cr) {
  final m = RegExp(r'bytes\s+(\d+)-').firstMatch(cr);
  if (m == null) return -1;
  return int.tryParse(m.group(1)!) ?? -1;
}

/// 解析 Content-Range 的完整总大小（斜杠后的值），解析失败返回 0。
@visibleForTesting
int contentRangeTotal(String cr) {
  final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
  if (m == null) return 0;
  return int.tryParse(m.group(1)!) ?? 0;
}

/// 镜像下载候选：前缀拼 GitHub 原 URL，空前缀（直连）放链尾兜底。
/// label 与候选严格对应，避免全失败时上屏原因归因错误。
/// 若 [originalUrl] 已带镜像前缀（检查端 HTML 降级可能已镜像化，例如
/// `https://ghproxy.net/https://github.com/...`），不能再拼第二层前缀：
/// 该镜像已证明可达，复用为第一候选，再补剥掉前缀的 GitHub 原 URL 兜底。
@visibleForTesting
List<({String url, String label})> mirrorCandidates(String originalUrl) {
  String? preMirror;
  for (final m in UpdateChecker.githubMirrors) {
    if (m.isNotEmpty && originalUrl.startsWith(m)) {
      preMirror = m;
      break;
    }
  }
  if (preMirror != null) {
    final candidates = <({String url, String label})>[
      (url: originalUrl, label: '镜像(已选)'),
    ];
    final bare = originalUrl.substring(preMirror.length);
    if (bare.isNotEmpty) candidates.add((url: bare, label: '直连'));
    return candidates;
  }
  return [
    for (var i = 0; i < UpdateChecker.githubMirrors.length; i++)
      (
        url: UpdateChecker.githubMirrors[i].isEmpty
            ? originalUrl
            : UpdateChecker.githubMirrors[i] + originalUrl,
        label: UpdateChecker.githubMirrors[i].isEmpty ? '直连' : '镜像$i',
      ),
  ];
}
