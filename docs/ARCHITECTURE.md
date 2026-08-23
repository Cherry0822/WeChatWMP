# WMP 工具集 · 架构与运行逻辑

> 本文档基于当前仓库代码（`main` 分支）整理，描述三个组件的运行逻辑、数据流与关键约定。
> 适用于：`WMPFDebugger-mac`、`WMPLauncher`、`miniapp-reverse-mcp`。

## 1. 项目定位

WMP（WeChat Mini Program）是一套**微信小程序逆向调试工具集**，实现从「强制开启小程序远程调试」到「把 CDP 调试能力暴露给 AI 客户端」的完整链路：

```text
微信小程序 ←Frida Hook→ WMPFDebugger-mac (CDP 代理 :62000) ←WS→ miniapp-reverse-mcp (MCP) ←→ AI 客户端
                              ↑ 由 WMPLauncher（macOS App）负责启动 / 环境 / 版本管理
```

三个组件职责：

| 组件 | 技术栈 | 职责 |
|---|---|---|
| `WMPFDebugger-mac` | Node.js + Frida | 注入微信 `WeChatAppEx` 进程，把微信私有调试协议（protobuf）翻译成标准 CDP 协议，提供 `:62000` CDP 代理 |
| `miniapp-reverse-mcp` | Python (FastMCP) | 连接 CDP 代理，把网络抓包、断点、源码分析、wxapkg 反编译等能力封装成 46 个 MCP 工具 |
| `WMPLauncher` | SwiftUI (macOS) | 图形化控制台：启动/停止两个服务、环境检测与自动安装、版本偏移配置管理、以及各领域功能页（路由/云函数/wx API/反编译等） |

---

## 2. WMPFDebugger-mac（调试器/协议网关）

### 2.1 启动流程（`src/index.js`）

`node src/index.js` 依次启动三件事：

1. **`debug_server()` — 调试端口 `:9421`**
   与小程序端（被 Frida patch 后的 WeChatAppEx）建立 WebSocket 连接，收发**微信私有调试协议**消息。
2. **`proxy_server()` — CDP 端口 `:62000`**
   标准 CDP WebSocket 代理，供 Chrome DevTools（`devtools://...?ws=127.0.0.1:62000`）、miniapp-reverse-mcp 等 CDP 客户端连接。
3. **`frida_server()` — Frida 注入**
   - 用 `pgrep -f '/MacOS/WeChatAppEx.app/Contents/MacOS/WeChatAppEx'` 找到所有 WeChatAppEx 进程并 attach；
   - 用 `defaults read .../WeChatAppEx.app/Contents/Info.plist CFBundleVersion` 读取版本号（旧版 `4.18788.xxx` 取第二段，新版如 `269136` 直接是数字），自动匹配 `frida/config/addresses.{版本}.json`；
   - 把配置文件 JSON 替换进 `frida/hook.js` 的 `@@CONFIG@@` 占位符后注入进程。

收到 SIGINT/SIGTERM 或未捕获异常时执行 `shutdown()`：卸载全部 Frida 脚本 → 分离会话 → 关闭两个 WebSocket 服务。

### 2.2 协议转换（私有协议 ↔ CDP）

消息在两条链路上双向转换，核心是 `src/third-party/` 中从微信开发者工具提取的协议实现：

```text
小程序端 ──protobuf(WARemoteDebug_DebugMessage)──> :9421  ──codex.unwrapDebugMessageData──> CDP 消息 ──> :62000 ──> DevTools / MCP
小程序端 <──protobuf(WARemoteDebug_DebugMessage)── :9421  <──codex.wrapDebugMessageData──── CDP 消息 <── :62000 <── DevTools / MCP
```

- 上行：收到 protobuf 消息 → `WARemoteDebug_DebugMessage.decode` → `codex.unwrapDebugMessageData` 取出 `chromeDevtoolsResult` 类别的 `payload` → 广播给 `:62000` 的 CDP 客户端；
- 下行：CDP 客户端消息 → 包装成 `chromeDevtools` 类别 → `WARemoteDebug_DebugMessage.encode` → 发给小程序端；
- 同时监听 `customMessage` 类别里的 `__networkDebug` 方法，把 JS 层网络事件（`Network.requestWillBeSent` / `Network.responseReceived`）打印并追加写入 `/tmp/net-capture.log`（可用 `NET_CAPTURE_LOG` 环境变量覆盖）。

