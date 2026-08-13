# miniapp-reverse-mcp

微信小程序 CDP 调试的 MCP 服务端（Python，版本 0.1.6）。

它连接 [WMPFDebugger-mac](../WMPFDebugger-mac/README.md) 提供的 CDP 代理
（默认 `ws://127.0.0.1:62000`），自动选择小程序的 AppService / WebView target，
并把网络抓包、源码查看、断点调试、运行时分析等能力封装成 MCP 工具，
供支持 MCP 的 AI 客户端（Codex、Claude 等）直接调用。

工作链路：

```text
微信小程序 ←Frida Hook→ WMPFDebugger-mac (CDP 代理 :62000)
                          ↑ WebSocket (CDP)
                    miniapp-reverse-mcp (MCP stdio)
                          ↑
                    AI 客户端 (Codex / Claude ...)
```

## 前置条件

- 已安装并启动 WMPFDebugger-mac（`cd ../WMPFDebugger-mac && node src/index.js`），
  并按要求关闭 SIP
- 微信中已打开要调试的小程序（先启动小程序，再连接调试器）
- Python >= 3.11

## 安装

```bash
cd miniapp-reverse-mcp
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

`pip install -e .` 会同时安装依赖（`cdp-use`、`mcp>=1.27.0`）并注册
`miniapp-reverse-mcp` 命令。如果不想以包方式安装，也可以直接：

```bash
pip install -r requirements.txt
```

## 启动

服务默认以 stdio 方式运行，由 MCP 客户端拉起，一般不需要手动前台运行。
手动验证时：

```bash
python run_mcp_server.py
```

日志比较吵的话，用安静版（屏蔽 `cdp_use` 的刷屏日志）：

```bash
python run_mcp_server_quiet.py
```

安装为包之后也可以直接运行：

```bash
miniapp-reverse-mcp
```

## MCP 注册配置

以 Claude Desktop 的 `claude_desktop_config.json` 为例：

```json
{
  "mcpServers": {
    "miniapp-reverse-mcp": {
      "command": "/absolute/path/to/miniapp-reverse-mcp/.venv/bin/python",
      "args": ["/absolute/path/to/miniapp-reverse-mcp/run_mcp_server.py"],
      "cwd": "/absolute/path/to/miniapp-reverse-mcp"
    }
  }
}
```

如果未使用虚拟环境，把 `command` 换成系统 `python` 即可。其他兼容 MCP 的客户端
（Codex、Cursor、Cline 等）使用同样的 `command` + `args` 注册方式，只是配置文件格式
略有不同；路径请一律使用绝对路径。

CLI 方式（Claude Code 示例）：

```bash
claude mcp add miniapp-reverse-mcp --transport stdio -- \
  /absolute/path/to/miniapp-reverse-mcp/.venv/bin/python \
  /absolute/path/to/miniapp-reverse-mcp/run_mcp_server.py
