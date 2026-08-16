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

enum RuntimeCLI {
    static func scriptPath(projectRoot: String) -> String {
        (projectRoot as NSString)
            .appendingPathComponent("miniapp-reverse-mcp/run_runtime_cli.py")
    }

    static func run(
        pythonPath: String,
        scriptPath: String,
        projectRoot: String,
        arguments: [String]
    ) -> String {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.standardOutput = outPipe
        process.standardError = errPipe

        let group = DispatchGroup()
        let lock = NSLock()
        var outData = Data()
        var errData = Data()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outData.append(data)
            }
            lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errData.append(data)
            }
            lock.unlock()
        }

        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            group.leave()
            return "执行失败：\(error.localizedDescription)"
        }

        group.wait()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            return errText.isEmpty ? "命令退出码 \(process.terminationStatus)" : errText
        }
        return [outText, errText].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum RuntimeCommandRunner {
    static func call(
        model: AppModel,
        arguments: [String],
        completion: @escaping (String) -> Void
    ) {
        let pythonPath = model.env.pythonPath
        let script = RuntimeCLI.scriptPath(projectRoot: model.projectRoot)
        let projectRoot = model.projectRoot
        Task.detached(priority: .userInitiated) {
            let text = RuntimeCLI.run(
                pythonPath: pythonPath,
                scriptPath: script,
                projectRoot: projectRoot,
                arguments: arguments
            )
            await MainActor.run { completion(text) }
        }
    }
}

