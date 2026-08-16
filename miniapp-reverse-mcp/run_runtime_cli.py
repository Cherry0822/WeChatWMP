#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import warnings
from pathlib import Path

logging.getLogger("cdp_use").setLevel(logging.ERROR)
warnings.filterwarnings("ignore")


ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from miniapp_cdp.mcp_server import MiniappCDPMCP


async def main_async(args) -> None:
    app = MiniappCDPMCP()

    if args.command == "route-config":
        print(await app.get_miniapp_route_config())
    elif args.command == "route":
        print(await app.navigate_miniapp(action=args.action, route=args.route, delta=args.delta))
    elif args.command == "redirect-guard":
        print(await app.set_miniapp_redirect_guard(enabled=args.enabled))
    elif args.command == "debug-state":
        print(await app.get_miniapp_debug_state())
    elif args.command == "set-debug":
        print(await app.set_miniapp_debug(enable=args.enable))
    elif args.command == "cloud-start":
        print(await app.start_cloud_capture())
    elif args.command == "cloud-stop":
        print(await app.stop_cloud_capture())
    elif args.command == "cloud-poll":
        print(await app.poll_cloud_calls())
    elif args.command == "cloud-clear":
        print(await app.clear_cloud_calls())
    elif args.command == "cloud-call":
        print(await app.call_cloud_function(name=args.name, data_json=args.data_json))
    elif args.command == "cloud-static-scan":
        print(await app.static_scan_cloud_functions())
    elif args.command == "targets":
        print(await app.list_targets())
    elif args.command == "targets-json":
        await app.network_capture.ensure_monitoring()
        collector = app.network_capture.collector
        if collector is None:
            print(json.dumps([], ensure_ascii=False))
        else:
            items = []
            for target in collector.state_store.list_targets():
                items.append({
                    "target_id": target.target_id,
                    "target_type": target.target_type,
                    "title": target.title,
                    "url": target.url,
                    "attached": target.attached,
                    "session_id": target.session_id or "",
                    "selected": bool(collector.selected_target and collector.selected_target.target_id == target.target_id),
                })
            print(json.dumps(items, ensure_ascii=False))
    elif args.command == "target-attach":
        print(await app.switch_target(target_id=args.target_id))
    elif args.command == "wxapi-start":
        print(await app.start_wxapi_capture())
    elif args.command == "wxapi-stop":
        print(await app.stop_wxapi_capture())
    elif args.command == "wxapi-poll":
        print(await app.poll_wxapi_calls())
    elif args.command == "wxapi-clear":
        print(await app.clear_wxapi_calls())
    elif args.command == "wxapi-replay":
        print(await app.replay_wxapi_call(name=args.name, data_json=args.data_json))
    else:
        raise SystemExit(f"unknown command: {args.command}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="WMP runtime CDP CLI")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("route-config").set_defaults(func=None)

    p_route = sub.add_parser("route")
    p_route.add_argument("--action", required=True)
    p_route.add_argument("--route", default=None)
    p_route.add_argument("--delta", type=int, default=1)

    p_guard = sub.add_parser("redirect-guard")
    p_guard.add_argument("--enabled", type=lambda value: value.lower() == "true", required=True)

    sub.add_parser("debug-state")

    p_debug = sub.add_parser("set-debug")
    p_debug.add_argument("--enable", type=lambda value: value.lower() == "true", required=True)

    sub.add_parser("cloud-start")
    sub.add_parser("cloud-stop")
    sub.add_parser("cloud-poll")
    sub.add_parser("cloud-clear")

    p_call = sub.add_parser("cloud-call")
    p_call.add_argument("--name", required=True)
    p_call.add_argument("--data-json", default=None)

    sub.add_parser("cloud-static-scan")

    sub.add_parser("targets")
    sub.add_parser("targets-json")

    p_target = sub.add_parser("target-attach")
    p_target.add_argument("--target-id", required=True)

    sub.add_parser("wxapi-start")
    sub.add_parser("wxapi-stop")
    sub.add_parser("wxapi-poll")
    sub.add_parser("wxapi-clear")

    p_wxapi = sub.add_parser("wxapi-replay")
    p_wxapi.add_argument("--name", required=True)
    p_wxapi.add_argument("--data-json", default=None)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        asyncio.run(main_async(args))
    except Exception as exc:
        print(f"RUNTIME_ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