### 2.3 Frida Hook 机制（`frida/hook.js`）

根据 `frida/config/addresses.{版本}.json`（含 `Arch.arm64` / `Arch.x64` 双表）在 `WeChatAppEx Framework` 模块上 patch 四个点：

| 配置字段 | 作用 |
|---|---|
| `LoadStartHookOffset` | `AppletIndexContainer::OnLoadStart`（第一个），改寄存器（arm64: X1 / x64: RSI）强制开启调试 |
| `LoadStartHookOffset2` | `OnLoadStart`（最后一个），把入口场景值改写为可调试场景 `1101`（仅当场景值在白名单 `[1005, 1007, ...]` 内） |
| `CDPFilterHookOffset` | `SendToClientFilter` 过滤函数，放行 CDP 消息（v8[2]==6 时写 0） |
| `ResourceCachePolicyHookOffset` | 资源缓存策略函数，返回值改写为 `0x0` 跳过缓存限制 |
| `StructOffset` / `SceneOffset` | 场景结构体链式偏移（`a1+8 → +StructOffset → +16 → +SceneOffset`） |

配置文件兼容两种格式：旧版顶层直接是偏移字段；新版 `{ "Version": N, "WeChatVersion": "...", "Arch": { "arm64": {...}, "x64": {...} } }`（hook 内按 `Process.arch` 选择，x64 有 `x86_64/amd64` 别名兜底）。缺失必填字段时 hook 校验失败并停止。

### 2.4 云函数抓包（两条路线）

- **路线 A — JS 层（`src/cloud-hook.js`）**：通过 CDP `Runtime.evaluate` 向小程序 JS 上下文注入 hook，包装 `wx.cloud.callFunction` / `Cloud.prototype.callFunction` / `callContainer`，捕获结果写入页面全局数组 `__wxCloudHooks`（上限 500 条），由服务端周期性 `evaluate` drain 取回。注入前需先监听 `AddJsContext` 拿到 appservice 上下文，再用 `connectJsContext` 切换。
- **路线 B — TLS 层（`frida/cloud-capture.js` + `scripts/run-cloud-capture.js`）**：attach 微信的 `network.mojom.NetworkService` 子进程，hook BoringSSL `SSL_read` / `SSL_write` 明文读写函数（偏移来自配置文件的 `SSLPayloadReadOffset` / `SSLPayloadWriteOffset`，当前仅 269136/arm64），按 SSL 对象分组输出明文流量；宿主机解析 HTTP/1.1 与 HTTP/2 帧（HPACK 头部、gzip DATA 自动解压），识别云网关特征（`servicewechat.com` 等），完整报文写入 `CLOUD_CAPTURE_LOG`（默认 `/tmp/cloud-capture.log`）。离线还原可用 `tools/parse-cloud-capture.py`。

---

## 3. miniapp-reverse-mcp（MCP 服务端）

### 3.1 分层结构

```text
server.py (FastMCP 壳，46 个 @mcp.tool 注册)
   │
   ▼
mcp_server.py (MiniappCDPMCP 业务编排层)
   │  ├─ CDPRuntime            CDP 连接 / target 枚举 / session attach / 事件转发
   │  ├─ NetworkCaptureService 单 target 采集器的生命周期管理（懒启动、健康检查、自动重连）
   │  ├─ CloudCapture          wx.cloud 注入式捕获（cloud_audit_inject.js）
   │  ├─ WxApiCapture          wx API 注入式捕获（wxapi_inject.js）
   │  ├─ StateStore / EventBus 状态存储 / 事件分发
   │  └─ tools/*               各领域实现（network / script / debugger / runtime / target /
   │                           websocket / extraction / navigator / debug / cloud / wxapi）
   ▼
collectors/single_target_network.py (SingleTargetNetworkCollector 核心采集器)
```

