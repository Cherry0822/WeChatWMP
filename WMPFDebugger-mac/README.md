# WMPFDebugger-mac

macOS 版本的微信小程序调试工具（支持 Intel x64 和 Apple Silicon arm64）

## 项目简介

本项目基于以下两个优秀的开源项目修改而成：

- [WMPFDebugger](https://github.com/evi0s/WMPFDebugger) - Windows 版本的微信小程序调试工具
- [WMPFDebugger-arm](https://github.com/chain00x/WMPFDebugger-arm) - macOS ARM 版本的适配

本项目在 WMPFDebugger-arm 的基础上，实现了以下改进(还有倒退 笑)：

- ✅ **双架构支持**：同时支持 macOS Intel (x64) 和 Apple Silicon (arm64/M芯片)
- ✅ **完善的版本管理**：通过配置文件管理不同版本的偏移地址，便于维护和扩展
- ✅ **自动架构检测**：自动检测系统架构并加载对应的配置
- ✅ **自动版本检测**：自动检测 WeChatAppEx 版本并加载对应的配置文件
- ✅ **移除ts**：直接使用js，方便小白运行(是的我就是小白)

## 工作原理

这个工具通过 patch 一些 Chrome 调试协议（CDP）的过滤器和其他的条件判断来强制小程序连接到外部调试器（也就是远程调试，LanDebug 模式）。这个调试协议是基于 protobuf 实现的私有协议，通过逆向开发者工具提取相应的协议实现，该工具实现了一个简单的小程序调试协议转换为标准 Chrome 调试协议，从而允许我们使用标准基于 chromium 浏览器的内嵌开发者工具来调试任意小程序。

## 系统要求

- **操作系统**：macOS（支持 Intel x64 和 Apple Silicon arm64）
- **Node.js**：至少 LTS v22 版本
- **包管理器**：npm
- **浏览器**：基于 Chromium 的浏览器（如 Chrome、Edge 等）
- **微信**：已安装并运行微信 macOS 版本
- **关闭SIP**：您必须关闭电脑的SIP，否则frida没有权限

## 安装

**第 1 步** 克隆仓库并安装依赖

```bash
git clone https://github.com/your-username/WMPFDebugger-mac
cd WMPFDebugger-mac
npm install
```

## 使用方法

**第 2 步** 运行调试服务器（请注意需要关闭SIP不然会报错）

```bash
node src/index.js
```

该命令会：
- 启动调试服务器（端口 9421）
- 启动 CDP 代理服务器（端口 62000）
- 自动检测 WeChatAppEx 版本和系统架构
- 自动注入 hook 脚本到小程序运行时

> **重要提示**：在此步骤之后，你需要**先启动小程序**（第 3 步），**再打开开发者工具**（第 4 步）。如果操作顺序相反，你可能需要重新执行步骤 2-4。

**第 3 步** 打开任意你想调试的小程序

在微信中打开任意小程序，确保小程序正常运行。

**第 4 步** 打开 Chrome DevTools

在浏览器中访问以下地址：

```
devtools://devtools/bundled/inspector.html?ws=127.0.0.1:62000
```

即可开始调试。你可以修改 `src/index.js` 中的 `CDP_PORT` 常量来更改端口号（默认为 62000）。

## 支持的版本

当前支持的 WMPF 版本：

- **18788** (最新)
- **18152**

> **如何检查你的 WeChatAppEx 版本**：
> 
> 在终端运行以下命令：
> ```bash
> defaults read /Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/Info.plist CFBundleVersion
> ```
> 版本号是输出中第二个数字（例如：`4.18788.xxx` 中的 `18788`）

## 版本管理

本项目使用配置文件管理不同版本的偏移地址。配置文件位于 `frida/config/` 目录下，命名格式为 `addresses.{版本号}.json`。

每个配置文件包含：
- `Version`：版本号
- `Arch`：架构配置
  - `arm64`：Apple Silicon (M芯片) 的偏移地址
  - `x64`：Intel 处理器的偏移地址

系统会自动：
1. 检测当前运行的 WeChatAppEx 版本
2. 检测系统架构（arm64 或 x64）
3. 加载对应的配置文件

### 添加新版本支持

**第 1 步** 确认当前 WeChatAppEx 版本号（见上文"支持的版本"）。

**第 2 步** 在 WeChatAppEx Framework 中找到新版本对应的偏移地址。可参考
[chain00x/WMPFDebugger-arm](https://github.com/chain00x/WMPFDebugger-arm) 的方法，
或作者的 B 站视频 [macos打开小程序调试控制台找偏移方法](https://www.bilibili.com/video/BV1gMqfBkEn8)。
需要准备以下偏移：

| 偏移字段 | 作用 |
| --- | --- |
| `LoadStartHookOffset` / `LoadStartHookOffset2` | `AppletIndexContainer::OnLoadStart` 两个函数入口，用于修改寄存器强制开启调试 |
| `CDPFilterHookOffset` | `SendToClientFilter` 过滤函数，用于放行 CDP 消息 |
| `ResourceCachePolicyHookOffset` | 资源缓存策略函数，用于跳过缓存策略限制 |
| `StructOffset` / `SceneOffset` | 场景结构体偏移，用于把入口场景改写为可调试场景 |

云抓包（路线 B）额外字段（当前仅 269136 / arm64）：

| 偏移字段 | 作用 |
| --- | --- |
| `SSLPayloadReadOffset` / `SSLPayloadWriteOffset` | NetworkService 进程中 BoringSSL 明文读写函数偏移，用于 TLS 层抓包 |

**第 3 步** 运行生成脚本，脚本会以 `addresses.18788.json` 为模板生成新配置文件：

```bash
node scripts/generate-address.js <version> <LoadStartHookOffset> <LoadStartHookOffset2> <CDPFilterHookOffset> <ResourceCachePolicyHookOffset> <StructOffset> [SceneOffset]
```

例如：

```bash
node scripts/generate-address.js 20008 0x4F744C4 0x8444BD0 0x8436B98 0x4FDC5BC 1440 456
```

执行后会在 `frida/config/` 下生成 `addresses.20008.json`：

- `arm64` 表使用你传入的偏移（`SceneOffset` 省略时沿用旧值）
- `x64` 表会沿用 `addresses.18788.json` 的旧值，**Intel 用户需要手动更新**

**第 4 步** 重启 `node src/index.js`，看到如下日志即表示新版本加载成功：

```text
[frida] Loaded config for version: 20008 (arch: arm64)
```

## 云函数/云开发抓包（路线 B，原生 TLS 层）

macOS 端小程序网络请求由 WeChatAppEx 的 **NetworkService 子进程**（Chromium 网络栈）发出，
云函数（`wx.cloud`）由基础库 JS（`WACloud.js`）实现，请求同样走该进程。本工具通过 Frida hook
NetworkService 里的 BoringSSL 明文读写函数，在 TLS 解密后抓取 HTTP/1.1 与 HTTP/2 流量，
并按连接（SSL 对象）分组输出。

### 使用

```bash
# 需先满足：关闭 SIP、微信已运行、打开过至少一个小程序
node scripts/run-cloud-capture.js
```

- 终端实时输出：`REQ/RESP`（HTTP/1.1）、`H2 HEADERS/DATA`（HTTP/2 帧）、`[CLOUD]` 标记
- 完整原始报文写入 `/tmp/cloud-capture.log`（可用 `CLOUD_CAPTURE_LOG` 环境变量改路径）
- 停止：Ctrl+C

### 已知结论与限制

1. 云函数调用**不走**主进程的 `operateWXData` 桥（二进制中不存在 `cloud`/`callFunction`
   命令字面量），因此只 hook 主进程抓不到云函数。
2. 实测云开发体验小程序（wxcf5102ada68a7ac9）的云函数流量：请求为 HTTP/2 GET
   到 `sh.servicewechat.com` 网关（函数名/参数在 URL），**响应为 gzip 压缩 JSON**，
   解压后即明文（剧集列表、openid、播放链接等），并非业务层 AES 加密。
3. 微盟类小程序（茄皇/东鹏）的部分业务请求有 SDK 层加密（实测签到 body 为密文），
   这类与微信云函数无关，需另行处理。
4. HTTP/2 HEADERS 为 HPACK 压缩：`scripts/run-cloud-capture.js` 实时输出帧，
   `tools/parse-cloud-capture.py` 可离线按连接还原 URL（连接需从建立开始捕获），
   并对 gzip DATA 帧自动解压。
5. 每次 WeChatAppEx 更新需重新定位两个 SSL 偏移：用
   `tools/find_string_xrefs.py` 按 `SSL_write couldn` / `SSL_read` 字符串交叉引用回溯。

## 项目结构

```
WMPFDebugger-mac/
├── frida/
│   ├── config/              # 版本配置文件目录
│   │   ├── addresses.18152.json
│   │   └── addresses.18788.json
│   └── hook.js             # Frida hook 脚本
├── scripts/
│   └── generate-address.js # 生成新版偏移配置的脚本
├── src/
│   ├── index.js            # 主程序入口（调试服务器 + CDP 代理 + Frida 注入）
│   └── third-party/        # 第三方协议实现（来自微信开发者工具）
│       ├── RemoteDebugCodex.js
│       ├── RemoteDebugConstants.js
│       ├── RemoteDebugUtils.js
│       └── WARemoteDebugProtobuf.js
├── package.json
└── package-lock.json
└── README.md
```

## 故障排除

### 无法找到 WeChatAppEx 进程

确保：
- 微信已启动
- 至少打开过一个小程序（这样才会启动 WeChatAppEx 进程）

### 连接失败

1. 确保先启动小程序，再打开 DevTools
2. 检查端口是否被占用
3. 尝试重启微信和调试服务器

### 版本不支持

如果提示版本不支持，说明当前 WeChatAppEx 版本还没有对应的配置文件。你可以：
1. 提交 Issue 请求添加新版本支持(我懒，不一定会去更新)
2. 请查看[chain00x/WMPFDebugger-arm](https://github.com/chain00x/WMPFDebugger-arm)项目内的方法
3. 赞助催我更新
4. 看我B站视频[macos打开小程序调试控制台找偏移方法](https://www.bilibili.com/video/BV1gMqfBkEn8)

如果启动时报 `未找到版本 17078 对应的配置文件`，说明 `defaults read` 读取
WeChatAppEx 版本失败，程序回退到了默认版本 17078。请确认微信已安装、
`WeChatAppEx.app` 存在，并用上文命令手动核对版本号。

## 致谢

- [evi0s/WMPFDebugger](https://github.com/evi0s/WMPFDebugger) - Windows 版本
- [chain00x/WMPFDebugger-arm](https://github.com/chain00x/WMPFDebugger-arm) - macOS ARM 版本适配

## 许可证

本项目采用 GPL-2.0 许可证开源。

## 免责声明

**本库只能作为学习用途，造成的任何问题与本库开发者无关，如侵犯到你的权益，请联系删除**

该程序以 GPLv2 许可证开源，参考许可证第十一及十二条：

本程序为免费授权，故在适用法律范围内不提供品质担保。除非另作书面声明，版权持有人及其他程式提供者"概"不提供任何显式或隐式的品质担保，品质担保所指包括而不仅限于有经济价值和适合特定用途的保证。全部风险，如程序的质量和性能问题，皆由你承担。若程序出现缺陷，你将承担所有必要的修复和更正服务的费用。

除非适用法律或书面协议要求，任何版权持有人或本程序按本协议可能存在的第三方修改和再发布者，都不对你的损失负有责任，包括由于使用或者不能使用本程序造成的任何一般的、特殊的、偶发的或重大的损失（包括而不仅限于数据丢失、数据失真、你或第三方的后续损失、其他程序无法与本程序协同运作），即使那些人声称会对此负责。

此外，在 `src/third-party` 中，所有代码从微信开发者工具提取，因此腾讯控股有限公司拥有对该代码的所有版权。
