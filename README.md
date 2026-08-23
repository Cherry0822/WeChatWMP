# WeChatWMP

微信小程序远程调试、网络分析与 MCP 工具集，面向 macOS（Apple Silicon arm64 与 Intel x64）。项目把微信小程序运行时、标准 Chrome DevTools Protocol（CDP）和 Model Context Protocol（MCP）连接起来，让开发者可以用图形界面、Chrome DevTools 或 AI 客户端分析自己有权测试的小程序。

> 项目当前针对 **macOS 26** 构建。这里的“iOS 26”并不适用于本仓库：`WMPLauncher` 是 macOS SwiftUI 应用，不能直接编译为 iOS App。

## 能做什么

### WMPLauncher：macOS 图形控制台

- 一键启动、停止和重启调试器与 MCP 服务
- 检查 Node.js、Python、依赖、微信版本、SIP 和偏移配置
- 自动安装运行时依赖到应用支持目录
- 管理不同 WeChatAppEx 版本及 arm64/x64 偏移配置
- 查看统一日志、当前调试 target 和服务状态
- 小程序 wxapkg 解包与敏感信息扫描
- 路由读取、页面导航和强制跳转拦截
- 云函数捕获、手动调用和静态扫描
- wx API 捕获、过滤与重放
- 快速打开 CDP DevTools、复制 MCP 客户端配置

### WMPFDebugger-mac：Frida 与 CDP 协议网关

- 自动识别运行中的 `WeChatAppEx` 进程、微信版本和 CPU 架构
- 注入版本化 Frida Hook，强制开启小程序远程调试路径
- 将微信私有 protobuf 调试协议转换为标准 CDP
- 提供调试协议端口 `9421` 和 CDP WebSocket 代理端口 `62000`
- 支持 Chromium DevTools、MCP 服务和其他 CDP 客户端
- 可选的 JS 层云函数捕获与 TLS 层云流量分析
- 支持 Apple Silicon arm64 与 Intel x64；偏移配置位于 `frida/config/`

### miniapp-reverse-mcp：AI 可调用的 MCP 服务

Python 服务通过 stdio 提供 MCP 工具，并连接 `WMPFDebugger-mac` 的 CDP 代理。主要能力包括：

- **网络**：XHR/Fetch 请求、响应体、POST 数据、发起调用栈、WebSocket 帧
- **源码**：脚本列表、源码读取/保存、跨脚本搜索、运行时求值
- **断点**：XHR 断点、文本断点、事件监听断点、暂停信息、恢复和单步
- **运行时**：console/exception/execution context 事件、CPU profile、精确覆盖率
- **小程序包**：自动发现 wxapkg、解密解包、IP/域名/Token/密钥等敏感信息扫描
- **路由**：读取页面与 tabBar，执行 navigate/redirect/relaunch/back/refresh，拦截强制跳转
- **云开发**：云函数 Hook、轮询、清理、手动调用和静态引用扫描
- **wx API**：捕获 login/request/storage/导航等 API，轮询、清理和重放
- **调试状态**：读取和切换小程序内置 debug/vConsole 状态
- **Target**：枚举 AppService/WebView target 并切换当前调试目标

当前 MCP 服务注册 46 个工具，完整参数与说明见 [`miniapp-reverse-mcp/README.md`](miniapp-reverse-mcp/README.md)。

## 工作链路

```text
微信小程序
    │
    ├─ Frida Hook
    ▼
WMPFDebugger-mac
    ├─ 私有 protobuf 调试协议 ⇄ 标准 CDP
    ├─ 调试端口：9421
    └─ CDP 代理：62000
            │ WebSocket
            ▼
miniapp-reverse-mcp
    └─ MCP over stdio
            │
            ▼
Codex / Claude / Cursor / 其他 MCP 客户端

WMPLauncher 负责启动、停止、环境检测、版本配置和功能操作。
```

## 系统要求与限制

- macOS 26 或更高版本；支持 Apple Silicon 和 Intel
- 完整 Xcode（不是只有 Command Line Tools），用于 SwiftUI 宏和 macOS 26 SDK
- Node.js 22 LTS 或更高版本
- Python 3.11 或更高版本
- 已安装并运行 macOS 版微信
- 微信中已经打开目标小程序，使 `WeChatAppEx` 进程出现
- Frida 注入通常需要关闭 SIP；请在测试机器和测试账号上操作
- 需要与目标小程序、账号和数据相应的授权

微信或 WeChatAppEx 更新后，旧的偏移配置可能失效。若找不到匹配的 `addresses.<version>.json`，需要重新分析并维护偏移表。

## 快速开始

### 1. 获取源码

```bash
git clone https://github.com/Cherry0822/WeChatWMP.git
cd WeChatWMP
```

### 2. 启动调试器

```bash
cd WMPFDebugger-mac
npm install
node src/index.js
```

启动后：

- 调试协议监听 `127.0.0.1:9421`
- CDP 代理监听 `127.0.0.1:62000`
- 在微信中打开目标小程序
- 可用 Chromium DevTools 打开：