```

## 工具一览表

### 网络抓包

| 工具 | 说明 | 常用参数 |
| --- | --- | --- |
| `list_network_requests` | 自动连接 CDP 并监控当前 target 的 XHR/Fetch，返回请求列表或单条详情（最新在前，默认 20 条/页） | `endpoint`、`reqid`、`url_filter`、`resource_types`、`wait_ms`、`clear_existing`、`page_size`、`page_idx` |
| `get_response_body` | 读取某个请求的响应体（超过 10KB 截断，二进制显示 `<binary data>`） | `request_id` |
| `get_request_post_data` | 读取某个请求的 POST 数据（默认截断 20KB） | `request_id`、`max_size` |
| `get_request_initiator` | 查看发起该请求的 JS 调用栈，用于溯源 | `request_id` |
| `get_websocket_messages` | 列出 WebSocket 连接，或查看某个连接的收发帧 | `wsid`、`direction`、`show_content`、`page_size`、`page_idx` |

### 源码分析

| 工具 | 说明 | 常用参数 |
| --- | --- | --- |
| `list_scripts` | 列出当前页面已加载的 JS（含 URL 和 SourceMap 信息） | `url_filter` |
| `get_script_source` | 按 URL 或 script ID 读取源码片段；普通文件按行区间，压缩文件用字符 `offset`/`length` | `url`/`script_id`、`start_line`/`end_line` 或 `offset`/`length` |
| `save_script_source` | 把完整源码保存到本地文件（WASM 脚本保存为 `.wasm`） | `file_path`、`url`/`script_id` |
| `search_in_sources` | 在所有已加载源码中搜索字符串或正则，返回命中的脚本、行号和内容 | `query`、`is_regex`、`exclude_minified`、`url_filter`、`max_results` |
| `evaluate_script` | 执行 JS 表达式；暂停时自动在指定调用帧上下文求值 | `expression`、`await_promise`、`context_id`、`frame_index` |

### 断点调试

| 工具 | 说明 | 常用参数 |
| --- | --- | --- |
| `break_on_xhr` | 当 XHR/Fetch 请求 URL 包含指定字符串时暂停 | `url` |
| `set_breakpoint_on_text` | 在文本首次出现的位置设置代码断点（仅第一个匹配） | `text`、`condition`、`case_sensitive` |
| `set_event_listener_breakpoint` | 设置 DOM 事件监听断点（如 click、input） | `event_name`、`target_name` |
| `list_breakpoints` | 查看全部 XHR / 代码 / 事件断点 | - |
| `remove_breakpoints` | 按 ID / URL 删除断点，或 `clear_all=True` 清空全部 | `breakpoint_id`、`xhr_url`、`clear_all` |
| `get_paused_info` | 暂停时查看调用栈与作用域变量 | `frame_index`、`include_scopes`、`max_scope_depth` |
| `resume_execution` | 恢复执行 | - |
| `step` | 单步执行：`over` / `into` / `out` | `action` |

### 运行时与性能

| 工具 | 说明 | 常用参数 |
| --- | --- | --- |
| `get_runtime_events` | 获取捕获的 console / exception / execution context 事件 | `event_type`、`clear`、`limit` |
| `start_cpu_profile` / `stop_cpu_profile` | 启动 / 停止 CPU 采样，并汇总热点函数 | `sampling_interval`；`limit`、`include_profile` |
| `precise_coverage` | 精确覆盖率控制：`start` / `take` / `stop` | `action`、`reset`、`limit` |

### 目标切换

| 工具 | 说明 | 常用参数 |
| --- | --- | --- |
| `list_targets` | 列出当前所有 target（AppService、WebView 等） | - |
| `switch_target` | 切换到指定 target 线程 | `target_id` |

## 典型 AI 调试流程示例

目标：定位小程序点击"领取"后发出的请求，并分析发起代码与响应结构。

给 AI 的任务描述可以这样写：

```text
请调试微信小程序：让用户点击"领取"按钮，抓取它发出的网络请求；
找到发起该请求的 JS 代码，在解析响应的地方打断点，并说明响应结构。
```

AI 端的典型工具调用顺序：

1. 确认 WMPFDebugger-mac 已启动、小程序已打开。
2. 先调用 `list_network_requests(clear_existing=True)` 清空旧记录，
   让用户在小程序里点击"领取"，再调用 `list_network_requests()` 拿到 `reqid`。
3. 调用 `get_request_initiator(reqid)` 查看请求由哪段 JS 发起。
4. 用 `list_scripts(url_filter='...')` 和 `get_script_source(url=..., start_line, end_line)`
   阅读相关代码；压缩文件改用 `offset`/`length`。
5. 需要断点时调用 `set_breakpoint_on_text(text='解析响应处的具体语句')`。
   **不要在函数名或 `xxx = function` 赋值处打断点**——压缩代码里那只是一次性赋值；
   应先用 `get_script_source` 读到函数体，再在函数体内部的语句上打断点。
6. 让用户再次触发操作，调用 `get_paused_info()` 查看调用栈和变量；
   必要时用 `evaluate_script('...')` 检查表达式，用 `step(action='over')` 单步。
7. 完成后调用 `resume_execution()`；开始新任务前调用
   `remove_breakpoints(clear_all=True)` 清理全部断点。

## 注意事项

- 工具默认 endpoint 是
  `devtools://devtools/bundled/inspector.html?ws=127.0.0.1:62000`，
  也可以直接传 `ws://127.0.0.1:62000`。
- 大多数工具首次调用会自动连接并 attach 一个 target（优先选择 AppService 逻辑层）。
- `switch_target` 会重建连接，**清空之前的网络记录和断点**。
- 请求缓存上限 2000 条；响应体可能被引擎 GC 回收，取不到时需重新触发请求。
- `search_in_sources` 服务端默认 `exclude_minified=True`，如需搜压缩文件请显式传 `False`。
- 连接超时 5 秒。报超时先检查：WMPFDebugger-mac 是否在运行、小程序是否已打开、
  端口 62000 是否被占用。

## 项目结构

```text
miniapp-reverse-mcp/
├── pyproject.toml            # 包定义，提供 miniapp-reverse-mcp 命令
├── requirements.txt          # 依赖清单
├── run_mcp_server.py         # stdio 启动入口
├── run_mcp_server_quiet.py   # 安静模式启动入口
└── src/miniapp_cdp/
    ├── server.py             # FastMCP 服务与工具注册
    ├── mcp_server.py         # 业务编排层
    ├── cdp_runtime.py        # CDP 连接 / target / session 管理
    ├── network_capture.py    # 网络采集服务（自动连接与健康检查）
    ├── endpoint.py           # devtools:// URL 解析
    ├── models.py             # 数据模型
    ├── state_store.py        # 状态存储
    ├── event_bus.py          # CDP 事件分发
    ├── collectors/           # 单 target CDP 事件采集器
    └── tools/                # 各领域工具实现（network / script / debugger / runtime / target / websocket）
```
