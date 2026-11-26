import 'dart:convert';

import '../utils/index_signature.dart';

/// 更新清单（Release 附件签名清单）——更新链的**真实性校验**。
///
/// ## 为什么需要
/// 更新包此前只有「长度/Content-Range 对账」：第三方镜像（ghproxy/ghfast）
/// 返回的任意 exe 只要长度对得上，就会被静默安装（Windows）或交给系统安装器
/// （Android）。长度正确的任意程序 ≠ 作者发布的程序。
///
/// ## 机制
/// 发布时用**发布私钥**给一份 JSON 清单签名（ECDSA P-256 / SHA-256，格式与
/// 市场索引完全一致，见 `lib/utils/index_signature.dart`），清单里写明每个附件
/// 的 `name/size/sha256`，连同版本号、单调递增的 `sequence`、`minApp` 一起
/// 作为 Release 附件 `release-manifest.json` 分发。App 侧：
/// 1. 拿到清单先验签——签名不过一律拒绝（镜像只是不可信传输层）；
/// 2. 用清单里的 sha256/size 校验下载完成的文件，通过才允许安装；
/// 3. `sequence` 单调递增，防旧版清单回滚；`minApp` 防跨版本直更导致契约断裂。
///
/// ## 规范化（签名端与验签端必须完全一致）
/// 签名对象 = 顶层 JSON 去掉 `_sig` 后 `jsonEncode` 的 UTF-8 字节。
/// 签名工具：`dart run tool/sign_update_manifest.dart`（公钥轮换见
/// [kUpdatePublicKeysHex] 注释）。
/// 清单签名所在的顶层字段名（与市场索引同构，签名算法同源）。
const String kUpdateManifestSignatureField = '_sig';

/// 更新清单在 Release 附件里的固定文件名。
const String kUpdateManifestAssetName = 'release-manifest.json';

/// 验签公钥（prime256v1 的 Q 点坐标，格式 "PUBX:PUBY"，各 32 字节 hex）。
///
/// 公开信息，可硬编码。私钥由发布机持有（不进仓库），签名在 CI 里用
/// GitHub Secret `UPDATE_SIGNING_KEY` 注入。轮换：用
/// `dart run tool/sign_update_manifest.dart --genkey --key <新私钥路径>`
/// 生成新对，把新公钥**追加**到这里（旧公钥保留——存量已签清单仍需验过），
/// 下次发布自动改用新私钥。
const List<String> kUpdatePublicKeysHex = [
  '7be30bb6c3b79ade882677109b94161eee2eccb78da8bf1de2f524f497e47c80:'
      '6b7e296b7b3ceb4f81bbebb9e2ac8f2bc69ad089e7c009ac8fde7a036bb1ef71', // 2026-11-21（私钥已丢失，保留仅为兼容当时可能签发过的清单）
  'd03d5200d2449276094f405bdb8a694da41f600c7f235c27d292c52cf95c0945:'
      'fa45008844fc906cf3bd87f098037c1907ebb20a323bbe24ab8c2c0bf026f1b9', // 2026-11-26 起生效（私钥在发布机 ~/.xingmanxia/update_signing_key.json + GitHub Secret）
];

/// 清单可信度分级。与 [IndexSignatureStatus] 同构，但多了
/// [unparsable]（JSON 本身就不是对象/字段缺失）。
enum UpdateManifestStatus {
  /// 签名有效且字段完整，可据以校验下载包。
  valid,

  /// 没有 `_sig` 字段（历史 release 未签清单）。
  missing,

  /// 有签名但验不过，或必需字段缺失/类型错误。
  invalid,

  /// 顶层不是 JSON 对象或无法解析。
  unparsable,
}

/// 清单里的单个附件条目。
class UpdateManifestAsset {
  /// 附件文件名（与 Release 资产名一致，如 `app-release.apk`）。
  final String name;

  /// 平台标识：android / windows / macos（与 [UpdateChecker.currentPlatformKey]
  /// 的取值约定一致，仅作展示与过滤用）。
  final String platform;

  /// 附件字节数。
  final int size;

  /// 附件 SHA-256，小写 hex。
  final String sha256;