enum JSONText {
    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return "\(value)"
        }
        return String(data: data, encoding: .utf8) ?? "\(value)"
    }

    static func parseArray(_ text: String) -> [[String: Any]]? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return array
    }
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
    @StateObject private var wxapiState = WxApiCaptureState()

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
                    case .extraction: ExtractionView()
                    case .routes: RouteNavigationView()
                    case .cloud: CloudScanView()
                    case .wxapi: WxApiCaptureView(ui: wxapiState)
                    case .targets: TargetView()
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
        let pythonPath = model.env.pythonPath
        let script = RuntimeCLI.scriptPath(projectRoot: model.projectRoot)
        let projectRoot = model.projectRoot
        Task.detached(priority: .userInitiated) {
            let text = RuntimeCLI.run(
                pythonPath: pythonPath,
                scriptPath: script,
                projectRoot: projectRoot,
                arguments: ["route-config"]
            )
            await MainActor.run {
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

// MARK: - 提取扫描

struct ExtractionPackageFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int
}

struct ExtractionAppGroup: Identifiable {
    var id: String { appid }
    let appid: String
    let fileCount: Int
    let totalSize: Int
    let files: [ExtractionPackageFile]
}

final class ExtractionUIState: ObservableObject {
    @Published var packagesDir = ""
    @Published var outputDir = ""
    @Published var groups: [ExtractionAppGroup] = []
    @Published var loading = false
    @Published var busyAppID: String?
    @Published var currentAppID = ""
    @Published var currentAppName = ""
    @Published var currentTargetLoading = false
}

struct ExtractionView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = ExtractionUIState()
    private let currentTargetTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "反编译", subtitle: "直接调用本机 Python 脚本，按 AppID 管理小程序包的解包与敏感信息提取")

            LauncherCard {
                HStack(spacing: 10) {
                    pathField(
                        "包目录",
                        text: $ui.packagesDir,
                        prompt: "留空时自动检测"
                    )
                    .frame(maxWidth: 440)

                    Button("自动检测") {
                        ui.packagesDir = ""
                        refresh()
                    }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)

                    Button("选择") { choosePackagesDir() }
                        .buttonStyle(GlassButtonStyle())
                        .controlSize(.small)

                    Spacer()
                }

                HStack(spacing: 10) {
                    pathField(
                        "输出根目录",
                        text: $ui.outputDir,
                        prompt: "默认 analysis/<appid>"
                    )
                    .frame(maxWidth: 440)

                    Button("选择") { chooseOutputDir() }
                        .buttonStyle(GlassButtonStyle())
                        .controlSize(.small)

                    Button(ui.loading ? "读取中" : "刷新列表") {
                        refresh()
                    }
                    .buttonStyle(GlassButtonStyle(tint: .accentColor))
                    .controlSize(.small)
                    .disabled(ui.loading)

                    Spacer()
                }
            }

            HStack(spacing: 10) {
                SectionTitle(text: "已发现的小程序")
                Spacer()
                if ui.loading || ui.busyAppID != nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if ui.groups.isEmpty {
                Text(ui.loading ? "正在读取 wxapkg 目录…" : "还没有读取到小程序，请确认包目录后点击刷新列表。")
                    .font(.callout)
                    .foregroundColor(.launcherSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(sortedGroups) { group in
                            appGroupRow(group)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear {
            ui.packagesDir = UserDefaults.standard.string(forKey: "extractionPackagesDir") ?? ""
            ui.outputDir = UserDefaults.standard.string(forKey: "extractionOutputDir") ?? ""
            refresh()
            refreshCurrentTarget()
        }
        .onReceive(currentTargetTimer) { _ in
            refreshCurrentTarget()
        }
    }

    private func appGroupRow(_ group: ExtractionAppGroup) -> some View {
        LauncherCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(group.appid)
                            .font(.system(.headline, design: .monospaced))
                            .textSelection(.enabled)
                        if group.appid == ui.currentAppID {
                            StatusPill(text: "当前打开", color: .launcherGreen)
                        }
                    }
                    Text("\(group.fileCount) 个包 · \(formattedSize(group.totalSize))")
                        .font(.caption)
                        .foregroundColor(.launcherSecondary)
                    if group.appid == ui.currentAppID && !ui.currentAppName.isEmpty {
                        Text(ui.currentAppName)
                            .font(.caption)
                            .foregroundColor(.launcherGreen)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    actionButton("反编译", icon: "archivebox") {
                        runOperation(command: "extract", appid: group.appid)
                    }

                    actionButton("提取", icon: "magnifyingglass") {
                        runOperation(command: "extract-and-scan", appid: group.appid)
                    }

                    actionButton("查看", icon: "folder") {
                        openOutput(for: group.appid)
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(GlassButtonStyle(tint: .accentColor))
        .controlSize(.small)
        .disabled(ui.loading || ui.busyAppID != nil)
    }

    private func pathField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var scriptPath: String {
        (model.projectRoot as NSString)
            .appendingPathComponent("miniapp-reverse-mcp/run_extract_cli.py")
    }

    private func outputRoot(for appid: String) -> String {
        let base = ui.outputDir.isEmpty
            ? (model.projectRoot as NSString).appendingPathComponent("analysis")
            : ui.outputDir
        return (base as NSString).appendingPathComponent(appid)
    }

    private func reportPath(for appid: String) -> String {
        (outputRoot(for: appid) as NSString).appendingPathComponent("report/report.html")
    }

    private func decompilePath(for appid: String) -> String {
        (outputRoot(for: appid) as NSString).appendingPathComponent("decompiled")
    }

    private var sortedGroups: [ExtractionAppGroup] {
        guard !ui.currentAppID.isEmpty,
              let index = ui.groups.firstIndex(where: { $0.appid == ui.currentAppID }) else {
            return ui.groups
        }
        var groups = ui.groups
        let current = groups.remove(at: index)
        groups.insert(current, at: 0)
        return groups
    }

    private func refreshCurrentTarget() {
        guard !ui.currentTargetLoading else { return }
        ui.currentTargetLoading = true
        let pythonPath = model.env.pythonPath
        let script = RuntimeCLI.scriptPath(projectRoot: model.projectRoot)
        let projectRoot = model.projectRoot
        Task.detached(priority: .userInitiated) {
            let text = RuntimeCLI.run(
                pythonPath: pythonPath,
                scriptPath: script,
                projectRoot: projectRoot,
                arguments: ["route-config"]
            )
            await MainActor.run {
                ui.currentTargetLoading = false
                guard let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    ui.currentAppID = ""
                    ui.currentAppName = ""
                    return
                }
                ui.currentAppID = object["appid"] as? String ?? ""
                ui.currentAppName = object["name"] as? String ?? ""
            }
        }
    }

    private func refresh() {
        guard !ui.loading else { return }
        ui.loading = true
        let pythonPath = model.env.pythonPath
        let script = scriptPath
        let projectRoot = model.projectRoot
        let packagesDir = ui.packagesDir

        Task.detached(priority: .userInitiated) {
            var args = ["list"]
            if !packagesDir.isEmpty {
                args += ["--packages-dir", packagesDir]
            }
            let text = RuntimeCLI.run(pythonPath: pythonPath, scriptPath: script, projectRoot: projectRoot, arguments: args)
            await MainActor.run {
                ui.loading = false
                applyListResult(text)
            }
        }
    }

    private func runOperation(command: String, appid: String) {
        guard ui.busyAppID == nil else { return }
        ui.busyAppID = appid

        let pythonPath = model.env.pythonPath
        let script = scriptPath
        let projectRoot = model.projectRoot
        let packagesDir = ui.packagesDir
        let outputDir = outputRoot(for: appid)

        Task.detached(priority: .userInitiated) {
            var args = [command, "--appid", appid, "--output-dir", outputDir]
            if !packagesDir.isEmpty {
                args += ["--packages-dir", packagesDir]
            }
            let text = RuntimeCLI.run(pythonPath: pythonPath, scriptPath: script, projectRoot: projectRoot, arguments: args)
            await MainActor.run {
                ui.busyAppID = nil
                model.logStore.append(.launcher, text)
            }
        }
    }

    private func applyListResult(_ text: String) {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            model.logStore.append(.launcher, text.isEmpty ? "未读取到小程序列表。" : text)
            return
        }

        var groups: [ExtractionAppGroup] = []
        for item in raw {
            let appid = item["appid"] as? String ?? ""
            let fileCount = item["file_count"] as? Int ?? (item["file_count"] as? NSNumber)?.intValue ?? 0
            let totalSize = item["total_size"] as? Int ?? (item["total_size"] as? NSNumber)?.intValue ?? 0
            let rawFiles = item["files"] as? [[String: Any]] ?? []
            let files = rawFiles.compactMap { file -> ExtractionPackageFile? in
                guard let name = file["name"] as? String,
                      let path = file["path"] as? String else { return nil }
                let size = file["size"] as? Int ?? (file["size"] as? NSNumber)?.intValue ?? 0
                return ExtractionPackageFile(name: name, path: path, size: size)
            }
            groups.append(ExtractionAppGroup(
                appid: appid,
                fileCount: fileCount,
                totalSize: totalSize,
                files: files
            ))
        }
        ui.groups = groups
        model.logStore.append(.launcher, groups.isEmpty ? "没有找到小程序包。" : "已读取 \(groups.count) 个小程序。")
    }

    private func choosePackagesDir() {
        chooseDirectory(message: "选择 wxapkg 包目录") { url in
            ui.packagesDir = url.path
            UserDefaults.standard.set(url.path, forKey: "extractionPackagesDir")
            refresh()
        }
    }

    private func chooseOutputDir() {
        chooseDirectory(message: "选择输出根目录") { url in
            ui.outputDir = url.path
            UserDefaults.standard.set(url.path, forKey: "extractionOutputDir")
        }
    }

    private func chooseDirectory(message: String, onChoose: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            onChoose(url)
        }
    }

    private func openOutput(for appid: String) {
        let report = reportPath(for: appid)
        if FileManager.default.fileExists(atPath: report) {
            NSWorkspace.shared.open(URL(fileURLWithPath: report))
            return
        }

        let decompile = decompilePath(for: appid)
        if FileManager.default.fileExists(atPath: decompile) {
            NSWorkspace.shared.open(URL(fileURLWithPath: decompile))
            return
        }

        let root = outputRoot(for: appid)
        if FileManager.default.fileExists(atPath: root) {
            NSWorkspace.shared.open(URL(fileURLWithPath: root))
        } else {
            model.logStore.append(.launcher, "还没有生成 \(appid) 的解包或扫描报告，请先点击反编译或提取。")
        }
    }

    private func formattedSize(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

}

// MARK: - 路由导航

struct MiniappRouteConfig {
    var pages: [String] = []
    var tabBar: [String] = []
    var appid = ""
    var entry = ""
    var name = ""
    var current = ""
}

final class RouteNavigationState: ObservableObject {
    @Published var config = MiniappRouteConfig()
    @Published var selectedRoute = ""
    @Published var searchText = ""
    @Published var message = ""
    @Published var loading = false
    @Published var redirectGuardOn = false
}

struct RouteNavigationView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = RouteNavigationState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "路由导航", subtitle: "读取小程序页面配置，执行跳转、返回、刷新，并可开启防强制跳转")

            LauncherCard {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("小程序")
                            .font(.caption)
                            .foregroundColor(.launcherSecondary)
                        Text(ui.config.name.isEmpty ? "未读取" : ui.config.name)
                            .font(.headline)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("AppID")
                            .font(.caption)
                            .foregroundColor(.launcherSecondary)
                        Text(ui.config.appid.isEmpty ? "-" : ui.config.appid)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("入口页").font(.caption).foregroundColor(.launcherSecondary)
                        Text(ui.config.entry.isEmpty ? "-" : ui.config.entry)
                            .font(.system(.body, design: .monospaced))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("当前路由").font(.caption).foregroundColor(.launcherSecondary)
                        Text(ui.config.current.isEmpty ? "-" : ui.config.current)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        fetchConfig()
                    } label: {
                        Label(ui.loading ? "读取中" : "读取配置", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(GlassButtonStyle(tint: .accentColor))
                    .disabled(ui.loading)
                    Spacer()
                }
            }

            SectionTitle(text: "页面列表")
            HStack(spacing: 10) {
                TextField("搜索路由", text: $ui.searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if !ui.config.current.isEmpty {
                    Button("定位当前") {
                        ui.selectedRoute = ui.config.current
                    }
                    .buttonStyle(GlassButtonStyle())
                    .controlSize(.small)
                }
            }

            if filteredRoutes.isEmpty {
                Text(ui.loading ? "正在读取…" : "还没有读取到路由配置。")
                    .font(.callout)
                    .foregroundColor(.launcherSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220), spacing: 9)],
                        alignment: .leading,
                        spacing: 9
                    ) {
                        ForEach(filteredRoutes, id: \.self) { route in
                            routeButton(route)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            SectionTitle(text: "导航操作")
            HStack(spacing: 9) {
                actionButton("跳转", systemImage: "arrow.right") {
                    navigate("navigate", route: ui.selectedRoute)
                }
                actionButton("重启到页面", systemImage: "arrow.triangle.2.circlepath") {
                    navigate("relaunch", route: ui.selectedRoute)
                }
                actionButton("重定向", systemImage: "arrow.uturn.right") {
                    navigate("redirect", route: ui.selectedRoute)
                }
                actionButton("返回", systemImage: "chevron.left") {
                    navigate("back", route: nil)
                }
                actionButton("刷新", systemImage: "arrow.clockwise") {
                    navigate("refresh", route: nil)
                }
                Toggle(ui.redirectGuardOn ? "防跳转开" : "防跳转关", isOn: Binding(
                    get: { ui.redirectGuardOn },
                    set: { newValue in setRedirectGuard(newValue) }
                ))
                .toggleStyle(.switch)
                .fixedSize()
            }
            .controlSize(.small)

            if !ui.message.isEmpty {
                Text(ui.message)
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .onAppear { fetchConfig() }
    }

    private var filteredRoutes: [String] {
        let all = ui.config.pages
        guard !ui.searchText.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(ui.searchText) }
    }

    private func routeButton(_ route: String) -> some View {
        Button {
            ui.selectedRoute = route
            navigate("navigate", route: route)
        } label: {
            HStack {
                Text(route)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if ui.selectedRoute == route {
                    Image(systemName: "checkmark")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .glassEffect(
            ui.selectedRoute == route ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(GlassButtonStyle(tint: .accentColor))
        .disabled(ui.loading)
    }

    private func fetchConfig() {
        ui.loading = true
        RuntimeCommandRunner.call(model: model, arguments: ["route-config"]) { text in
            ui.loading = false
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                ui.message = text.isEmpty ? "未读取到配置。" : text
                return
            }
            var config = MiniappRouteConfig()
            config.pages = obj["pages"] as? [String] ?? []
            config.tabBar = obj["tabBar"] as? [String] ?? []
            config.appid = obj["appid"] as? String ?? ""
            config.entry = obj["entry"] as? String ?? ""
            config.name = obj["name"] as? String ?? ""
            config.current = obj["current"] as? String ?? ""
            ui.config = config
            ui.selectedRoute = config.current
            ui.message = "已读取 \(config.pages.count) 个页面。"
        }
    }

    private func navigate(_ action: String, route: String?) {
        var args = ["route", "--action", action]
        if let route, !route.isEmpty {
            args += ["--route", route]
        }
        ui.loading = true
        RuntimeCommandRunner.call(model: model, arguments: args) { text in
            ui.loading = false
            ui.message = text
        }
    }

    private func setRedirectGuard(_ enabled: Bool) {
        RuntimeCommandRunner.call(model: model, arguments: ["redirect-guard", "--enabled", enabled ? "true" : "false"]) { text in
            ui.redirectGuardOn = enabled
            ui.message = text
        }
    }

}

// MARK: - 云扫描

struct CapturedCallItem: Identifiable {
    let id = UUID()
    let raw: [String: Any]
    var name: String { raw["name"] as? String ?? "" }
    var type: String { raw["type"] as? String ?? "" }
    var appId: String { raw["appId"] as? String ?? "" }
    var status: String { raw["status"] as? String ?? "" }
    var timestamp: String { raw["timestamp"] as? String ?? "" }
}

struct CaptureCallRow: View {
    let call: CapturedCallItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                Text(call.name)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                Text("\(call.type) · \(call.status) · \(call.timestamp)")
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 7)
        )
    }
}

