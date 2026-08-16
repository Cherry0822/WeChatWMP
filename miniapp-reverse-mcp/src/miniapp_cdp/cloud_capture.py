from __future__ import annotations

import asyncio
import json
import re
from pathlib import Path
from typing import Any

from .network_capture import NetworkCaptureService


_CLOUD_JS_PATH = Path(__file__).resolve().parent / "cloud_audit_inject.js"
_CLOUD_JS = _CLOUD_JS_PATH.read_text(encoding="utf-8")


def _extract_json(result: dict[str, Any]) -> dict[str, Any]:
    remote = result.get("result", {})
    value = remote.get("value")
    if value is None:
        raise RuntimeError(remote.get("description", "no return value"))
    if not isinstance(value, str):
        value = json.dumps(value, ensure_ascii=False)
    return json.loads(value)


class CloudCapture:
    def __init__(self) -> None:
        self._enabled = False
        self._seen = 0

    async def _collector(self, network_capture: NetworkCaptureService):
        await network_capture.ensure_monitoring()
        collector = network_capture.collector
        if collector is None:
            raise RuntimeError("Debugger not connected")
        return collector

    async def _inject(self, collector) -> None:
        await collector.evaluate_script(_CLOUD_JS, return_by_value=True, await_promise=True)

    async def start(self, network_capture: NetworkCaptureService) -> dict[str, Any]:
        if self._enabled:
            return {"ok": True, "already": True}
        collector = await self._collector(network_capture)
        await self._inject(collector)
        result = await collector.evaluate_script(
            "JSON.stringify(window.cloudAudit.installHook())",
            return_by_value=True,
            await_promise=True,
        )
        info = _extract_json(result)
        self._enabled = bool(info.get("ok"))
        return info

    async def stop(self, network_capture: NetworkCaptureService) -> dict[str, Any]:
        if not self._enabled:
            return {"ok": True, "already": False}
        collector = await self._collector(network_capture)
        await self._inject(collector)
        await collector.evaluate_script("window.cloudAudit.uninstallHook()", return_by_value=True, await_promise=True)
        self._enabled = False
        self._seen = 0
        return {"ok": True}

    async def poll(self, network_capture: NetworkCaptureService) -> list[dict[str, Any]]:
        collector = await self._collector(network_capture)
        if not self._enabled:
            await self.start(network_capture)
            if not self._enabled:
                return []
        await self._inject(collector)
        alive_result = await collector.evaluate_script(
            "(function(){try{return window.cloudAudit&&window.cloudAudit._hooked?'1':'0'}catch(e){return '0'}})()",
            return_by_value=True,
            await_promise=True,
        )
        alive = alive_result.get("result", {}).get("value")
        if alive != "1":
            await collector.evaluate_script(
                "JSON.stringify(window.cloudAudit.installHook())",
                return_by_value=True,
                await_promise=True,
            )
            self._seen = 0

        result = await collector.evaluate_script(
            "JSON.stringify(window.cloudAudit.getHookedCalls())",
            return_by_value=True,
            await_promise=True,
        )
        calls = _extract_json(result)
        if not isinstance(calls, list):
            return []
        new_calls = calls[self._seen:]
        self._seen = len(calls)
        return new_calls

    async def clear(self, network_capture: NetworkCaptureService) -> None:
        self._seen = 0
        collector = await self._collector(network_capture)
        await self._inject(collector)
        await collector.evaluate_script(
            "window.cloudAudit.clearHookedCalls()",
            return_by_value=True,
            await_promise=True,
        )

    async def call_function(
        self,
        network_capture: NetworkCaptureService,
        name: str,
        data: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        collector = await self._collector(network_capture)
        await self._inject(collector)
        safe_name = name.replace("\\", "\\\\").replace("'", "\\'")
        safe_data = json.dumps(data or {}, ensure_ascii=False)
        await collector.evaluate_script(
            "window._cloudAuditLastResult=null",
            return_by_value=True,
            await_promise=True,
        )
        js = (
            f"window.cloudAudit.callFunction('{safe_name}', {safe_data})"
            ".then(function(r){window._cloudAuditLastResult=JSON.stringify(r)})"
            "['catch'](function(e){window._cloudAuditLastResult="
            "JSON.stringify({ok:false,status:'fail',error:e.message||String(e)})})"
        )
        await collector.evaluate_script(js, return_by_value=True, await_promise=True)
        for _ in range(24):
            await asyncio.sleep(0.5)
            result = await collector.evaluate_script(
                "window._cloudAuditLastResult",
                return_by_value=True,
                await_promise=True,
            )
            value = result.get("result", {}).get("value")
            if value:
                try:
                    return json.loads(value)
                except (json.JSONDecodeError, TypeError):
                    return {"ok": False, "status": "fail", "reason": "parse error"}
        return {"ok": False, "status": "fail", "reason": "调用超时，无响应"}

    async def static_scan(self, network_capture: NetworkCaptureService) -> list[dict[str, Any]]:
        collector = await self._collector(network_capture)
        await self._inject(collector)
        try:
            env_result = await collector.evaluate_script(
                "JSON.stringify(window.cloudAudit.detectEnv())",
                return_by_value=True,
                await_promise=True,
            )
            env = _extract_json(env_result)
            appid = env.get("appId", "")
        except Exception:
            appid = ""

        name_re = re.compile(r"name\s*:\s*[\"']([^\"']+)[\"']")
        data_re = re.compile(r"data\s*:\s*\{([^}]{1,500})\}")
        field_re = re.compile(r"(\w+)\s*:")
        collection_re = re.compile(r"\.collection\s*\(\s*[\"']([^\"']+)[\"']\s*\)")
        skip = {"name", "success", "fail", "complete", "config", "env", "data"}
        file_methods = {"uploadFile", "downloadFile", "deleteFile", "getTempFileURL"}
        db_ops = {"add", "get", "update", "remove", "count", "aggregate", "doc", "where"}

        found: dict[str, dict[str, Any]] = {}
        scripts = list(collector.scripts.items())
        for script_id, script_record in scripts:
            try:
                source_result = await collector.get_script_source(script_id)
            except Exception:
                continue
            source = source_result.get("scriptSource", "")
            if not source:
                continue

            pos = 0
            while True:
                pos = source.find("callFunction", pos)
                if pos == -1:
                    break
                window = source[pos:pos + 1000]
                match = name_re.search(window)
                if match:
                    name = match.group(1)
                    key = f"fn:{name}"
                    if key not in found:
                        found[key] = {"type": "function", "name": name, "params": [], "count": 0}
                    found[key]["count"] += 1
                    data_match = data_re.search(window)
                    if data_match:
                        for field_match in field_re.finditer(data_match.group(1)):
                            field = field_match.group(1)
                            if field not in skip and field not in found[key]["params"]:
                                found[key]["params"].append(field)
                pos += 12

            for match in collection_re.finditer(source):
                collection = match.group(1)
                key = f"db:{collection}"
                if key not in found:
                    found[key] = {"type": "database", "name": collection, "params": [], "count": 0}
                found[key]["count"] += 1
                after = source[match.end():match.end() + 300]
                for op in db_ops:
                    if f".{op}(" in after and op not in found[key]["params"]:
                        found[key]["params"].append(op)

            for method in file_methods:
                if method in source:
                    key = f"storage:{method}"
                    if key not in found:
                        found[key] = {"type": "storage", "name": method, "params": [], "count": 0}
                    found[key]["count"] += 1

        return [
            {
                "name": info["name"],
                "type": info["type"],
                "appId": appid,
                "params": info["params"],
                "count": info["count"],
            }
            for info in found.values()
        ]
