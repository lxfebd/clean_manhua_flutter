# 依赖漏洞状态（P2-29）

## 2026-11-28 实测

使用 **OSV 官方 API**（`https://api.osv.dev/v1/querybatch`，ecosystem=`Pub`）
按 `pubspec.lock` 中的**实际锁定版本**逐一比对：

- 校验依赖数：**132**
- 含已知漏洞的包：**0**
- 原始结果：`docs/dependency_osv_2026-11-28.json`

这是「已经运行过比对」的证据，不是凭印象说「应该没问题」。

## 复跑方式

```bash
python3 tool/check_dependency_vulns.py --out docs/dependency_osv_$(date +%F).json
```

- 退出码 `0`：未发现漏洞
- 退出码 `1`：发现漏洞（会列出包名与 OSV ID）
- 退出码 `2`：查询失败——**网络失败不会被当成「无漏洞」**

脚本只用 Python 标准库，不需要安装额外工具。

## 边界与后续

- OSV 结果只代表**查询当下**的公告库状态；新公告出现后需要重新跑。
- 本次只覆盖 Pub 依赖。**Gradle / Kotlin、Windows 原生库、NSIS** 不在这次
  Pub 查询范围内；NSIS 已有独立的 SHA-256 校验（见 `.github/workflows/build.yml`）。
- 建议每次升级 `pubspec.lock` 后复跑，并把新的 JSON 结果一并提交。
