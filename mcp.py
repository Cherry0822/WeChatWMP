from __future__ import annotations
import asyncio, sys, json, logging, warnings
from pathlib import Path

logging.getLogger("cdp_use").setLevel(logging.ERROR)
logging.basicConfig(level=logging.WARNING)
warnings.filterwarnings("ignore")

ROOT = Path("/Users/cherry/Desktop/WMP/miniapp-reverse-mcp")
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from miniapp_cdp.mcp_server import MiniappCDPMCP

USAGE = """Usage:
  mcp.py targets
  mcp.py scripts [url_filter]
  mcp.py source --url URL [--start N --end M | --offset N --length M]
  mcp.py source --id SCRIPT_ID [--start N --end M | --offset N --length M]
  mcp.py search QUERY [--regex] [--max N] [--no-exclude-minified]
  mcp.py network [wait_ms] [--clear]
  mcp.py eval EXPR
  mcp.py switch TARGET_ID
  mcp.py break_on_xhr URL
  mcp.py break_on_text TEXT
  mcp.py list_breakpoints
  mcp.py resume
  mcp.py paused [frame_index]
  mcp.py step ACTION
  mcp.py ws [wsid] [--direction DIR]
  mcp.py runtime_events EVENT_TYPE [--clear] [--limit N]
"""

async def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(USAGE)
        return 0

    cmd = args[0]
    app = MiniappCDPMCP()

    if cmd == "targets":
        print(await app.list_targets())
    elif cmd == "scripts":
        filt = args[1] if len(args) > 1 else None
        print(await app.list_scripts(url_filter=filt))
    elif cmd == "source":
        url = None; sid = None; start = None; end = None; offset = None; length = 1000
        i = 1
        while i < len(args):
            a = args[i]
            if a == "--url":
                url = args[i+1]; i += 2
            elif a == "--id":
                sid = args[i+1]; i += 2
            elif a == "--start":
                start = int(args[i+1]); i += 2
            elif a == "--end":
                end = int(args[i+1]); i += 2
            elif a == "--offset":
                offset = int(args[i+1]); i += 2
            elif a == "--length":
                length = int(args[i+1]); i += 2
            else:
                i += 1
        print(await app.get_script_source(script_id=sid, url=url, start_line=start, end_line=end, offset=offset, length=length))
    elif cmd == "search":
        query = args[1]
        is_regex = "--regex" in args
        max_results = 30
        if "--max" in args:
            max_results = int(args[args.index("--max")+1])
        exclude_minified = "--no-exclude-minified" not in args
        print(await app.search_in_sources(query=query, is_regex=is_regex, max_results=max_results, exclude_minified=exclude_minified))
    elif cmd == "network":
        wait_ms = 0; clear = False
        for a in args[1:]:
            if a == "--clear":
                clear = True
            elif a.isdigit() and wait_ms == 0:
                wait_ms = int(a)
        print(await app.list_network_requests(wait_ms=wait_ms, clear_existing=clear))
    elif cmd == "eval":
        expr = args[1]
        print(await app.evaluate_script(expression=expr))
    elif cmd == "switch":
        tid = args[1]
        print(await app.switch_target(target_id=tid))
    elif cmd == "break_on_xhr":
        print(await app.break_on_xhr(url=args[1]))
    elif cmd == "break_on_text":
        print(await app.set_breakpoint_on_text(text=args[1]))
    elif cmd == "list_breakpoints":
        print(await app.list_breakpoints())
    elif cmd == "resume":
        print(await app.resume_execution())
    elif cmd == "paused":
        fi = int(args[1]) if len(args) > 1 else 0
        print(await app.get_paused_info(frame_index=fi))
    elif cmd == "step":
        print(await app.step(action=args[1]))
    elif cmd == "ws":
        wsid = args[1] if len(args) > 1 else None
        direction = None
        if "--direction" in args:
            direction = args[args.index("--direction")+1]
        print(await app.get_websocket_messages(wsid=wsid, direction=direction, show_content=False))
    elif cmd == "runtime_events":
        et = args[1] if len(args) > 1 else "console"
        clear = "--clear" in args
        limit = 50
        if "--limit" in args:
            limit = int(args[args.index("--limit")+1])
        print(await app.get_runtime_events(event_type=et, clear=clear, limit=limit))
    else:
        print(USAGE)
    return 0

if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
