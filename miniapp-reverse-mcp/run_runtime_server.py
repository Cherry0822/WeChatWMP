#!/usr/bin/env python3
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import sys
from pathlib import Path

logging.getLogger("cdp_use").setLevel(logging.ERROR)

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from miniapp_cdp.mcp_server import MiniappCDPMCP
from run_runtime_cli import build_parser, main_async


async def dispatch(app: MiniappCDPMCP, arguments: list[str]) -> str:
    parser = build_parser()
    args = parser.parse_args(arguments)
    # main_async owns the existing CLI formatting; capture it for the JSON-line API.
    from io import StringIO
    from contextlib import redirect_stdout

    output = StringIO()
    with redirect_stdout(output):
        await main_async(args, app=app)
    return output.getvalue().strip()


async def serve() -> None:
    app = MiniappCDPMCP()
    try:
        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line:
                break
            request = None
            try:
                request = json.loads(line)
                request_id = request.get("id")
                arguments = request.get("args", [])
                if not isinstance(arguments, list) or not all(isinstance(x, str) for x in arguments):
                    raise ValueError("args must be an array of strings")
                data = await dispatch(app, arguments)
                response = {"id": request_id, "ok": True, "data": data}
            except Exception as exc:
                response = {"id": request.get("id") if isinstance(request, dict) else None, "ok": False, "error": str(exc)}
            print(json.dumps(response, ensure_ascii=False), flush=True)
    finally:
        collector = app.network_capture.collector
        if collector is not None:
            with contextlib.suppress(Exception):
                await collector.stop()


def main() -> None:
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