### 3.2 连接与采集生命周期

所有工具首次调用都会走 `NetworkCaptureService.ensure_monitoring()`（连接超时 5 秒）：

1. **连接**：`endpoint.py` 把 `devtools://...?ws=127.0.0.1:62000` 解析成 `ws://127.0.0.1:62000`（也接受直接传 `ws://` / `wss://`）；
2. **枚举 target**：`Target.getTargets` 拿到全部 target（AppService 逻辑层、WebView 渲染层等）；
3. **选择 target**（`select_default_app_target`，五级优先级）：
   `page` 类型且 URL 含 `servicewechat.com` + `appservice.html` 且非 `preload-` → AppService preload → WebView `page-frame.html` 且标题为 `AppIndex` → WebView 非 preload → 任意 servicewechat page；
4. **attach**：`Target.attachToTarget(flatten: true)` 拿到 `sessionId`；
5. **启用域**：`Network.enable` / `Runtime.enable` / `Debugger.enable`（session 粒度），并设置异步调用栈深度 32；
6. **注册事件回调**：Network 请求生命周期、Debugger paused/resumed、Runtime console/exception/executionContext、WebSocket 收发帧等。

采集数据保存在 collector 内：请求记录 `records`（最新 2000 条，`deque` 上限）、脚本表 `scripts`、断点表、暂停状态 `paused_state`、console（1000）/exception（500）、WebSocket 连接表。连接断开时 `ensure_monitoring` 会检测到并自动重建。

### 3.3 三种运行形态

| 入口 | 协议 | 使用方 |
|---|---|---|
| `run_mcp_server.py`（`server.py` 的 FastMCP stdio） | MCP（JSON-RPC 2.0 over stdio） | AI 客户端（Claude Desktop / Codex 等，注册方式见 README） |
| `run_runtime_server.py` | 自定义 JSON 行协议：`{"id", "args":[...]}` → `{"id", "ok", "data"/"error"}`（单行换行分隔） | Launcher 的常驻运行时，持有 CDP collector 与捕获状态 |
| `run_runtime_cli.py` | 命令行单次调用（`route-config`、`cloud-start` 等子命令） | WMPLauncher 的 `RuntimeCommandRunner`（一次性进程） |

`run_runtime_server.py` 复用 `run_runtime_cli.py` 的命令表：`route-config` / `route` / `redirect-guard` / `debug-state` / `set-debug` / `cloud-start|stop|poll|clear|static-scan|call` / `targets` / `targets-json` / `target-attach` / `wxapi-start|stop|poll|clear|replay`。

### 3.4 注入式抓包（cloud / wxapi）

`CloudCapture` 与 `WxApiCapture` 都遵循同一模式：

1. `ensure_monitoring()` 拿到 collector；
2. `evaluate_script` 注入对应的 JS 审计脚本（`cloud_audit_inject.js` 暴露 `window.cloudAudit`，`wxapi_inject.js` 暴露 `window.__wxApiAudit`，均会扫描多 frame 收集所有 `wx.cloud` 实例 / `wx` 对象）；
3. 调用 `install()` / `installHook()` 包装原始方法，捕获调用入参、结果、异常，记录在页面内队列；
4. `poll_*` 工具通过 evaluate `drain` 表达式取走新记录（服务端维护 `_seen` 游标），并检测 hook 是否仍存活（页面刷新后自动重装）。

### 3.5 wxapkg 反编译与敏感信息扫描（`extraction/`）

- `wxapkg.py`：纯 Python 实现微信 4.0+ 的 wxapkg 解密+解包。加密格式：`V1MMWX` magic（6 字节）→ `file[6:1030]` 为 AES-256-CBC 加密区（密钥 `PBKDF2(appID, "saltiest", 1000, 32, SHA1)`，IV `"the iv: 16 bytes"`）→ `file[1030:]` 逐字节 XOR `appID[-2]`。解包按 `0xBE ... 0xED` 索引区还原文件。
- `extractor.py`：正则引擎（沿用 heartk_fast.py 规则），扫描 IP/域名/URL/身份证/手机号/邮箱/JWT/密钥等类别，支持自定义正则，输出 `report.json` + `report.html`。
- 工具链路：`list_wxapkg_files`（自动识别 macOS 默认包目录）→ `extract_wxapkg`（输出到 `analysis/<appid>/decompiled`）→ `scan_extracted_code` → `extract_and_scan_wxapkg`（一键）。