struct CloudStaticItem: Identifiable {
    let id = UUID()
    let raw: [String: Any]
    var name: String { raw["name"] as? String ?? "" }
    var type: String { raw["type"] as? String ?? "" }
    var appId: String { raw["appId"] as? String ?? "" }
    var count: Int { raw["count"] as? Int ?? (raw["count"] as? NSNumber)?.intValue ?? 0 }
    var params: [String] { raw["params"] as? [String] ?? [] }
}

final class CloudScanState: ObservableObject {
    @Published var captureActive = false
    @Published var loading = false
    @Published var calls: [CapturedCallItem] = []
    @Published var staticResults: [CloudStaticItem] = []
    @Published var selectedCallID: UUID?
    @Published var callName = ""
    @Published var callData = ""
    @Published var message = ""
}

struct CloudScanView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = CloudScanState()
    private let pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "云函数", subtitle: "Hook wx.cloud，捕获实际触发的云函数，并支持手动调用和静态扫描")

            LauncherCard {
                HStack(spacing: 10) {
                    Button(ui.captureActive ? "停止捕获" : "开始捕获") {
                        ui.captureActive ? stopCapture() : startCapture()
                    }
                    .buttonStyle(GlassButtonStyle(tint: ui.captureActive ? Color.launcherRed : Color.accentColor))

                    Button("清空记录") { clearCalls() }
                        .buttonStyle(GlassButtonStyle())

                    Button(ui.loading ? "扫描中" : "静态扫描") { staticScan() }
                        .buttonStyle(GlassButtonStyle())
                        .disabled(ui.loading)

                    Spacer()
                }
            }

            SectionTitle(text: "手动调用")
            LauncherCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("云函数名").font(.caption).foregroundColor(.launcherSecondary)
                        TextField("callFunction 名称", text: $ui.callName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("data JSON").font(.caption).foregroundColor(.launcherSecondary)
                        TextField("{\"key\":\"value\"}", text: $ui.callData)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    Button("调用") { manualCall() }
                        .buttonStyle(GlassButtonStyle(tint: .accentColor))
                        .disabled(ui.loading || ui.callName.isEmpty)
                }
            }

            SectionTitle(text: "捕获记录")
            HStack(spacing: 12) {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(ui.calls) { call in
                            CaptureCallRow(
                                call: call,
                                isSelected: ui.selectedCallID == call.id
                            ) {
                                ui.selectedCallID = call.id
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    Text("详情").font(.headline)
                    if let call = selectedCall {
                        ScrollView {
                            Text(JSONText.pretty(call.raw))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("选择左侧记录查看参数与返回结果。")
                            .font(.callout)
                            .foregroundColor(.launcherSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            SectionTitle(text: "静态扫描结果")
            if ui.staticResults.isEmpty {
                Text("还没有静态扫描结果。")
                    .font(.callout)
                    .foregroundColor(.launcherSecondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(ui.staticResults) { item in
                            staticRow(item)
                        }
                    }
                }
                .frame(minHeight: 110, maxHeight: 240)
            }

            if !ui.message.isEmpty {
                Text(ui.message)
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .onReceive(pollTimer) { _ in
            if ui.captureActive && !ui.loading {
                pollCalls()
            }
        }
        .onDisappear {
            if ui.captureActive {
                stopCapture()
            }
        }
        .onAppear {
            if ui.captureActive {
                pollCalls()
            }
        }
    }

    private var selectedCall: CapturedCallItem? {
        guard let id = ui.selectedCallID else { return nil }
        return ui.calls.first { $0.id == id }
    }



    private func startCapture() {
        RuntimeCommandRunner.call(model: model, arguments: ["cloud-start"]) { text in
            ui.captureActive = true
            ui.message = text
            pollCalls()
        }
    }

    private func stopCapture() {
        RuntimeCommandRunner.call(model: model, arguments: ["cloud-stop"]) { text in
            ui.captureActive = false
            ui.message = text
        }
    }

    private func pollCalls() {
        guard !ui.loading else { return }
        ui.loading = true
        RuntimeCommandRunner.call(model: model, arguments: ["cloud-poll"]) { text in
            ui.loading = false
            guard let data = text.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }
            let newCalls = array.map { CapturedCallItem(raw: $0) }
            if !newCalls.isEmpty {
                ui.calls.insert(contentsOf: newCalls.reversed(), at: 0)
            }
        }
    }

    private func clearCalls() {
        RuntimeCommandRunner.call(model: model, arguments: ["cloud-clear"]) { text in
            ui.calls.removeAll()
            ui.selectedCallID = nil
            ui.message = text
        }
    }

    private func staticScan() {
        ui.loading = true
        RuntimeCommandRunner.call(model: model, arguments: ["cloud-static-scan"]) { text in
            ui.loading = false
            guard let data = text.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                ui.message = text.isEmpty ? "静态扫描未返回结果。" : text
                return
            }
            ui.staticResults = array.map { CloudStaticItem(raw: $0) }
            ui.message = "静态扫描完成，发现 \(array.count) 个云函数引用。"
        }
    }

    private func staticRow(_ item: CloudStaticItem) -> some View {
        LauncherCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                    Text("\(item.type) · \(item.count) 次")
                        .font(.caption)
                        .foregroundColor(.launcherSecondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    if item.params.isEmpty {
                        Text("无参数")
                            .font(.caption)
                            .foregroundColor(.launcherSecondary)
                    } else {
                        ForEach(item.params.prefix(8), id: \.self) { param in
                            Text(param)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.10), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                        }
                    }
                }
            }
        }
    }

    private func manualCall() {
        var args = ["cloud-call", "--name", ui.callName]
        if !ui.callData.isEmpty {
            args += ["--data-json", ui.callData]
        }
        RuntimeCommandRunner.call(model: model, arguments: args) { text in
            ui.message = text
        }
    }

}

