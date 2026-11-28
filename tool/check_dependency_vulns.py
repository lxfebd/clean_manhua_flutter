#!/usr/bin/env python3
"""用 OSV 官方 API 校验 pubspec.lock 的依赖漏洞（P2-29）。

用法：
  python3 tool/check_dependency_vulns.py
  python3 tool/check_dependency_vulns.py --out docs/dependency_osv_$(date +%F).json

退出码：0 = 未发现漏洞；1 = 发现漏洞；2 = 查询失败。
只用 Python 标准库，不需要额外安装 osv-scanner。
"""
import argparse
import datetime
import io
import json
import re
import sys
import urllib.request


def locked_packages(path="pubspec.lock"):
    text = io.open(path, encoding="utf-8").read()
    # pubspec.lock 的 packages 段是两级缩进；这里只抓包名与 version，
    # 不引入第三方 YAML 解析器。
    return [
        (m.group(1), m.group(2))
        for m in re.finditer(
            r'^  ([a-zA-Z0-9_]+):\n(?:    .*\n)*?    version: "?([^"\n]+)"?',
            text,
            re.M,
        )
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", help="把完整结果写到 JSON 文件")
    args = ap.parse_args()

    pkgs = locked_packages()
    if not pkgs:
        print("未从 pubspec.lock 解析到依赖", file=sys.stderr)
        return 2
    payload = {
        "queries": [
            {"package": {"name": name, "ecosystem": "Pub"}, "version": version}
            for name, version in pkgs
        ]
    }
    req = urllib.request.Request(
        "https://api.osv.dev/v1/querybatch",
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "xingmanxia-dependency-check",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.load(resp)
    except Exception as exc:  # 网络失败不能伪装成「无漏洞」
        print(f"OSV 查询失败：{exc}", file=sys.stderr)
        return 2

    vulnerable = []
    for (name, version), result in zip(pkgs, data.get("results", [])):
        vulns = result.get("vulns") or []
        if vulns:
            vulnerable.append(
                {
                    "name": name,
                    "version": version,
                    "vulns": [
                        {"id": v["id"], "summary": v.get("summary", "")}
                        for v in vulns
                    ],
                }
            )

    report = {
        "date": datetime.date.today().isoformat(),
        "ecosystem": "Pub",
        "checked": len(pkgs),
        "vulnerable_count": len(vulnerable),
        "vulnerable": vulnerable,
    }
    if args.out:
        io.open(args.out, "w", encoding="utf-8").write(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n"
        )
    print(f"已校验 {len(pkgs)} 个 Pub 依赖，发现 {len(vulnerable)} 个含漏洞包")
    for item in vulnerable:
        ids = ", ".join(v["id"] for v in item["vulns"])
        print(f"- {item['name']}@{item['version']}: {ids}")
    return 1 if vulnerable else 0


if __name__ == "__main__":
    sys.exit(main())