### 3.6 路由导航（`nav_inject.js`）

注入 `window.nav`（`UniversalMiniProgramNavigator`）：检测小程序环境 → 读取 `__wxConfig`（页面、tabBar、入口页、appid、名称）→ 提供 `current/navigate/redirect/relaunch/back/refresh` 导航动作；`redirect-guard` 开启后可拦截强制 `redirectTo/reLaunch/navigateTo` 并记录到 `_blockedRedirects`。重复注入时会先检测 `wxFrame` 是否仍有效（支持切换小程序）。

---

## 4. WMPLauncher（macOS 控制台）

### 4.1 应用骨架

`WMPLauncherApp`（`@main`）注入五个环境对象：`AppModel`（全局状态）、`DebuggerService`、`MCPClient`、`LogStore`（2000 条上限，来源 launcher/debugger/mcp）、`GlassTheme`（液态玻璃外观）。默认窗口 1080×720。主界面为左侧边栏 + 12 个 tab：

概览 / 服务 / 环境检查 / 日志 / 版本 / 反编译 / 路由导航 / 云函数 / 接口抓包 / 服务目标 / 工具 / 设置

### 4.2 进程管理

| 对象 | 子进程 | 说明 |
|---|---|---|
| `DebuggerService` | `env node src/index.js`（cwd 为 `WMPFDebugger-mac/`） | 启动/停止/重启调试器，管道实时收日志；停止先 `interrupt()`，4 秒未退再 `terminate()` |
| `MCPClient` | `env python run_mcp_server_quiet.py`（cwd 为 `miniapp-reverse-mcp/`） | 以 JSON-RPC 2.0 over stdio 直接与 MCP 服务通信：`initialize`（protocolVersion `2025-06-18`）→ `notifications/initialized` → `tools/call`；请求 60s 超时；握手 10s 超时 |
| `RuntimeCommandRunner` | 有状态命令走 `python run_runtime_server.py`，无状态命令走 `run_runtime_cli.py` | Launcher 统一命令入口 |
| `RuntimeDaemon` | `python run_runtime_server.py`（常驻，JSON 行协议） | 复用同一 `MiniappCDPMCP` 实例，保证捕获状态跨调用持续存在 |

启动调试器前 `AppModel.startDebugger()` 会用 `PortChecker`（lsof 检查 `:9421` / `:62000`）探测端口占用，弹窗让用户选择「释放端口并启动 / 直接启动 / 取消」。

### 4.3 环境检查与自动安装

- `EnvChecker.snapshot()` 检查 9 项：SIP 状态、Node ≥ 22、Python ≥ 3.11、WMPFDebugger 依赖（node_modules 中 frida/ws/protobufjs）、miniapp-reverse-mcp 依赖（venv 中 cdp_use/mcp）、微信 / WeChatAppEx 安装与版本、版本配置文件匹配（`addresses.{短版本}.json`）、x64 偏移表核对、WeChatAppEx 进程是否在运行。
- `EnvironmentInstaller.ensureAll()` 按需自动安装（所有产物进 `~/Library/Application Support/WMPLauncher/runtime/`）：
  1. Node ≥ 22：从 `nodejs.org/dist/index.json` 找最新 LTS（v2x）下载 darwin tar.gz 解压；
  2. Python：系统无 ≥3.11 时下载 `uv`（GitHub releases）并用 `uv python install 3.13`；
  3. 创建 `.venv` 并 `pip install -r requirements.txt`；
  4. `npm install --no-audit --no-fund` 补齐 WMPFDebugger 依赖。

### 4.4 版本配置管理

