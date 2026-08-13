# WMP 工具集 · Git 版本规划

> 适用范围：`WMPFDebugger-mac`、`WMPLauncher`、`miniapp-reverse-mcp` 三个组件。
> 当前状态：尚未初始化 Git 仓库（2026-08-13）。

## 1. 目标

为 WMP（微信小程序逆向调试工具集）建立一套清晰、可执行、可持续的版本管理方案，解决以下问题：

- 三个组件当前版本各自为政、`WMPLauncher` 无版本号；
- 没有分支模型、Tag 约定与发布流程；
- 无法回答「哪个版本能稳定配合工作」这个核心问题。

## 2. 仓库结构决策：单仓（monorepo）

三个组件同属一个产品链路，且 `miniapp-reverse-mcp` 依赖 `WMPFDebugger-mac` 的 CDP 代理，`WMPLauncher` 管理调试器版本/环境：

```text
微信小程序 ←Frida→ WMPFDebugger-mac(CDP :62000) ←WS→ miniapp-reverse-mcp(MCP) ←→ AI 客户端
                         ↑ 由 WMPLauncher 负责启动/环境/版本管理
```

**结论：采用单仓库（monorepo）**，三个组件作为子目录，保持一个仓库、统一发布、统一追溯。

```
WMP/
├── WMPFDebugger-mac/      # Node.js 组件
├── WMPLauncher/           # Swift 组件
├── miniapp-reverse-mcp/   # Python 组件
├── .gitignore
└── GIT_VERSION_PLAN.md
```

## 3. 当前版本盘点

| 组件 | 版本来源 | 当前版本 | 说明 |
|---|---|---|---|
| WMPFDebugger-mac | `package.json` | `1.0.0` | 直接继承上游，建议按本项目实际能力重新校准 |
| WMPLauncher | 无 | 未定义 | 建议从 `0.1.0` 起步 |
| miniapp-reverse-mcp | `pyproject.toml` | `0.1.6` | 已有迭代历史 |

## 4. 版本号规范：SemVer 2.0.0

统一采用语义化版本 `MAJOR.MINOR.PATCH`：

- **MAJOR**：不兼容的破坏性变更（协议断连、CLI/API 参数破坏、架构重写）；
- **MINOR**：向后兼容的新功能（新增 MCP 工具、新增调试能力）；
- **PATCH**：向后兼容的问题修复（bug fix、偏移修正、文档修正）。

附加规则：

- `0.x.y` 阶段允许 MINOR 包含破坏性变更（正式版前宽松）；
- 预发布用 `-alpha.N` / `-beta.N` / `-rc.N`，如 `0.2.0-rc.1`；
- 发布后不得修改已发布 Tag，有 bug 只能发新版本。

## 5. 各组件版本规划（路线图）

### 5.1 基线（现状，2026-08）

| 组件 | 版本 | 状态 |
|---|---|---|
| WMPFDebugger-mac | `1.0.0` | 已存在，建议校准为 `0.x` 语义或明确为本项目首发版 |
| WMPLauncher | `0.1.0` | 首次定义版本号 |
| miniapp-reverse-mcp | `0.1.6` | 保持 |

> 建议：由于本项目在 WMPFDebugger-arm 基础上做了大量改动且未达上游同等成熟度，
> 建议 `WMPFDebugger-mac` 从 `0.2.0` 重新起版本，与其它组件对齐「工具集尚未 1.0」的定位。

### 5.2 里程碑 M1：整合发布 `0.2.0`

目标：三组件首次作为一个整体可交付、可追溯。

| 组件 | 目标版本 | 主要内容 |
|---|---|---|
| WMPFDebugger-mac | `0.2.0` | 偏移配置热更新、版本自动检测增强、CDP 稳定性 |
| WMPLauncher | `0.2.0` | 一键环境检查/安装、版本切换、日志查看 UI 闭环 |
| miniapp-reverse-mcp | `0.2.0` | 网络抓包/断点/源码工具集稳定，补齐错误处理 |

### 5.3 里程碑 M2：能力扩展 `0.3.0`

| 组件 | 目标版本 | 主要内容 |
|---|---|---|
| WMPFDebugger-mac | `0.3.0` | 新增协议子命令/插件钩子、多小程序并发调试 |
| WMPLauncher | `0.3.0` | 配置导入导出、环境模板、自动更新 |
| miniapp-reverse-mcp | `0.3.0` | 新增运行时分析、抓包回放、批量工具 |

### 5.4 里程碑 M3：稳定版 `1.0.0`

- 三组件 API/协议冻结，进入长期维护；
- 完整文档、示例与回归测试；
- 发布渠道固化（GitHub Release + 可安装包）。

