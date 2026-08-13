from __future__ import annotations

import logging
import warnings

# 屏蔽 cdp_use 对“另一个 CDP 客户端(DevTools)响应”的刷屏日志
logging.getLogger("cdp_use").setLevel(logging.ERROR)
warnings.filterwarnings("ignore")

from run_mcp_server import main


if __name__ == "__main__":
    main()
