from __future__ import annotations

import json
from typing import Any

from ..cloud_capture import CloudCapture
from ..network_capture import NetworkCaptureService


async def start_cloud_capture(network_capture: NetworkCaptureService, cloud: CloudCapture) -> str:
    return json.dumps(await cloud.start(network_capture), ensure_ascii=False)


async def stop_cloud_capture(network_capture: NetworkCaptureService, cloud: CloudCapture) -> str:
    return json.dumps(await cloud.stop(network_capture), ensure_ascii=False)


async def poll_cloud_calls(network_capture: NetworkCaptureService, cloud: CloudCapture) -> str:
    return json.dumps(await cloud.poll(network_capture), ensure_ascii=False)


async def clear_cloud_calls(network_capture: NetworkCaptureService, cloud: CloudCapture) -> str:
    await cloud.clear(network_capture)
    return json.dumps({"ok": True}, ensure_ascii=False)


async def call_cloud_function(
    network_capture: NetworkCaptureService,
    cloud: CloudCapture,
    name: str,
    data_json: str | None = None,
) -> str:
    data: dict[str, Any] = {}
    if data_json:
        try:
            parsed = json.loads(data_json)
            if isinstance(parsed, dict):
                data = parsed
        except json.JSONDecodeError:
            return json.dumps({"ok": False, "error": "data_json 不是有效 JSON"}, ensure_ascii=False)
    return json.dumps(await cloud.call_function(network_capture, name, data), ensure_ascii=False)


async def static_scan_cloud_functions(network_capture: NetworkCaptureService, cloud: CloudCapture) -> str:
    results = await cloud.static_scan(network_capture)
    return json.dumps(results, ensure_ascii=False)
