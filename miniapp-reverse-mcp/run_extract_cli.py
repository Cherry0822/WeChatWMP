#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from miniapp_cdp.extraction import wxapkg
from miniapp_cdp.extraction.extractor import Extractor


def resolve_packages_dir(packages_dir: str | None) -> str:
    if packages_dir:
        path = os.path.abspath(os.path.expanduser(packages_dir))
        if not os.path.isdir(path):
            raise SystemExit(f"packages_dir 不存在: {path}")
        return path

    path = wxapkg.get_default_packages_dir()
    if not path:
        raise SystemExit("未找到默认小程序包目录，请传入 --packages-dir")
    return path


def resolve_output_dir(appid: str, output_dir: str | None) -> str:
    if output_dir:
        path = os.path.abspath(os.path.expanduser(output_dir))
    else:
        path = os.path.abspath(os.path.join("analysis", appid))
    os.makedirs(path, exist_ok=True)
    return path


def group_files(files: list[dict]) -> list[dict]:
    grouped: dict[str, list[dict]] = {}
    for file in files:
        grouped.setdefault(file["appid"], []).append(file)

    result = []
    for appid in sorted(grouped):
        items = grouped[appid]
        items.sort(key=lambda item: item.get("name", ""))
        total_size = sum(item.get("size", 0) for item in items)
        result.append({
            "appid": appid,
            "file_count": len(items),
            "total_size": total_size,
            "files": items,
        })
    result.sort(key=lambda item: item["appid"])
    return result


def cmd_list(args):
    packages_dir = resolve_packages_dir(args.packages_dir)
    files = wxapkg.find_wxapkg_files(packages_dir)
    grouped = group_files(files)
    print(json.dumps(grouped, ensure_ascii=False, indent=2))


def extract_appid(appid: str, packages_dir: str, output_dir: str) -> str:
    files = wxapkg.find_wxapkg_files(packages_dir)
    matched = [item for item in files if item.get("appid") == appid]
    if not matched:
        available = sorted({item.get("appid", "") for item in files if item.get("appid")})
        suffix = f"当前目录可用 appid: {', '.join(available)}" if available else ""
        return f"未找到 appid={appid} 的 wxapkg 文件。{suffix}"

    root = resolve_output_dir(appid, output_dir)
    decompile_dir = os.path.join(root, "decompiled")
    os.makedirs(decompile_dir, exist_ok=True)

    lines = [f"开始解包 appid={appid}，共 {len(matched)} 个文件:"]
    total_files = 0
    for item in matched:
        try:
            extracted = wxapkg.extract_wxapkg(item["path"], decompile_dir, appid)
            total_files += len(extracted)
            lines.append(f"- {item.get('name', '')}: {len(extracted)} 个文件")
        except Exception as exc:
            lines.append(f"- {item.get('name', '')}: 解包失败 {exc}")
    lines.append(f"解包完成，共提取 {total_files} 个文件")
    lines.append(f"解包目录: {decompile_dir}")
    return "\n".join(lines)


def scan_directory(scan_dir: str, output_dir: str | None) -> str:
    scan_path = os.path.abspath(os.path.expanduser(scan_dir))
    if not os.path.isdir(scan_path):
        return f"扫描目录不存在: {scan_path}"

    report_dir = os.path.abspath(os.path.expanduser(output_dir)) if output_dir else os.path.join(os.path.dirname(scan_path), "report")
    os.makedirs(report_dir, exist_ok=True)

    extractor = Extractor()
    result = extractor.scan_directory(scan_path, num_workers=1)
    summary = Extractor.get_summary(result)
    total_findings = sum(summary.values())

    json_path = os.path.join(report_dir, "report.json")
    html_path = os.path.join(report_dir, "report.html")
    Extractor.export_json(result, json_path)
    Extractor.export_html(result, html_path)

    lines = [
        f"扫描完成: {result.get('files_scanned', 0)} 个文件，发现 {total_findings} 条，耗时 {result.get('elapsed', 0)}s",
        f"JSON 报告: {json_path}",
        f"HTML 报告: {html_path}",
        "分类统计:",
    ]
    for key, count in summary.items():
        lines.append(f"- {Extractor.get_category_label(key)}: {count}")
    return "\n".join(lines)


def cmd_extract(args):
    packages_dir = resolve_packages_dir(args.packages_dir)
    print(extract_appid(args.appid, packages_dir, args.output_dir))


def cmd_scan(args):
    print(scan_directory(args.scan_dir, args.output_dir))


def cmd_extract_and_scan(args):
    packages_dir = resolve_packages_dir(args.packages_dir)
    root = resolve_output_dir(args.appid, args.output_dir)
    extract_text = extract_appid(args.appid, packages_dir, root)
    scan_text = scan_directory(os.path.join(root, "decompiled"), os.path.join(root, "report"))
    print(extract_text)
    print("")
    print(scan_text)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="WMP miniapp extraction CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="List wxapkg files grouped by appid")
    p_list.add_argument("--packages-dir", default=None)
    p_list.set_defaults(func=cmd_list)

    p_extract = sub.add_parser("extract", help="Decrypt and unpack one appid")
    p_extract.add_argument("--appid", required=True)
    p_extract.add_argument("--packages-dir", default=None)
    p_extract.add_argument("--output-dir", default=None)
    p_extract.set_defaults(func=cmd_extract)

    p_scan = sub.add_parser("scan", help="Scan an extracted directory")
    p_scan.add_argument("--scan-dir", required=True)
    p_scan.add_argument("--output-dir", default=None)
    p_scan.set_defaults(func=cmd_scan)

    p_both = sub.add_parser("extract-and-scan", help="Extract and scan one appid")
    p_both.add_argument("--appid", required=True)
    p_both.add_argument("--packages-dir", default=None)
    p_both.add_argument("--output-dir", default=None)
    p_both.set_defaults(func=cmd_extract_and_scan)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
