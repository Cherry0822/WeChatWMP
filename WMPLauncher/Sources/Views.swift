import SwiftUI
import AppKit

extension AnyTransition {
    static let liquidGlass: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
        removal: .opacity.combined(with: .scale(scale: 1.03, anchor: .top))
    )
}

final class ToolsSelection: ObservableObject {
    @Published var selectedTool: ToolInfo?
}

final class SettingsUIState: ObservableObject {
    @Published var copied = false
}

// MARK: - 颜色与小组件

extension Color {
    static let launcherText = Color(nsColor: .textColor)
    static let launcherSecondary = Color(nsColor: .secondaryLabelColor)
    static let launcherGreen = Color(nsColor: .systemGreen)
    static let launcherOrange = Color(nsColor: .systemOrange)
    static let launcherRed = Color(nsColor: .systemRed)
    static let launcherBlue = Color.accentColor
}

struct StatusPill: View {
    @EnvironmentObject private var theme: GlassTheme
    let text: String
    var color: Color = .launcherSecondary

    var body: some View {
        GlassPill(text: text, color: color, opacity: theme.opacity)
    }
}

struct LauncherCard<Content: View>: View {
    @EnvironmentObject private var theme: GlassTheme
    @ViewBuilder let content: () -> Content
    let fillsHeight: Bool

    init(fillsHeight: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.fillsHeight = fillsHeight
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            content()
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsHeight ? .infinity : nil,
            alignment: .topLeading
        )
        .glassPanel(cornerRadius: 10, opacity: theme.opacity)
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2).fontWeight(.semibold)
            Text(subtitle).font(.callout).foregroundColor(.launcherSecondary)
        }
        .padding(.bottom, 16)
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.launcherSecondary)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            CelosiaBackground()

            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 190)
                Divider()
                Group {
                    switch model.tab {
                    case .overview: OverviewView()
                    case .services: ServicesView()
                    case .environment: EnvironmentView()
                    case .logs: LogsView()
                    case .versions: VersionsView()
                    case .tools: ToolsView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(22)
                .id(model.tab)
                .transition(.liquidGlass)
            }
            .frame(minWidth: 960, minHeight: 660)
        }
        .preferredColorScheme(.dark)
        .background(WindowTransparency())
        .task {
            model.bootstrap()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: GlassTheme
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GlassEffectContainer(spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(LauncherTab.allCases) { tab in
                        let isSelected = model.tab == tab

                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                model.tab = tab
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: tab.icon)
                                    .frame(width: 18)
                                Text(tab.title)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.82))
                        .glassEffect(
                            isSelected ? .regular.tint(.accentColor).interactive() : .clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .glassEffectID(tab.id, in: namespace)
                    }
                }
                .padding(3)
            }
            Spacer()
            Text("v0.1.0 · GPL-2.0")
                .font(.caption2)
                .foregroundColor(.launcherSecondary)
                .padding(8)
        }
        .padding(10)
        .background(
            GlassBackground(
                material: .sidebar,
                blendingMode: .withinWindow,
                cornerRadius: 0,
                opacity: theme.opacity
            )
        )
    }
}

// MARK: - 概览

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var debugger: DebuggerService
    @EnvironmentObject private var mcp: MCPClient
    @State private var gridWidth: CGFloat = 0

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
            Text("stdio · 25 个工具")
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
            Text(model.env.wechatAppExRunning ? "AppService + WebView" : "等待小程序启动")
                .font(.title3)
                .fontWeight(.semibold)
            Text(model.env.wechatAppExRunning
                 ? "当前选中：AppService（逻辑层）"
                 : "请在微信中打开一个小程序")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            Spacer(minLength: 6)
            Button("查看 Target", action: { model.tab = .tools })
                .buttonStyle(GlassButtonStyle())
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

struct ServicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var debugger: DebuggerService
    @EnvironmentObject private var mcp: MCPClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "服务", subtitle: "调试器负责连接小程序，MCP 负责给 AI 提供 25 个工具")

                HStack(alignment: .top, spacing: 12) {
                    debuggerCard
                    mcpCard
                }
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
            .onChange(of: text) { _ in
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
                .onChange(of: logStore.entries.count) { _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
                .onChange(of: state.filter) { _ in
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

// MARK: - 工具

struct ToolsView: View {
    @StateObject private var selection = ToolsSelection()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "MCP 工具", subtitle: "共 25 个工具，按领域分组，点击查看说明与常用参数")

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ToolCatalog.groups(), id: \.name) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: group.icon)
                                Text(group.name).font(.headline)
                                Text("\(group.tools.count) 个")
                                    .font(.caption)
                                    .foregroundColor(.launcherSecondary)
                            }
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 175), spacing: 8)],
                                alignment: .leading,
                                spacing: 8
                            ) {
                                ForEach(group.tools) { tool in
                                    ToolChip(
                                        tool: tool,
                                        isSelected: selection.selectedTool?.id == tool.id
                                    ) {
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                            selection.selectedTool = tool
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if let tool = selection.selectedTool {
                    LauncherCard {
                        Text(tool.name).font(.headline).textSelection(.enabled)
                        Text(tool.group)
                            .font(.caption)
                            .foregroundColor(.launcherSecondary)
                        Text(tool.desc).font(.callout)
                        if !tool.params.isEmpty {
                            Text("常用参数")
                                .font(.caption)
                                .foregroundColor(.launcherSecondary)
                            HStack(spacing: 6) {
                                ForEach(tool.params, id: \.self) { param in
                                    Text(param)
                                        .font(.system(size: 11, design: .monospaced))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.10), in: Capsule())
                                        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                                }
                            }
                        }
                    }
                    .padding(.top, 20)
                } else {
                    Text("点击上方任意工具查看详情")
                        .font(.callout)
                        .foregroundColor(.launcherSecondary)
                        .padding(.top, 20)
                }
            }
        }
    }

}

