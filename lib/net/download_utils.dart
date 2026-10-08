import 'dart:io';

/// 下载通用原语（P0-1：video_download_manager / update_download_manager 共用）。

/// 带停滞超时的分块流：相邻两个块间隔超过 [stall] 即抛超时，
/// 避免「头已返回但 body 悬挂」的下载永远卡住。
/// （漫画批量图下载走 [Net.getBytesAuto] 自带超时，不需要此原语。）
Stream<List<int>> stallGuarded(
  HttpClientResponse resp, {
  Duration stall = const Duration(seconds: 20),
}) async* {
  await for (final chunk in resp.timeout(stall)) {
    yield chunk;
  }
}