`VersionConfigStore` 读取/写入 `WMPFDebugger-mac/frida/config/addresses.{版本}.json`（模型：`{Version, WeChatVersion, Arch:{arm64, x64}}`）。「版本」tab 的 `VersionsView` 提供：当前微信版本/小程序版本/匹配配置展示、已有配置列表（按版本号降序）、arm64/x64 双表表单编辑（LoadStart/CDPFilter/ResourceCache/StructOffset/SceneOffset）、新增与保存。

### 4.5 各功能 tab 与后端对应

| Tab | UI 行为 | 后端调用 |
|---|---|---|
| 概览 | 4 状态卡片（调试器/MCP/target/环境），3 秒轮询刷新当前 target 信息，快捷启动/打开 DevTools/复制 MCP 配置 | `DebuggerService`、`MCPClient`、`RuntimeCommandRunner`（route-config） |
| 服务 | 调试器与 MCP 启动/重启/关闭、调试开关（`set_miniapp_debug`） | 进程管理 + `RuntimeCommandRunner`（debug-state / set-debug） |
| 环境检查 | 检查项列表 + 「检测并安装」 | `EnvChecker` + `EnvironmentInstaller` |
| 日志 | 按来源（全部/启动器/调试器/MCP）过滤 | `LogStore` |
| 版本 | 版本配置列表与编辑器 | `VersionConfigStore` |
| 反编译 | 包目录自动检测、小程序列表、解包、扫描（含自定义正则） | `RuntimeCLI` 直接运行 `run_extract_cli.py`（纯本地文件操作，不依赖 CDP）：`list` / `extract` / `scan` / `extract-and-scan`；默认输出 `analysis/<appid>/decompiled` 与 `analysis/<appid>/report/` |
| 路由导航 | 读取配置、页面列表搜索、导航动作、防强制跳转 | `RuntimeCommandRunner`（route-config / route / redirect-guard） |
| 云函数 | 开始/停止捕获、手动调用、静态扫描、1 秒轮询记录 | `RuntimeCommandRunner`（cloud-*） |
| 接口抓包 | 捕获 wx API、过滤、重放选中、2 秒轮询 | `RuntimeCommandRunner`（wxapi-*） |
| 服务目标 | target 列表（当前/已附加标记）、切换目标 | `RuntimeCommandRunner`（targets-json / target-attach） |
| 工具 | 46 个 MCP 工具的只读目录（分组、描述、参数） | `ToolCatalog`（静态数据） |
| 设置 | 项目路径（UserDefaults 持久化）、玻璃外观、MCP 注册配置 JSON 展示/复制、启动行为（开机启动/自动重启/日志落盘/启动时打开 DevTools） | `AppModel` / `GlassTheme` |

---

## 5. 仓库根目录辅助脚本

针对泡泡玛特小程序（appid `wx19e904724550a41f`）逆向的专项脚本，都基于 `MiniappCDPMCP` 直接驱动 CDP（去硬编码路径，直接 `miniapp-reverse-mcp/.venv/bin/python <脚本>` 运行）：

| 脚本 | 作用 |
|---|---|
| `bypass.py` | 运行时补丁：拦截 `wx.redirectTo/navigateTo/reLaunch` 把 `stopPC` / `network_busy` 跳转改写为排队页，排队页直接放行进首页；不改包，小程序重开失效 |
| `mock_login.py` | 注入前端登录态（`loginStatus` / `userId` / `login_token` 等）让会员页可进入、可触发真实请求（后端网关仍会 432 拦截） |
| `_analyze.py` | 快速探测：列出 targets / scripts / network 摘要 |

> 通用调试命令统一走 `run_runtime_cli.py`；Launcher 的有状态命令通过 `run_runtime_server.py` 执行。根目录专项脚本仍为独立调试入口。

---

## 6. 一次典型调试会话的时序