// MARK: - WxAPI捕获

final class WxApiCaptureState: ObservableObject {
    @Published var captureActive = false
    @Published var loading = false
    @Published var calls: [CapturedCallItem] = []
    @Published var selectedCallID: UUID?
    @Published var message = ""
    @Published var filterText = ""
    @Published var hiddenTypes: Set<String> = []
    @Published var showFilter = false
}

struct WxApiCaptureView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var ui: WxApiCaptureState
    private let pollTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "接口抓包", subtitle: "Hook wx API，捕获登录、请求、缓存、导航、支付等调用")

            LauncherCard {
                HStack(spacing: 10) {
                    Button(ui.captureActive ? "停止捕获" : "开始捕获") {
                        ui.captureActive ? stopCapture() : startCapture()
                    }
                    .buttonStyle(GlassButtonStyle(tint: ui.captureActive ? Color.launcherRed : Color.accentColor))

                    Button("清空记录") { clearCalls() }
                        .buttonStyle(GlassButtonStyle())

                    Button("重放选中") { replaySelected() }
                        .buttonStyle(GlassButtonStyle())
                        .disabled(ui.selectedCallID == nil)

                    Button("过滤") { ui.showFilter.toggle() }
                        .buttonStyle(GlassButtonStyle())
                        .popover(isPresented: $ui.showFilter) {
                            filterPanel
                        }

                    Spacer()
                }
            }

            SectionTitle(text: "捕获记录")
            HStack(spacing: 10) {
                TextField("搜索 API 名称或类型", text: $ui.filterText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if !ui.filterText.isEmpty {
                    Button("清除") { ui.filterText = "" }
                        .buttonStyle(GlassButtonStyle())
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(displayCalls) { call in
                            CaptureCallRow(
                                call: call,
                                isSelected: ui.selectedCallID == call.id
                            ) {
                                ui.selectedCallID = call.id
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    Text("详情").font(.headline)
                    if let call = selectedCall {
                        ScrollView {
                            Text(JSONText.pretty(call.raw))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("选择左侧记录查看请求参数与返回结果。")
                            .font(.callout)
                            .foregroundColor(.launcherSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            if !ui.message.isEmpty {
                Text(ui.message)
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .onReceive(pollTimer) { _ in
            if ui.captureActive && !ui.loading {
                pollCalls()
            }
        }
        .onAppear {
            if ui.captureActive {
                pollCalls()
            }
        }
    }

    private var displayCalls: [CapturedCallItem] {
        let query = ui.filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ui.calls.filter { call in
            if ui.hiddenTypes.contains(call.type) { return false }
            if query.isEmpty { return true }
            return call.name.lowercased().contains(query) || call.type.lowercased().contains(query)
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("隐藏不需要的数据类型")
                .font(.headline)
            ForEach(Self.filterTypes, id: \.self) { type in
                Toggle(type, isOn: Binding(
                    get: { ui.hiddenTypes.contains(type) },
                    set: { hidden in
                        if hidden { ui.hiddenTypes.insert(type) } else { ui.hiddenTypes.remove(type) }
                    }
                ))
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    private static let filterTypes = [
        "auth", "request", "storage", "share", "location",
        "device", "nav", "media", "clipboard", "pay"
    ]

    private var selectedCall: CapturedCallItem? {
        guard let id = ui.selectedCallID else { return nil }
        return ui.calls.first { $0.id == id }
    }



    private func startCapture() {
        RuntimeCommandRunner.call(model: model, arguments: ["wxapi-start"]) { text in
            if text.contains("RUNTIME_ERROR") || text.contains("Timed out connecting") {
                ui.captureActive = false
                ui.message = "调试服务未启动或小程序未打开，无法开始 WxAPI 捕获。"
                return
            }
            ui.captureActive = true
            ui.message = text
            pollCalls()
        }
    }

    private func stopCapture() {
        RuntimeCommandRunner.call(model: model, arguments: ["wxapi-stop"]) { text in
            ui.captureActive = false
            ui.message = text
        }
    }

    private func pollCalls() {
        guard !ui.loading else { return }
        ui.loading = true
        RuntimeCommandRunner.call(model: model, arguments: ["wxapi-poll"]) { text in
            ui.loading = false
            if text.contains("RUNTIME_ERROR") || text.contains("Timed out connecting") {
                ui.captureActive = false
                ui.message = "调试服务未启动或小程序未打开，无法拉取 WxAPI 数据。"
                return
            }
            guard let array = JSONText.parseArray(text) else {
                ui.message = "捕获数据解析失败，请查看日志。"
                model.logStore.append(.launcher, "WxAPI 捕获解析失败：\(text.prefix(300))")
                return
            }
            ui.calls = array.reversed().map { CapturedCallItem(raw: $0) }
            if !ui.calls.isEmpty {
                ui.message = "已显示 \(ui.calls.count) 条捕获记录。"
            }
        }
    }

    private func clearCalls() {
        RuntimeCommandRunner.call(model: model, arguments: ["wxapi-clear"]) { text in
            ui.calls.removeAll()
            ui.selectedCallID = nil
            ui.message = text
        }
    }

    private func replaySelected() {
        guard let call = selectedCall else { return }
        let dataJSON = JSONText.pretty(call.raw["data"] ?? [:])
        var args = ["wxapi-replay", "--name", call.name]
        if !dataJSON.isEmpty, dataJSON != "{}" {
            args += ["--data-json", dataJSON]
        }
        RuntimeCommandRunner.call(model: model, arguments: args) { text in
            ui.message = text
        }
    }



}

// MARK: - 服务目标

struct TargetItem: Identifiable {
    let id = UUID()
    let targetID: String
    let targetType: String
    let title: String
    let url: String
    let attached: Bool
    let selected: Bool
}

final class TargetViewState: ObservableObject {
    @Published var targets: [TargetItem] = []
    @Published var selectedTargetID: String?
    @Published var loading = false
    @Published var message = ""
}

struct TargetView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var ui = TargetViewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "服务目标", subtitle: "查看当前 CDP 中的小程序 target，并切换调试目标")

            LauncherCard {
                HStack {
                    Button(ui.loading ? "读取中" : "刷新目标") { fetchTargets() }
                        .buttonStyle(GlassButtonStyle(tint: .accentColor))
                        .disabled(ui.loading)
                    Spacer()
                    if ui.loading { ProgressView().controlSize(.small) }
                }
            }

            SectionTitle(text: "Target 列表")
            if ui.targets.isEmpty {
                Text(ui.loading ? "正在读取 target…" : "还没有读取到 target。")
                    .font(.callout)
                    .foregroundColor(.launcherSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(ui.targets) { target in
                            targetRow(target)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }

            if !ui.message.isEmpty {
                Text(ui.message)
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .onAppear { fetchTargets() }
    }

    private func targetRow(_ target: TargetItem) -> some View {
        LauncherCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(target.title.isEmpty ? target.targetType : target.title)
                            .font(.system(.subheadline, design: .monospaced))
                        if target.selected {
                            StatusPill(text: "当前", color: .launcherGreen)
                        }
                        if target.attached {
                            StatusPill(text: "已附加", color: .launcherBlue)
                        }
                    }
                    Text(target.targetID)
                        .font(.caption)
                        .foregroundColor(.launcherSecondary)
                        .textSelection(.enabled)
                    Text(target.url)
                        .font(.caption)
                        .foregroundColor(.launcherSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("切换") { switchTarget(target) }
                    .buttonStyle(GlassButtonStyle(tint: .accentColor))
                    .disabled(ui.loading)
            }
        }
    }

    private func fetchTargets() {
        guard !ui.loading else { return }
        ui.loading = true
        RuntimeCommandRunner.call(model: model, arguments: ["targets-json"]) { text in
            ui.loading = false
            guard let data = text.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                ui.message = text.isEmpty ? "未读取到 target。" : text
                return
            }
            ui.targets = array.map { item in
                TargetItem(
                    targetID: item["target_id"] as? String ?? "",
                    targetType: item["target_type"] as? String ?? "",
                    title: item["title"] as? String ?? "",
                    url: item["url"] as? String ?? "",
                    attached: item["attached"] as? Bool ?? false,
                    selected: item["selected"] as? Bool ?? false
                )
            }
        }
    }

    private func switchTarget(_ target: TargetItem) {
        ui.loading = true
        RuntimeCommandRunner.call(model: model, arguments: ["target-attach", "--target-id", target.targetID]) { text in
            ui.loading = false
            ui.message = text
            fetchTargets()
        }
    }

}

// MARK: - 工具

struct ToolsView: View {
    @StateObject private var selection = ToolsSelection()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "MCP 工具", subtitle: "共 \(ToolCatalog.all.count) 个工具，按领域分组，点击查看说明与常用参数")

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