## 6. 分支模型：trunk-based + 发布分支（推荐）

三个组件耦合紧密、当前为个人/小团队开发，**不采用重量级 Git Flow**，改用更轻量的主干开发：

### 6.1 分支定义

| 分支 | 作用 | 生命周期 |
|---|---|---|
| `main` | 始终可发布的稳定主干 | 长期 |
| `feature/*` | 单个功能/组件特性开发 | 短期，合并后删除 |
| `fix/*` | bug 修复 | 短期，合并后删除 |
| `chore/*` | 配置/文档/构建等 | 短期，合并后删除 |
| `release/x.y` | 发布前冻结与回归（可选） | 发布后删除或留档 |

### 6.2 工作流

```text
main ──────────────────────────────────────────────
  │
  ├── feature/mcp-network-replay ──┐
  │          (开发)                 │ 合并回 main
  ├── feature/launcher-env-check ──┘
  │
  ├── release/0.2 ── 打 Tag wmp-v0.2.0 ── 发布 ── 合并回 main
```

规则：

1. `main` 上永远不直接开发，一切改动通过 PR（个人开发可用本地分支合并）；
2. 一个分支只做一件事（一个组件、一个功能）；
3. 合并前 `git rebase main` 保持线性历史；
4. 发布时从 `main` 切 `release/x.y`，仅修 bug，验证后打 Tag 并合回 `main`。

## 7. Tag 与发布流程

### 7.1 Tag 命名

| 类型 | 格式 | 示例 |
|---|---|---|
| 整仓聚合发布 | `wmp-vX.Y.Z` | `wmp-v0.2.0` |
| 组件单独发布 | `<component>-vX.Y.Z` | `miniapp-reverse-mcp-v0.2.0` |
| 预发布 | `wmp-vX.Y.Z-rc.N` | `wmp-v0.2.0-rc.1` |

### 7.2 发布步骤

```bash
# 1) 从 main 切发布分支
git checkout main && git pull
git checkout -b release/0.2

# 2) 同步组件版本号
#    WMPFDebugger-mac/package.json
#    miniapp-reverse-mcp/pyproject.toml
#    WMPLauncher/Package.swift 或 Info.plist（新增版本字段）

# 3) 回归验证
#    WMPFDebugger-mac: node src/index.js
#    miniapp-reverse-mcp: pip install -e . && miniapp-reverse-mcp
#    WMPLauncher: ./build.sh

# 4) 提交并打注解标签
git commit -am "chore: release wmp 0.2.0"
git tag -a wmp-v0.2.0 -m "WMP 工具集 0.2.0 整合发布"

# 5) 合回 main 并推送
git checkout main
git merge --no-ff release/0.2
git push origin main --tags
git branch -d release/0.2
```

## 8. Commit 规范：Conventional Commits

格式：`<type>(<scope>): <subject>`

- `type`：`feat` / `fix` / `docs` / `refactor` / `test` / `build` / `ci` / `chore` / `perf`
- `scope`（可选，按组件）：`debugger` / `launcher` / `mcp` / `repo`

示例：

```text
feat(mcp): 新增网络抓包回放工具
fix(debugger): 修复 arm64 偏移加载错误
docs: 更新 README 安装步骤
chore(repo): 添加 .gitignore 与版本规划
```

## 9. .gitignore 策略（各组件忽略项）

| 组件 | 忽略内容 |
|---|---|
| 全局 | `.DS_Store`、`*.log` |
| WMPFDebugger-mac | `node_modules/`、`dist/`、`*.local` |
| WMPLauncher | `.build/`、`.swiftpm/`、`WMPLauncher.app`（产物） |
| miniapp-reverse-mcp | `.venv/`、`__pycache__/`、`*.pyc`、`*.egg-info/` |

已在本仓库根目录生成配套 `.gitignore`。

## 10. 初始化清单（待执行）

```bash
cd /Users/cherry/Desktop/WMP
git init
git add .
git commit -m "chore(repo): 初始化 WMP 工具集单仓并添加版本规划"

# 建立首个基线 Tag
git tag -a wmp-v0.1.6 -m "当前基线：debugger 0.2.0 / launcher 0.1.0 / mcp 0.1.6"
```

后续按 6/7 节的分支与 Tag 流程推进。

## 11. 可选：CI/CD 建议

- **PR 校验**：`main` 分支保护 + 强制 PR；Node `yarn lint/test`、Swift `swift build`、Python `pytest`；
- **自动发版**：Tag `wmp-v*` 触发 GitHub Actions，分别构建三组件产物并发布 GitHub Release；
- **版本一致性检查**：CI 校验 `package.json` / `pyproject.toml` / `Info.plist` 三者版本是否与 Tag 匹配。