struct ToolChip: View {
    let tool: ToolInfo
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(tool.name)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .foregroundColor(isSelected ? Color.white : Color.primary.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: GlassTheme
    @StateObject private var uiState = SettingsUIState()

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoRestart") private var autoRestart = true
    @AppStorage("logToDisk") private var logToDisk = false
    @AppStorage("openDevToolsOnStart") private var openDevToolsOnStart = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "设置", subtitle: "项目路径、液态玻璃外观、MCP 注册与启动行为")

                glassAppearanceSection

                SectionTitle(text: "项目路径")
                VStack(alignment: .leading, spacing: 12) {
                    settingField("项目路径") {
                        TextField("项目路径", text: $model.projectRoot)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.projectRoot) { newValue in
                                UserDefaults.standard.set(newValue, forKey: "projectRoot")
                                model.refreshEnv()
                            }
                    }
                    settingField("Node 解释器") {
                        Text(model.env.nodePath)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .glassSurface(cornerRadius: 8, opacity: theme.opacity)
                    }
                    settingField("Python 解释器（venv）") {
                        Text(model.env.pythonPath)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .glassSurface(cornerRadius: 8, opacity: theme.opacity)
                    }
                }

                SectionTitle(text: "MCP 注册配置")
                Text(model.mcpConfigJSON)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .glassSurface(cornerRadius: 9, opacity: theme.opacity)

                HStack(spacing: 10) {
                    Button {
                        copyConfigToPasteboard()
                        uiState.copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            uiState.copied = false
                        }
                    } label: {
                        Label(uiState.copied ? "已复制" : "复制配置", systemImage: uiState.copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(GlassButtonStyle())
                    Button(action: openClaudeConfig) {
                        Label("打开 Claude Desktop 配置", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                .controlSize(.regular)

                SectionTitle(text: "启动行为")
                VStack(spacing: 0) {
                    toggleRow("开机自启", "登录时自动启动调试服务", $launchAtLogin)
                    Divider()
                    toggleRow("崩溃自动重启", "调试器或 MCP 意外退出后自动拉起", $autoRestart)
                    Divider()
                    toggleRow("日志落盘", "保存到 ~/Library/Logs/WMPLauncher/", $logToDisk)
                    Divider()
                    toggleRow("启动时打开 DevTools", "调试服务就绪后自动打开浏览器调试页", $openDevToolsOnStart)
                }
                .padding(.horizontal, 14)
                .glassSurface(cornerRadius: 12, opacity: theme.opacity)
                .padding(.bottom, 12)
            }
        }
    }

    private var glassAppearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("液态玻璃透明度", systemImage: "circle.lefthalf.filled")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                Text("\(theme.percentage)%")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.launcherSecondary)
            }
            Slider(value: $theme.opacity, in: 0...1.0, step: 0.01)
                .tint(.accentColor)
            Text("拖动滑块可实时调整侧边栏、卡片与玻璃表面的透明程度。")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
        }
        .padding(14)
        .glassPanel(cornerRadius: 12, opacity: theme.opacity)
        .padding(.bottom, 4)
    }

    private func settingField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.launcherSecondary)
            content()
        }
    }

    private func toggleRow(_ title: String, _ detail: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(.launcherText)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.accentColor)
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private func copyConfigToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.mcpConfigJSON, forType: .string)
    }

    private func openClaudeConfig() {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Claude")
        let file = dir.appendingPathComponent("claude_desktop_config.json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                try model.mcpConfigJSON.write(to: file, atomically: true, encoding: .utf8)
                model.logStore.append(.launcher, "已创建 Claude Desktop 配置文件：\(file.path)")
            }
            NSWorkspace.shared.open(file)
        } catch {
            model.logStore.append(.launcher, "打开 Claude Desktop 配置失败：\(error.localizedDescription)")
        }
    }
}

struct OverviewView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { OverviewView() }
    }
}

struct ServicesView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { ServicesView() }
    }
}

struct LogsView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { LogsView() }
    }
}

struct ToolsView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { ToolsView() }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { SettingsView() }
    }
}