```text
1. 用户启动 WMPLauncher → 「启动调试器」→ node src/index.js
   ├─ :9421 调试端口 + :62000 CDP 代理就绪
   └─ Frida attach WeChatAppEx，按版本加载 addresses.{v}.json 并注入 hook.js
2. 用户在微信中打开目标小程序（先开小程序，后连调试器）
3. AI 客户端经 MCP 调用 list_network_requests
   └─ ensure_monitoring: 连接 :62000 → 枚举 target → 选 AppService → attach → enable → 开始采集
4. AI 调用 get_request_initiator / list_scripts / get_script_source 溯源请求发起代码
5. AI 用 set_breakpoint_on_text 在函数体内部语句设断点 → 用户再次触发操作 → get_paused_info
   → evaluate_script / step → resume_execution
6. 需要看云函数/wx API 时：start_cloud_capture / start_wxapi_capture → poll_* 拉取
7. 需要反编译：extract_and_scan_wxapkg(appid) 输出 analysis/<appid>/decompiled + report
8. 任务结束：remove_breakpoints(clear_all=True) 清理断点
```

---

## 7. 关键约定与注意事项

- **启动顺序**：先启动调试器，再打开小程序，最后连 DevTools/MCP；顺序颠倒需重做 2–4 步。
- **SIP**：必须关闭 SIP，否则 Frida 无权限 attach。
- **版本匹配**：WeChatAppEx 升级后需重新定位偏移并生成 `addresses.{版本}.json`（`scripts/generate-address.js`）；x64 表会沿用旧模板值需手动核对。`defaults read` 失败时回退默认版本 `17078`。
- **端口**：`9421`（小程序调试）、`62000`（CDP 代理），被占用时 Launcher 会提示释放。
- **MCP 工具**：默认 endpoint `devtools://devtools/bundled/inspector.html?ws=127.0.0.1:62000`；`switch_target` 会重建连接并清空网络记录与断点；请求缓存上限 2000 条；连接超时 5 秒。
- **断点建议**：不要在函数名/赋值处设断点（压缩代码中是一次性赋值），先 `get_script_source` 读函数体，再在内部语句设断点。
- **注入式抓包**：cloud/wxapi hook 随页面刷新失效，`poll_*` 会检测存活并自动重装；捕获队列在页面内（cloud 队列上限 500 条，wxapi 队列不截断）。
- **版本基线**：debugger `0.2.0` / launcher `0.1.0` / mcp `0.1.6`（见 `GIT_VERSION_PLAN.md`，单仓 trunk-based 流程）。

---

## 8. 目录速查

```text
WMP/
├── WMPFDebugger-mac/          # Node.js 调试器（Frida + 私有协议网关）
│   ├── src/index.js           # 主入口：debug_server / proxy_server / frida_server
│   ├── src/cloud-hook.js      # 云函数 JS 层捕获（路线 A）
│   ├── src/third-party/       # 微信开发者工具提取的协议实现
│   ├── frida/hook.js          # 四个 patch 点的主 hook
│   ├── frida/cloud-capture.js # TLS 层捕获（路线 B）
│   ├── frida/config/          # addresses.{版本}.json 偏移配置
│   └── scripts/               # generate-address / run-cloud-capture 等
├── WMPLauncher/               # SwiftUI macOS 控制台
│   └── Sources/               # AppModel / Services / Views / ToolCatalog / VersionConfigStore 等
├── miniapp-reverse-mcp/       # Python MCP 服务端
│   ├── src/miniapp_cdp/
│   │   ├── server.py          # FastMCP 工具注册（46 个）
│   │   ├── mcp_server.py      # MiniappCDPMCP 业务编排
│   │   ├── cdp_runtime.py     # CDP 连接 / target / session
│   │   ├── network_capture.py # 采集器生命周期
│   │   ├── collectors/        # 单 target CDP 采集器
│   │   ├── tools/             # 各领域工具实现
│   │   ├── extraction/        # wxapkg 解密 + 敏感信息扫描
│   │   ├── *_inject.js        # nav / cloud / wxapi 注入脚本
│   ├── run_mcp_server.py      # MCP stdio 入口
│   ├── run_runtime_server.py  # Launcher 常驻 daemon 入口
│   └── run_runtime_cli.py     # 单命令 CLI 入口
├── bypass.py / mock_login.py / _analyze.py  # 泡泡玛特专项脚本（调试命令统一走 run_runtime_cli.py）
└── GIT_VERSION_PLAN.md        # 版本管理与发布流程
```
