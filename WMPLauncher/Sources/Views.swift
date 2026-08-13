import SwiftUI
import AppKit

final class ToolsSelection: ObservableObject {
    @Published var selectedTool: ToolInfo?
}

final class SettingsUIState: ObservableObject {
    @Published var copied = false
}

// MARK: - 颜色与小组件

extension Color {
    static let launcherPanel = Color(nsColor: .controlBackgroundColor)
    static let launcherPanelAlt = Color(nsColor: .underPageBackgroundColor)
    static let launcherSeparator = Color(nsColor: .separatorColor)
    static let launcherText = Color(nsColor: .textColor)
    static let launcherSecondary = Color(nsColor: .secondaryLabelColor)
    static let launcherGreen = Color(nsColor: .systemGreen)
    static let launcherOrange = Color(nsColor: .systemOrange)
    static let launcherRed = Color(nsColor: .systemRed)
    static let launcherBlue = Color.accentColor
}

struct StatusPill: View {
    let text: String
    var color: Color = .launcherSecondary

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
        }
        .foregroundColor(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct LauncherCard<Content: View>: View {
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
        .background(Color.launcherPanel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.launcherSeparator, lineWidth: 1)
        )
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
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 190)
            Divider()
            Group {
                switch model.tab {
                case .overview: OverviewView()
                case .services: ServicesView()
                case .logs: LogsView()
                case .versions: VersionsView()
                case .workflow: WorkflowView()
                case .tools: ToolsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(22)
        }
        .frame(minWidth: 960, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            model.bootstrap()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(LauncherTab.allCases) { tab in
                Button {
                    model.tab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.icon)
                            .frame(width: 18)
                        Text(tab.title)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(model.tab == tab ? Color.accentColor : .primary)
                .background(
                    model.tab == tab
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
            Spacer()
            Text("v0.1.0 · GPL-2.0")
                .font(.caption2)
                .foregroundColor(.launcherSecondary)
                .padding(8)
        }
        .padding(10)
        .background(Color.launcherPanelAlt)
    }
}

// MARK: - 概览

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var debugger: DebuggerService
    @EnvironmentObject private var mcp: MCPClient

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "概览", subtitle: "调试服务与 MCP 服务的一体化状态")

                LazyVGrid(columns: columns, spacing: 12) {
                    debuggerCard
                    mcpCard
                    targetCard
                    envCard
                }

                SectionTitle(text: "环境检查")
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
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isCheckingEnvironment)

                    if model.isCheckingEnvironment {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if !model.installMessage.isEmpty {
                        Text(model.installMessage)
                            .font(.caption)
                            .foregroundColor(.launcherSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 10)

                VStack(spacing: 8) {
                    ForEach(model.env.checks) { item in
                        EnvRow(item: item) {
                            model.tab = .services
                        }
                    }
                }

                SectionTitle(text: "快捷操作")
                HStack(spacing: 10) {
                    Button(action: model.startDebugger) {
                        Label("启动调试器", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(debugger.state.isRunning || debugger.state.isBusy)

                    Button(action: model.startMCP) {
                        Label("启动 MCP", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(mcp.state.isRunning || mcp.state.isBusy)

                    Button(action: AppModel.openDevTools) {
                        Label("打开 DevTools", systemImage: "arrow.up.right.square")
                    }

                    Button(action: copyMCPConfig) {
                        Label("复制 MCP 配置", systemImage: "doc.on.doc")
                    }
                }
                .controlSize(.regular)
                .padding(.bottom, 10)
            }
        }
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
                Button("打开 DevTools", action: AppModel.openDevTools).controlSize(.small)
                Button(debugger.state.isRunning ? "关闭" : "启动",
                       action: debugger.state.isRunning ? model.stopDebugger : model.startDebugger)
                    .controlSize(.small)
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
                Button("复制配置", action: copyMCPConfig).controlSize(.small)
                Button(mcp.state.isRunning ? "停止" : "启动", action: mcp.state.isRunning ? model.stopMCP : model.startMCP)
                    .controlSize(.small)
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
            Button("查看 Target", action: { model.tab = .workflow })
                .controlSize(.small)
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
                .controlSize(.small)
                .disabled(model.isCheckingEnvironment)
                Button("查看详情", action: { model.tab = .services })
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

struct EnvRow: View {
    let item: EnvCheckItem
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.medium)
                Text(item.detail).font(.caption).foregroundColor(.launcherSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.launcherPanel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.launcherSeparator, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
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
        .background(Color.launcherPanel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.launcherSeparator, lineWidth: 1))
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

                SectionTitle(text: "环境检查详情")
                HStack {
                    Text("共 \(model.env.checks.count) 项 · \(model.env.failCount) 项失败 · \(model.env.warnCount) 项警告")
                        .font(.caption)
                        .foregroundColor(.launcherSecondary)
                    Spacer(minLength: 0)
                    Button("刷新") {
                        model.refreshEnv()
                    }
                    .controlSize(.small)
                }
                .padding(.bottom, 8)

                VStack(spacing: 8) {
                    ForEach(model.env.checks) { item in
                        EnvDetailRow(item: item)
                    }
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
                    .disabled(debugger.state.isBusy)
                Button("关闭", role: .destructive, action: model.stopDebugger)
                    .disabled(!debugger.state.isRunning || debugger.state.isBusy)
                Button("打开 DevTools", action: AppModel.openDevTools)
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
                    .disabled(mcp.state.isBusy)
                Button("关闭", role: .destructive, action: model.stopMCP)
                    .disabled(!mcp.state.isRunning || mcp.state.isBusy)
                Button("复制注册配置", action: copyConfig)
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

struct LogView: View {
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
            .background(Color.launcherPanelAlt, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.launcherSeparator, lineWidth: 1))
            .onChange(of: text) { _ in
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
    }
}

final class LogsViewState: ObservableObject {
    @Published var filter: LogStore.Source = .all
}

struct LogsView: View {
    @EnvironmentObject private var logStore: LogStore
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
                Picker("来源", selection: $state.filter) {
                    ForEach(LogStore.Source.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)

                Spacer(minLength: 0)

                Button {
                    copyLog()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    logStore.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                }
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
                .background(Color.launcherPanelAlt, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.launcherSeparator, lineWidth: 1))
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

// MARK: - 工作流

struct WorkflowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var mcp: MCPClient
    @EnvironmentObject private var workflow: WorkflowEngine

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                ForEach(WorkflowStep.allCases) { step in
                    StepRow(step: step)
                }
                Button {
                    workflow.reset()
                } label: {
                    Label("重置流程", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
            }
            .frame(width: 320)

            detailCard
        }
    }

    private var detailCard: some View {
        LauncherCard {
            HStack {
                Text("\(workflow.currentStep.rawValue + 1). \(workflow.currentStep.title)")
                    .font(.headline)
                Spacer()
                if workflow.isDone {
                    StatusPill(text: "完成", color: .launcherGreen)
                } else if workflow.busy {
                    StatusPill(text: "执行中…", color: .launcherOrange)
                } else {
                    StatusPill(text: "步骤 \(workflow.currentStep.rawValue + 1) / \(WorkflowStep.allCases.count)")
                }
            }

            Text("工具调用")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            Text(workflow.currentStep.toolCall)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.launcherPanelAlt, in: RoundedRectangle(cornerRadius: 8))

            stepControls

            if let error = workflow.lastError {
                Text("错误：\(error)")
                    .font(.caption)
                    .foregroundColor(.launcherRed)
            }

            Text("结果预览")
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            ScrollView {
                Text(workflow.detailResult.isEmpty ? "（尚未执行）" : workflow.detailResult)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 300)
            .background(Color.launcherPanelAlt, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.launcherSeparator, lineWidth: 1))

            if !mcp.state.isRunning {
                Label("MCP 服务未运行，请先到「服务」页启动", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.launcherOrange)
            }
        }
    }

    @ViewBuilder
    private var stepControls: some View {
        switch workflow.currentStep {
        case .clear:
            Button {
                Task { await workflow.runCurrentStep() }
            } label: {
                Label("清空记录", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!mcp.state.isRunning || workflow.busy)
        case .capture:
            VStack(alignment: .leading, spacing: 8) {
                Stepper(value: $workflow.captureWaitSeconds, in: 0...10, step: 1) {
                    Text("等待 \(workflow.captureWaitSeconds) 秒后查询")
                }
                Text("提示：点击下方按钮后，请在小程序里触发要抓包的操作。")
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                HStack {
                    Button {
                        Task { await workflow.runCurrentStep() }
                    } label: {
                        Label("开始抓包（等待后查询）", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Task { await workflow.captureNow() }
                    } label: {
                        Label("立即抓取", systemImage: "arrow.clockwise")
                    }
                }
            }
            .disabled(!mcp.state.isRunning || workflow.busy)
        case .trace:
            VStack(alignment: .leading, spacing: 8) {
                TextField("请求 ID（reqid）", text: $workflow.selectedRequestID)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await workflow.runCurrentStep() }
                } label: {
                    Label("溯源", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(!mcp.state.isRunning || workflow.busy)
        case .source:
            VStack(alignment: .leading, spacing: 8) {
                TextField("脚本 URL", text: $workflow.selectedScriptURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        Task { await workflow.listScripts() }
                    } label: {
                        Label("列出脚本", systemImage: "list.bullet")
                    }
                    Button {
                        Task { await workflow.runCurrentStep() }
                    } label: {
                        Label("读取源码（1-80 行）", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .disabled(!mcp.state.isRunning || workflow.busy)
        case .breakpoint:
            VStack(alignment: .leading, spacing: 8) {
                TextField("断点文本（函数体内部的语句）", text: $workflow.breakpointText)
                    .textFieldStyle(.roundedBorder)
                Text("不要设在函数名或 `xxx = function` 赋值处，压缩代码里那只是一次性赋值。")
                    .font(.caption)
                    .foregroundColor(.launcherOrange)
                Button {
                    Task { await workflow.runCurrentStep() }
                } label: {
                    Label("设置断点", systemImage: "ladybug")
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(!mcp.state.isRunning || workflow.busy)
        case .paused:
            Button {
                Task { await workflow.runCurrentStep() }
            } label: {
                Label("查看暂停状态", systemImage: "pause.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!mcp.state.isRunning || workflow.busy)
        case .cleanup:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { Task { await workflow.step("over") } } label: { Text("单步 over") }
                    Button { Task { await workflow.step("into") } } label: { Text("单步 into") }
                    Button { Task { await workflow.step("out") } } label: { Text("单步 out") }
                }
                Button {
                    Task { await workflow.resume() }
                } label: {
                    Label("恢复执行", systemImage: "play")
                }
                Button {
                    Task { await workflow.runCurrentStep() }
                } label: {
                    Label("清理全部断点并完成", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(!mcp.state.isRunning || workflow.busy)
        }
    }
}

struct StepRow: View {
    @EnvironmentObject private var workflow: WorkflowEngine
    let step: WorkflowStep

    var body: some View {
        Button {
            workflow.select(step)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(circleColor)
                        .frame(width: 26, height: 26)
                    Text("\(step.rawValue + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(circleForeground)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title).font(.subheadline).fontWeight(.medium)
                    Text(step.subtitle)
                        .font(.caption2)
                        .foregroundColor(.launcherSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? Color.accentColor : Color.launcherSeparator, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private var isActive: Bool { workflow.currentStep == step }
    private var isDone: Bool { workflow.doneSteps.contains(step.rawValue) }

    private var circleColor: Color {
        if isDone { return .launcherGreen }
        if isActive { return .accentColor }
        return Color.launcherPanelAlt
    }

    private var circleForeground: Color {
        if isDone || isActive { return .white }
        return .launcherSecondary
    }

    private var statusIcon: String {
        if isDone { return "checkmark.circle.fill" }
        if isActive { return "circle.dotted" }
        return "circle"
    }

    private var statusColor: Color {
        if isDone { return .launcherGreen }
        if isActive { return .accentColor }
        return .launcherSecondary
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
                                        selection.selectedTool = tool
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
                                        .background(Color.launcherPanelAlt, in: Capsule())
                                        .overlay(Capsule().stroke(Color.launcherSeparator, lineWidth: 1))
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
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.15) : Color.launcherPanel,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.launcherSeparator, lineWidth: isSelected ? 1.5 : 1)
        )
        .foregroundColor(isSelected ? Color.accentColor : .primary)
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var uiState = SettingsUIState()

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoRestart") private var autoRestart = true
    @AppStorage("logToDisk") private var logToDisk = false
    @AppStorage("openDevToolsOnStart") private var openDevToolsOnStart = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "设置", subtitle: "项目路径、MCP 注册与启动行为")

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
                            .background(Color.launcherPanelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                    settingField("Python 解释器（venv）") {
                        Text(model.env.pythonPath)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(Color.launcherPanelAlt, in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                SectionTitle(text: "MCP 注册配置")
                Text(model.mcpConfigJSON)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.launcherPanelAlt, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.launcherSeparator, lineWidth: 1))

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
                    Button(action: openClaudeConfig) {
                        Label("打开 Claude Desktop 配置", systemImage: "arrow.up.right.square")
                    }
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
                .background(Color.launcherPanel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.launcherSeparator, lineWidth: 1))
                .padding(.bottom, 12)
            }
        }
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
