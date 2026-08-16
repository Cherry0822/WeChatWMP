from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any

from ..extraction import wxapkg
from ..extraction.extractor import Extractor


def _resolve_packages_dir(packages_dir: str | None) -> tuple[str | None, str]:
    if packages_dir:
        path = os.path.abspath(os.path.expanduser(packages_dir))
        if not os.path.isdir(path):
            return None, f"packages_dir 不存在: {path}"
        return path, ""

    default_path = wxapkg.get_default_packages_dir()
    if not default_path:
        return None, "未找到默认小程序包目录，请显式传入 packages_dir"
    return default_path, ""


def _format_files(files: list[dict[str, Any]]) -> str:
    if not files:
        return "未找到 wxapkg 文件"
    lines = [f"共找到 {len(files)} 个 wxapkg 文件:"]
    for file in files:
        lines.append(
            f"- appid={file.get('appid', '')} path={file.get('path', '')} "
            f"name={file.get('name', '')} size={file.get('size', 0)}"
        )
    return "\n".join(lines)


def _default_extract_output_dir(appid: str) -> str:
    return str(Path.cwd() / "analysis" / appid)


def _scan_dir(scan_dir: str, output_dir: str | None, custom_patterns: dict[str, Any] | None) -> str:
    scan_path = os.path.abspath(os.path.expanduser(scan_dir))
    if not os.path.isdir(scan_path):
        return f"scan_dir 不存在: {scan_path}"

    if output_dir:
        report_dir = os.path.abspath(os.path.expanduser(output_dir))
    else:
        report_dir = os.path.join(os.path.dirname(scan_path), "scan-report")

    os.makedirs(report_dir, exist_ok=True)

    extractor = Extractor()
    if custom_patterns:
        for name, value in custom_patterns.items():
            if isinstance(value, dict):
                if value.get("enabled") is False:
                    continue
                pattern = value.get("regex", "")
            else:
                pattern = value
            if pattern:
                extractor.add_custom_pattern(str(name), str(pattern))

    # macOS 下从 stdio/MCP 进程启动 ProcessPool 可能失败或漏结果，先固定单进程，保证扫描完整。
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
        label = Extractor.get_category_label(key)
        lines.append(f"- {label}: {count}")
    return "\n".join(lines)


def _extract(appid: str, packages_dir: str | None, output_dir: str | None) -> str:
    resolved_packages, error = _resolve_packages_dir(packages_dir)
    if error:
        return error

    files = wxapkg.find_wxapkg_files(resolved_packages)
    matched = [file for file in files if file.get("appid") == appid]
    if not matched:
        available = sorted({file.get("appid", "") for file in files if file.get("appid")})
        return (
            f"未找到 appid={appid} 的 wxapkg 文件。"
            + (f"当前目录可用 appid: {', '.join(available)}" if available else "")
        )

    root = os.path.abspath(os.path.expanduser(output_dir)) if output_dir else _default_extract_output_dir(appid)
    decompile_dir = os.path.join(root, "decompiled")
    os.makedirs(decompile_dir, exist_ok=True)

    lines = [f"开始解包 appid={appid}，共 {len(matched)} 个文件:"]
    total_files = 0
    for file in matched:
        try:
            extracted = wxapkg.extract_wxapkg(file["path"], decompile_dir, appid)
            total_files += len(extracted)
            lines.append(f"- {file.get('name', '')}: {len(extracted)} 个文件")
        except Exception as exc:
            lines.append(f"- {file.get('name', '')}: 解包失败 {exc}")
    lines.append(f"解包完成，共提取 {total_files} 个文件")
    lines.append(f"解包目录: {decompile_dir}")
    return "\n".join(lines)


def _extract_and_scan(
    appid: str,
    packages_dir: str | None,
    output_dir: str | None,
    custom_patterns: dict[str, Any] | None,
) -> str:
    resolved_packages, error = _resolve_packages_dir(packages_dir)
    if error:
        return error

    files = wxapkg.find_wxapkg_files(resolved_packages)
    matched = [file for file in files if file.get("appid") == appid]
    if not matched:
        available = sorted({file.get("appid", "") for file in files if file.get("appid")})
        return (
            f"未找到 appid={appid} 的 wxapkg 文件。"
            + (f"当前目录可用 appid: {', '.join(available)}" if available else "")
        )

    root = os.path.abspath(os.path.expanduser(output_dir)) if output_dir else _default_extract_output_dir(appid)
    decompile_dir = os.path.join(root, "decompiled")
    os.makedirs(decompile_dir, exist_ok=True)

    extract_lines: list[str] = []
    total_files = 0
    for file in matched:
        try:
            extracted = wxapkg.extract_wxapkg(file["path"], decompile_dir, appid)
            total_files += len(extracted)
            extract_lines.append(f"- {file.get('name', '')}: {len(extracted)} 个文件")
        except Exception as exc:
            extract_lines.append(f"- {file.get('name', '')}: 解包失败 {exc}")

    report_dir = os.path.join(root, "report")
    scan_lines = _scan_dir(decompile_dir, report_dir, custom_patterns).splitlines()

    lines = [f"开始一键解包并扫描 appid={appid}", f"共 {len(matched)} 个 wxapkg 文件，提取 {total_files} 个文件"]
    lines.extend(extract_lines)
    lines.append("")
    lines.append("扫描结果:")
    lines.extend(scan_lines)
    return "\n".join(lines)


def _parse_custom_patterns(raw: str | None) -> dict[str, Any] | None:
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(value, dict):
        return None
    return value


async def list_wxapkg_files(packages_dir: str | None = None, appid: str | None = None) -> str:
    def run() -> str:
        resolved_packages, error = _resolve_packages_dir(packages_dir)
        if error:
            return error
        files = wxapkg.find_wxapkg_files(resolved_packages)
        if appid:
            files = [file for file in files if file.get("appid") == appid]
        return _format_files(files)

    return await asyncio.to_thread(run)


async def extract_wxapkg(
    appid: str,
    packages_dir: str | None = None,
    output_dir: str | None = None,
) -> str:
    return await asyncio.to_thread(_extract, appid, packages_dir, output_dir)


async def scan_extracted_code(
    scan_dir: str,
    output_dir: str | None = None,
    custom_patterns_json: str | None = None,
) -> str:
    return await asyncio.to_thread(
        _scan_dir,
        scan_dir,
        output_dir,
        _parse_custom_patterns(custom_patterns_json),
    )


async def extract_and_scan_wxapkg(
    appid: str,
    packages_dir: str | None = None,
    output_dir: str | None = None,
    custom_patterns_json: str | None = None,
) -> str:
    return await asyncio.to_thread(
        _extract_and_scan,
        appid,
        packages_dir,
        output_dir,
        _parse_custom_patterns(custom_patterns_json),
    )
