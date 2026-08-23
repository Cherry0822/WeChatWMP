import SwiftUI
import AppKit
import Combine

// MARK: - 概览

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var debugger: DebuggerService
    @EnvironmentObject private var mcp: MCPClient
    @State private var gridWidth: CGFloat = 0
    @State private var targetAppID = ""
    @State private var targetName = ""
    @State private var targetLoading = false
    private let targetTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "概览", subtitle: "调试服务与 MCP 服务的一体化状态")

                LazyVGrid(columns: gridColumns, spacing: 12) {
                    debuggerCard
                    mcpCard
                    targetCard
                    envCard
                }
                .id(gridColumnCount)

                SectionTitle(text: "快捷操作")
                HStack(spacing: 10) {
                    Button(action: model.startDebugger) {
                        Label("启动调试器", systemImage: "play.fill")
                    }
                    .buttonStyle(GlassButtonStyle(tint: Color.accentColor))
                    .disabled(debugger.state.isRunning || debugger.state.isBusy)

                    Button(action: model.startMCP) {
                        Label("启动 MCP", systemImage: "play.fill")
                    }
                    .buttonStyle(GlassButtonStyle(tint: Color.accentColor))
                    .disabled(mcp.state.isRunning || mcp.state.isBusy)

                    Button(action: AppModel.openDevTools) {
                        Label("打开 DevTools", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(GlassButtonStyle())

                    Button(action: copyMCPConfig) {
                        Label("复制 MCP 配置", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                .controlSize(.regular)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                gridWidth = newWidth
            }
        }
        .onAppear { refreshTargetInfo() }
        .onReceive(targetTimer) { _ in
            refreshTargetInfo()
        }
    }

    private var gridColumnCount: Int {
        let spacing: CGFloat = 12
        let minimumCardWidth: CGFloat = 360
        let usable = max(gridWidth, minimumCardWidth)
        return max(1, Int((usable + spacing) / (minimumCardWidth + spacing)))
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: gridColumnCount)
    }

    private var debuggerCard: some View {
        LauncherCard(fillsHeight: true) {
            HStack {
                Label("调试服务", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                StatusPill(
                    text: debugger.state.label,
                    color: pillColor(debugger.state)
                )
            }
            Text("ws://127.0.0.1:62000")
                .font(.title3)
                .fontWeight(.semibold)
                .textSelection(.enabled)
            Text("调试端口 9421 · CDP 代理 62000" + (debugger.pid > 0 ? " · PID \(debugger.pid)" : ""))
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Button("打开 DevTools", action: AppModel.openDevTools)
                    .buttonStyle(GlassButtonStyle())
                Button(debugger.state.isRunning ? "关闭" : "启动",
                       action: debugger.state.isRunning ? model.stopDebugger : model.startDebugger)
                    .buttonStyle(GlassButtonStyle(tint: debugger.state.isRunning ? Color.launcherRed : Color.accentColor))
                    .disabled(debugger.state.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var mcpCard: some View {
        LauncherCard(fillsHeight: true) {
            HStack {
                Label("MCP 服务", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                StatusPill(text: mcp.state.label, color: pillColor(mcp.state))
            }
            Text("stdio · \(ToolCatalog.all.count) 个工具")
                .font(.title3)
                .fontWeight(.semibold)
            Text("miniapp-reverse-mcp · \(model.env.pythonPath)")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Button("复制配置", action: copyMCPConfig)
                    .buttonStyle(GlassButtonStyle())
                Button(mcp.state.isRunning ? "停止" : "启动", action: mcp.state.isRunning ? model.stopMCP : model.startMCP)
                    .buttonStyle(GlassButtonStyle(tint: mcp.state.isRunning ? Color.launcherRed : Color.accentColor))
                    .disabled(mcp.state.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var targetCard: some View {
        LauncherCard(fillsHeight: true) {
            HStack {
                Label("小程序 Target", systemImage: "scope")
                    .font(.headline)
                Spacer()
                StatusPill(text: model.env.wechatAppExRunning ? "已连接" : "未连接",
                           color: model.env.wechatAppExRunning ? .launcherGreen : .launcherOrange)
            }
            Text(targetName.isEmpty ? "等待小程序启动" : targetName)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(targetAppID.isEmpty
                 ? "AppID：未获取"
                 : "AppID：\(targetAppID)")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
                .textSelection(.enabled)
            Text(targetAppID.isEmpty
                 ? (targetLoading ? "正在读取当前 target…" : "未检测到当前小程序")
                 : "当前选中：AppService（逻辑层）")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                Button("刷新 Target", action: refreshTargetInfo)
                    .buttonStyle(GlassButtonStyle())
                Button("查看 Target", action: { model.tab = .tools })
                    .buttonStyle(GlassButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var envCard: some View {
        LauncherCard(fillsHeight: true) {
            HStack {
                Label("环境检查", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                StatusPill(
                    text: model.env.failCount > 0 ? "\(model.env.failCount) 项失败"
                         : (model.env.warnCount > 0 ? "\(model.env.warnCount) 个警告" : "全部通过"),
                    color: model.env.failCount > 0 ? .launcherRed
                         : (model.env.warnCount > 0 ? .launcherOrange : .launcherGreen)
                )
            }
            Text("\(model.env.okCount) / \(model.env.checks.count) 项通过")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Node \(model.env.nodePath) · Python \(model.env.pythonPath) · WeChat \(model.env.wechatVersion)")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
                .lineLimit(2)
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                detectEnvironmentButton
                viewDetailsButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detectEnvironmentButton: some View {
        Button {
            Task { await model.checkAndInstallEnvironment() }
        } label: {
            Label(
                model.isCheckingEnvironment ? "检测中…" : "检测环境",
                systemImage: model.isCheckingEnvironment
                    ? "arrow.triangle.2.circlepath"
                    : "checkmark.seal"
            )
        }
        .buttonStyle(GlassButtonStyle(tint: Color.accentColor))
        .disabled(model.isCheckingEnvironment)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var viewDetailsButton: some View {
        Button("查看详情", action: { model.tab = .environment })
            .buttonStyle(GlassButtonStyle())
    }

    private func refreshTargetInfo() {
        guard !targetLoading else { return }
        targetLoading = true
        RuntimeCommandRunner.call(model: model, arguments: ["route-config"]) { text in
            targetLoading = false
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                targetAppID = ""
                targetName = ""
                return
            }
            targetAppID = object["appid"] as? String ?? ""
            targetName = object["name"] as? String ?? ""
        }
    }

    private func pillColor(_ state: ServiceState) -> Color {
        switch state {
        case .running: return .launcherGreen
        case .failed: return .launcherRed
        case .starting, .stopping: return .launcherOrange
        case .stopped: return .launcherSecondary
        }
    }

    private func copyMCPConfig() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.mcpConfigJSON, forType: .string)
    }
}

struct EnvDetailRow: View {
    let item: EnvCheckItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name).fontWeight(.medium)
                    StatusPill(text: statusText, color: color)
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                if !item.suggestion.isEmpty {
                    Text("处理建议：\(item.suggestion)")
                        .font(.caption)
                        .foregroundColor(color)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusText: String {
        switch item.status {
        case .ok: return "通过"
        case .warn: return "警告"
        case .fail: return "失败"
        }
    }

    private var symbol: String {
        switch item.status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .ok: return .launcherGreen
        case .warn: return .launcherOrange
        case .fail: return .launcherRed
        }
    }
}

// MARK: - 服务

final class DebugSwitchState: ObservableObject {
    @Published var debugEnabled = false
    @Published var vconsoleVisible = false
    @Published var loading = false
    @Published var message = ""
}

struct ServicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var debugger: DebuggerService
    @EnvironmentObject private var mcp: MCPClient
    @StateObject private var debugUI = DebugSwitchState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "服务", subtitle: "调试器负责连接小程序，MCP 负责给 AI 提供 \(ToolCatalog.all.count) 个工具")

                HStack(alignment: .top, spacing: 12) {
                    debuggerCard
                    mcpCard
                }

                SectionTitle(text: "调试开关")
                debugSwitchCard
            }
        }
    }

    private var debuggerCard: some View {
        LauncherCard {
            HStack {
                Label("WMPFDebugger-mac", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                StatusPill(text: debugger.state.label, color: pillColor(debugger.state))
            }
            Text("node src/index.js")
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text(metaText)
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            HStack(spacing: 8) {
                Button(debugger.state.isRunning ? "重启" : "启动",
                       action: debugger.state.isRunning ? model.restartDebugger : model.startDebugger)
                    .buttonStyle(GlassButtonStyle(tint: debugger.state.isRunning ? Color.launcherOrange : Color.accentColor))
                    .disabled(debugger.state.isBusy)
                Button("关闭", role: .destructive, action: model.stopDebugger)
                    .buttonStyle(GlassButtonStyle())
                    .disabled(!debugger.state.isRunning || debugger.state.isBusy)
                Button("打开 DevTools", action: AppModel.openDevTools)
                    .buttonStyle(GlassButtonStyle())
                    .disabled(!debugger.state.isRunning)
            }
            .controlSize(.small)
        }
    }

    private var mcpCard: some View {
        LauncherCard {
            HStack {
                Label("miniapp-reverse-mcp", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                StatusPill(text: mcp.state.label, color: pillColor(mcp.state))
            }
            Text("stdio · 25 tools" + (mcp.connected ? " · 已握手" : ""))
                .font(.body.monospaced())
            Text("run_mcp_server_quiet.py · 默认 endpoint 127.0.0.1:62000")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            HStack(spacing: 8) {
                Button(mcp.state.isRunning ? "重启" : "启动",
                       action: mcp.state.isRunning ? model.restartMCP : model.startMCP)
                    .buttonStyle(GlassButtonStyle(tint: mcp.state.isRunning ? Color.launcherOrange : Color.accentColor))
                    .disabled(mcp.state.isBusy)
                Button("关闭", role: .destructive, action: model.stopMCP)
                    .buttonStyle(GlassButtonStyle())
                    .disabled(!mcp.state.isRunning || mcp.state.isBusy)
                Button("复制注册配置", action: copyConfig)
                    .buttonStyle(GlassButtonStyle())
                    .disabled(!mcp.state.isRunning)
            }
            .controlSize(.small)
        }
    }

    private var debugSwitchCard: some View {
        LauncherCard {
            Text("风险提示")
                .font(.headline)
                .foregroundColor(.launcherOrange)
            Text("非正规开启小程序调试存在账号风险，请勿在主力账号上使用，建议使用测试号。")
                .font(.callout)
                .foregroundColor(.launcherSecondary)

            HStack {
                Text("当前状态")
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                Text(debugStatusText)
                    .font(.headline)
                    .foregroundColor(debugUI.debugEnabled || debugUI.vconsoleVisible ? .launcherGreen : .launcherSecondary)
                Spacer()
                Button(debugUI.loading ? "检测中" : "刷新状态") { refreshDebugState() }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
                    .disabled(debugUI.loading)
            }

            HStack(spacing: 10) {
                Button {
                    setDebug(true)
                } label: {
                    Label("开启调试", systemImage: "ladybug.fill")
                }
                .buttonStyle(GlassButtonStyle(tint: .accentColor))
                .disabled(debugUI.loading)

                Button {
                    setDebug(false)
                } label: {
                    Label("关闭调试", systemImage: "ladybug")
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(debugUI.loading)
            }

            if !debugUI.message.isEmpty {
                Text(debugUI.message)
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var debugStatusText: String {
        if debugUI.debugEnabled && debugUI.vconsoleVisible { return "调试已开启，vConsole 可见" }
        if debugUI.debugEnabled { return "调试已开启" }
        if debugUI.vconsoleVisible { return "vConsole 可见" }
        return "未开启"
    }

    private func refreshDebugState() {
        debugUI.loading = true
        RuntimeCommandRunner.call(model: model, arguments: ["debug-state"]) { text in
            debugUI.loading = false
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                debugUI.message = text.isEmpty ? "未读取到调试状态。" : text
                return
            }
            debugUI.debugEnabled = object["debug"] as? Bool ?? false
            debugUI.vconsoleVisible = object["vconsole"] as? Bool ?? false
            debugUI.message = "状态已刷新。"
        }
    }

    private func setDebug(_ enabled: Bool) {
        debugUI.loading = true
        RuntimeCommandRunner.call(model: model, arguments: ["set-debug", "--enable", enabled ? "true" : "false"]) { text in
            debugUI.loading = false
            debugUI.debugEnabled = enabled
            debugUI.message = text
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if debugger.pid > 0 { parts.append("PID \(debugger.pid)") }
        if !model.env.wechatVersion.isEmpty { parts.append("WeChatAppEx \(model.env.wechatVersion)") }
        if !model.env.arch.isEmpty { parts.append(model.env.arch) }
        return parts.joined(separator: " · ")
    }

    private func pillColor(_ state: ServiceState) -> Color {
        switch state {
        case .running: return .launcherGreen
        case .failed: return .launcherRed
        case .starting, .stopping: return .launcherOrange
        case .stopped: return .launcherSecondary
        }
    }

    private func copyConfig() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.mcpConfigJSON, forType: .string)
    }
}

struct EnvironmentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "环境检查", subtitle: "检测调试器与 MCP 服务依赖，缺失项可一键自动安装")

                LauncherCard {
                    HStack {
                        Label("环境状态", systemImage: "checkmark.shield")
                            .font(.headline)
                        Spacer()
                        StatusPill(
                            text: model.env.failCount > 0 ? "\(model.env.failCount) 项失败"
                                 : (model.env.warnCount > 0 ? "\(model.env.warnCount) 个警告" : "全部通过"),
                            color: model.env.failCount > 0 ? .launcherRed
                                 : (model.env.warnCount > 0 ? .launcherOrange : .launcherGreen)
                        )
                    }
                    Text("\(model.env.okCount) / \(model.env.checks.count) 项通过")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Node \(model.env.nodePath) · Python \(model.env.pythonPath) · WeChat \(model.env.wechatVersion)")
                        .font(.caption)
                        .foregroundColor(.launcherSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await model.checkAndInstallEnvironment() }
                    } label: {
                        Label(
                            model.isCheckingEnvironment ? "检测中…" : "检测环境",
                            systemImage: model.isCheckingEnvironment
                                ? "arrow.triangle.2.circlepath"
                                : "checkmark.seal"
                        )
                    }
                    .buttonStyle(GlassButtonStyle(tint: Color.accentColor))
                    .disabled(model.isCheckingEnvironment)

                    Button("刷新") {
                        model.refreshEnv()
                    }
                    .buttonStyle(GlassButtonStyle())

                    if model.isCheckingEnvironment {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
                .padding(.bottom, 8)

                if !model.installMessage.isEmpty {
                    Text(model.installMessage)
                        .font(.caption)
                        .foregroundColor(.launcherSecondary)
                        .lineLimit(3)
                        .padding(.bottom, 8)
                }

                Text("共 \(model.env.checks.count) 项 · \(model.env.failCount) 项失败 · \(model.env.warnCount) 项警告")
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .padding(.bottom, 8)

                VStack(spacing: 8) {
                    ForEach(model.env.checks) { item in
                        EnvDetailRow(item: item)
                    }
                }
            }
        }
    }
}

struct LogView: View {
    @EnvironmentObject private var theme: GlassTheme
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "暂无日志" : text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("log-bottom")
            }
            .frame(minHeight: 180, maxHeight: 300)
            .glassSurface(cornerRadius: 9, opacity: theme.opacity)
            .onChange(of: text) {
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
    }
}

final class LogsViewState: ObservableObject {
    @Published var filter: LogStore.Source = .all
}

struct LiquidSourcePicker: View {
    @Binding var selection: LogStore.Source
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(LogStore.Source.allCases) { source in
                    let isSelected = selection == source

                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            selection = source
                        }
                    } label: {
                        Text(source.rawValue)
                            .font(.callout)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.72))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        isSelected ? .regular.tint(.accentColor).interactive() : .clear,
                        in: Capsule()
                    )
                    .glassEffectID(source.rawValue, in: namespace)
                }
            }
            .padding(3)
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var theme: GlassTheme
    @StateObject private var state = LogsViewState()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var filtered: [LogStore.Entry] {
        switch state.filter {
        case .all:
            return logStore.entries
        case .launcher, .debugger, .mcp:
            return logStore.entries.filter { $0.source == state.filter }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "运行日志", subtitle: "启动器、调试器与 MCP 服务的实时运行日志")

            HStack(spacing: 10) {
                LiquidSourcePicker(selection: $state.filter)
                    .frame(maxWidth: 340)

                Spacer(minLength: 0)

                Button {
                    copyLog()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(GlassButtonStyle())

                Button(role: .destructive) {
                    logStore.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { entry in
                            LogEntryRow(
                                entry: entry,
                                time: timeFormatter.string(from: entry.time)
                            )
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("log-bottom")
                    }
                }
                .frame(minHeight: 380, maxHeight: .infinity)
                .glassSurface(cornerRadius: 10, opacity: theme.opacity)
                .onChange(of: logStore.entries.count) {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
                .onChange(of: state.filter) {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
    }

    private func copyLog() {
        let text = filtered
            .map { "\(timeFormatter.string(from: $0.time)) [\($0.source.rawValue)] \($0.message)" }
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct LogEntryRow: View {
    let entry: LogStore.Entry
    let time: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.launcherSecondary)
                .frame(width: 56, alignment: .leading)
            Text(entry.source.rawValue)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(sourceColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(sourceColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 48, alignment: .center)
            Text(entry.message)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private var sourceColor: Color {
        switch entry.source {
        case .launcher: return .accentColor
        case .debugger: return .launcherGreen
        case .mcp: return .launcherOrange
        case .all: return .launcherSecondary
        }
    }
}

