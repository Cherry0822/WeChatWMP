from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

from .network_capture import NetworkCaptureService


_WXAPI_JS_PATH = Path(__file__).resolve().parent / "wxapi_inject.js"
_WXAPI_JS = _WXAPI_JS_PATH.read_text(encoding="utf-8")


def _extract_json(result: dict[str, Any]) -> dict[str, Any]:
    remote = result.get("result", {})
    value = remote.get("value")
    if value is None:
        raise RuntimeError(remote.get("description", "no return value"))
    if not isinstance(value, str):
        value = json.dumps(value, ensure_ascii=False)
    return json.loads(value)


class WxApiCapture:
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
        await collector.evaluate_script(_WXAPI_JS, return_by_value=True, await_promise=True)

    async def start(self, network_capture: NetworkCaptureService) -> dict[str, Any]:
        if self._enabled:
            return {"ok": True, "already": True}
        collector = await self._collector(network_capture)
        await self._inject(collector)
        result = await collector.evaluate_script(
            "JSON.stringify(window.__wxApiAudit.install())",
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
        await collector.evaluate_script("window.__wxApiAudit.uninstall()", return_by_value=True, await_promise=True)
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
        result = await collector.evaluate_script(
            "JSON.stringify(window.__wxApiAudit.getCalls())",
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
        await collector.evaluate_script("window.__wxApiAudit.clear()", return_by_value=True, await_promise=True)

    async def replay(
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
            "window.__wxApiReplayResult=null",
            return_by_value=True,
            await_promise=True,
        )
        js = (
            f"window.__wxApiAudit.replay('{safe_name}', {safe_data})"
            ".then(function(r){window.__wxApiReplayResult=JSON.stringify(r)})"
            "['catch'](function(e){window.__wxApiReplayResult="
            "JSON.stringify({ok:false,status:'fail',error:e.message||String(e)})})"
        )
        await collector.evaluate_script(js, return_by_value=True, await_promise=True)
        for _ in range(20):
            await asyncio.sleep(0.5)
            result = await collector.evaluate_script(
                "window.__wxApiReplayResult",
                return_by_value=True,
                await_promise=True,
            )
            value = result.get("result", {}).get("value")
            if value:
                try:
                    return json.loads(value)
                except (json.JSONDecodeError, TypeError):
                    return {"ok": False, "status": "fail", "reason": "parse error"}
        return {"ok": False, "status": "fail", "reason": "replay timeout"}
