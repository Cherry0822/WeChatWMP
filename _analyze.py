import asyncio, sys, json
from pathlib import Path

ROOT = Path("/Users/cherry/Desktop/WMP/miniapp-reverse-mcp")
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from miniapp_cdp.mcp_server import MiniappCDPMCP

async def main():
    app = MiniappCDPMCP()
    print("=== list_targets ===")
    try:
        r = await app.list_targets()
        print(r)
    except Exception as e:
        print("ERROR list_targets:", repr(e))
    print("\n=== list_scripts ===")
    try:
        r = await app.list_scripts()
        print(r[:4000])
    except Exception as e:
        print("ERROR list_scripts:", repr(e))
    print("\n=== list_network_requests ===")
    try:
        r = await app.list_network_requests()
        print(r[:4000])
    except Exception as e:
        print("ERROR list_network_requests:", repr(e))

asyncio.run(main())