  const UpdateManifestAsset({
    required this.name,
    required this.platform,
    required this.size,
    required this.sha256,
  });

  static UpdateManifestAsset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final sha = raw['sha256'];
    final size = raw['size'];
    if (name is! String || name.isEmpty) return null;
    if (sha is! String || sha.isEmpty) return null;
    if (size is! int || size < 0) return null;
    return UpdateManifestAsset(
      name: name,
      platform: (raw['platform'] as String?) ?? '',
      size: size,
      sha256: sha.toLowerCase(),
    );
  }
}

/// 一份已验签（或验签失败）的更新清单。
class UpdateManifest {
  /// 该清单描述的版本号（与 release tag 一致，去 `v` 前缀）。
  final String version;

  /// 单调递增序号：同一版本可重签，但序号小等于已见序号的清单一律拒绝
  /// （防止「换成旧版清单」的回滚攻击）。
  final int sequence;

  /// 最低可升级版本：低于它的老版本不能直接跨到这个版本（缺少中间契约）。
  final String? minApp;

  /// 签发时间（ISO-8601，仅展示与审计，不参与签名外的判断）。
  final String? issuedAt;

  /// 附件条目。
  final List<UpdateManifestAsset> assets;

  final UpdateManifestStatus status;

  const UpdateManifest._({
    required this.version,
    required this.sequence,
    required this.assets,
    required this.status,
    this.minApp,
    this.issuedAt,
  });

  /// 按附件名取条目；没有返回 null。
  UpdateManifestAsset? asset(String name) {
    for (final a in assets) {
      if (a.name == name) return a;
    }
    return null;
  }

  /// 按文件名直接取期望的 sha256（调用方少写一次空判断）。
  String? expectedSha256(String name) => asset(name)?.sha256;

  /// 按文件名直接取期望的字节数。
  int? expectedSize(String name) => asset(name)?.size;

  /// 只做「分类」：不构造对象，供调用方先判断是 missing 还是 invalid
  /// （两者对 UI 的提示不同）。纯函数，不抛异常。
  static UpdateManifestStatus classify(
    String text, {
    List<String> publicKeys = kUpdatePublicKeysHex,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return UpdateManifestStatus.unparsable;
    }
    if (decoded is! Map) return UpdateManifestStatus.unparsable;
    switch (verifyJsonSignature(
      text,
      sigField: kUpdateManifestSignatureField,
      publicKeys: publicKeys,
    )) {
      case IndexSignatureStatus.missing:
        return UpdateManifestStatus.missing;
      case IndexSignatureStatus.invalid:
        return UpdateManifestStatus.invalid;
      case IndexSignatureStatus.valid:
        // 签名过了还要看字段完整性：缺 version/assets 的清单不构成约束力。
        final version = decoded['version'];
        final assets = decoded['assets'];
        if (version is! String || version.isEmpty) {
          return UpdateManifestStatus.invalid;
        }
        if (assets is! List || assets.isEmpty) {
          return UpdateManifestStatus.invalid;
        }
        for (final a in assets) {
          if (UpdateManifestAsset.fromJson(a) == null) {
            return UpdateManifestStatus.invalid;
          }
        }
        return UpdateManifestStatus.valid;
    }
  }

  /// 解析并验签。只有 [UpdateManifestStatus.valid] 才返回对象；
  /// 其余（含 missing/invalid/unparsable）一律返回 null——
  /// **未经签名的清单不产生任何约束力，也绝不允许据此放行安装**。
  static UpdateManifest? tryParse(
    String text, {
    List<String> publicKeys = kUpdatePublicKeysHex,
  }) {
    final st = classify(text, publicKeys: publicKeys);
    if (st != UpdateManifestStatus.valid) return null;
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final seqRaw = decoded['sequence'];
    return UpdateManifest._(
      version: decoded['version'] as String,
      sequence: seqRaw is int ? seqRaw : 0,
      minApp: decoded['minApp'] as String?,
      issuedAt: decoded['issuedAt'] as String?,
      assets: [
        for (final a in decoded['assets'] as List)
          UpdateManifestAsset.fromJson(a)!,
      ],
      status: st,
    );
  }
}