```text
devtools://devtools/bundled/inspector.html?ws=127.0.0.1:62000
```

顺序建议为：启动调试器 → 打开小程序 → 打开 DevTools 或 MCP 客户端。

### 3. 安装并运行 MCP

```bash
cd miniapp-reverse-mcp
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
python run_mcp_server_quiet.py
```

MCP 服务默认使用 stdio，并连接 `ws://127.0.0.1:62000`。它通常由 MCP 客户端拉起，不需要长期手动运行前台进程。

以 Claude Desktop 为例，在配置文件中加入：

```json
{
  "mcpServers": {
    "miniapp-reverse-mcp": {
      "command": "/绝对路径/WeChatWMP/miniapp-reverse-mcp/.venv/bin/python",
      "args": [
        "/绝对路径/WeChatWMP/miniapp-reverse-mcp/run_mcp_server.py"
      ],
      "cwd": "/绝对路径/WeChatWMP/miniapp-reverse-mcp"
    }
  }
}
```

Codex、Cursor、Cline 等支持 MCP 的客户端也使用相同的 `command`、`args` 和 `cwd` 思路。路径必须替换为本机绝对路径。

### 4. 使用 WMPLauncher

直接构建并运行控制台：

```bash
cd WMPLauncher
./build.sh
open ../WMPLauncher.app
```

应用会提供服务控制、环境检查、日志、版本、反编译、路由、云函数、接口抓包、target 和设置等页面。首次运行建议先进入“环境检查”，确认所有必需项通过后再启动服务。

## 在 macOS 26 上编译

`WMPLauncher/Package.swift` 声明了 `.macOS(.v26)`，`Info.plist` 的最低系统版本也是 `26.0`。请安装完整 Xcode，并确认开发者目录：

```bash
xcode-select -p
xcodebuild -version
```

构建：

```bash
cd WMPLauncher
./build.sh
```

脚本会：

1. 查找包含 SwiftUIMacros 的 Xcode
2. 执行 `swift build -c release`
3. 组装 `WMPLauncher.app`
4. 复制 Info.plist 与图标资源
5. 尝试使用临时签名进行本机运行

若安装了多个 Xcode，可指定：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh
```

当前构建使用临时签名，仅适合开发和测试；正式分发需要 Apple Developer 证书、签名和公证。

## GitHub Actions 发布

发布 workflow 位于 [`.github/workflows/release.yml`](.github/workflows/release.yml)，支持：

- 推送 `v*.*.*` 标签自动触发
- GitHub Actions 页面手动触发
- macOS runner 构建 `WMPLauncher.app`
- 打包 `WMPLauncher-macOS.zip`
- 构建 `miniapp-reverse-mcp` Python 包
- 安装 Node 依赖并执行基础依赖检查
- 自动创建 GitHub Release 并上传构建产物

发布示例：

```bash
git tag v0.1.7
git push origin v0.1.7
```

正式对外分发前，还应在 GitHub Secrets 中配置 Apple Developer 签名与公证所需凭据，并把 workflow 的临时签名替换为正式签名流程。

## 目录结构

```text
.
├── WMPLauncher/                 # SwiftUI macOS 控制台
│   ├── Sources/                 # UI、服务、环境检查、运行时控制
│   ├── Resources/               # 图标与资源
│   ├── Package.swift            # macOS 26 Swift Package
│   └── build.sh                 # 本地构建脚本
├── WMPFDebugger-mac/            # Node.js + Frida + CDP 网关
│   ├── frida/                   # Hook 与版本/架构偏移配置
│   ├── src/                     # 调试服务器、代理和协议转换
│   └── scripts/                 # 云抓包、探针和偏移生成工具
├── miniapp-reverse-mcp/         # Python MCP 服务端
│   ├── src/miniapp_cdp/         # CDP、采集器和 MCP 工具
│   ├── run_mcp_server.py        # MCP stdio 入口
│   └── run_runtime_server.py    # Launcher 使用的常驻 JSON 行协议
├── docs/ARCHITECTURE.md         # 详细架构、数据流和运行逻辑
└── .github/workflows/           # GitHub Actions 发布流程
```

## 文档入口

- [架构与运行逻辑](docs/ARCHITECTURE.md)
- [MCP 服务端与工具清单](miniapp-reverse-mcp/README.md)
- [Frida/CDP 调试器说明](WMPFDebugger-mac/README.md)
- [版本规划](GIT_VERSION_PLAN.md)

## 安全、合规与责任

本项目用于经过授权的调试、测试、问题定位和安全研究。请只分析你拥有或明确获准测试的小程序、账号和网络流量，不要绕过访问控制、窃取凭据或处理他人数据。

Frida 注入、关闭 SIP、读取 wxapkg 和捕获明文流量都可能带来系统、账号和隐私风险。建议使用隔离的测试环境、测试账号和最小权限，并在任务完成后停止服务、清理导出数据。

各子项目的许可证和第三方代码说明请以对应目录中的 `LICENSE`、源文件头部和上游项目条款为准。

