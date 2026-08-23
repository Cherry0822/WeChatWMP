import Foundation
import Combine
import AppKit
import ServiceManagement

final class AppModel: ObservableObject {
    @Published var tab: LauncherTab = .overview
    @Published var env = EnvironmentSnapshot()
    @Published var projectRoot: String
    @Published var debugger: DebuggerService
    @Published var mcp: MCPClient
    @Published var isCheckingEnvironment = false
    @Published var installMessage = ""
    let logStore = LogStore()

    init() {
        projectRoot = UserDefaults.standard.string(forKey: "projectRoot") ?? Self.defaultProjectRoot()
        let debuggerService = DebuggerService()
        let mcpClient = MCPClient()
        _debugger = Published(initialValue: debuggerService)
        _mcp = Published(initialValue: mcpClient)

        debuggerService.onLog = { [weak self] text in
            self?.logStore.append(.debugger, text)
        }
        debuggerService.onUnexpectedTermination = { [weak self] in
            self?.restartDebuggerAfterUnexpectedTermination()
        }
        mcpClient.onLog = { [weak self] text in
            self?.logStore.append(.mcp, text)
        }
        mcpClient.onUnexpectedTermination = { [weak self] in
            self?.restartMCPAfterUnexpectedTermination()
        }
    }

    static func defaultProjectRoot() -> String {
        let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        let debuggerPath = (bundleDir as NSString).appendingPathComponent("WMPFDebugger-mac")
        if FileManager.default.fileExists(atPath: debuggerPath) {
            return bundleDir
        }
        return "/Users/cherry/Desktop/WMP"
    }

    func bootstrap() {
        refreshEnv()
    }

    static func openDevTools() {
        guard let url = URL(string: "devtools://devtools/bundled/inspector.html?ws=127.0.0.1:62000") else { return }

        let candidates = [
            ("com.google.Chrome", "Google Chrome"),
            ("com.microsoft.edgemac", "Microsoft Edge"),
            ("org.chromium.Chromium", "Chromium")
        ]

        for (bundleID, _) in candidates {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                return
            }
        }

        if NSWorkspace.shared.open(url) {
            return
        }

        let alert = NSAlert()
        alert.messageText = "未找到可用的浏览器"
        alert.informativeText = "打开 DevTools 需要基于 Chromium 的浏览器（Chrome / Edge / Chromium），请先安装后重试。"
        alert.alertStyle = .warning
        alert.runModal()
    }

    func refreshEnv() {
        env = EnvChecker.snapshot(projectRoot: projectRoot)
    }

    @MainActor
    func checkAndInstallEnvironment() async {
        guard !isCheckingEnvironment else { return }
        isCheckingEnvironment = true
        installMessage = "正在检测环境…"
        logStore.append(.launcher, "开始检测环境")
        refreshEnv()
        do {
            let report = try await EnvironmentInstaller.ensureAll(projectRoot: projectRoot) { [weak self] line in
                Task { @MainActor in
                    self?.installMessage = line
                    self?.logStore.append(.launcher, line)
                }
            }
            refreshEnv()
            let message = report.installedAny
                ? "环境安装完成，所有依赖已就绪"
                : "环境检查完成，全部依赖已就绪"
            installMessage = message
            logStore.append(.launcher, message)
        } catch {
            installMessage = "环境安装失败：\(error.localizedDescription)"
            logStore.append(.launcher, "环境安装失败：\(error.localizedDescription)")
        }
        isCheckingEnvironment = false
    }

    func startDebugger() {
        logStore.append(.launcher, "请求启动调试器")
        let conflicts = PortChecker.conflicts(ports: [9421, 62000])
        if !conflicts.isEmpty {
            let detail = conflicts.map { conflict -> String in
                let names = conflict.occupants
                    .map { "\($0.name)(PID \($0.pid))" }
                    .joined(separator: ", ")
                return "端口 \(conflict.port) 被 \(names) 占用"
            }.joined(separator: "；")

            let alert = NSAlert()
            alert.messageText = "调试端口被占用"
            alert.informativeText = "\(detail)。是否结束占用进程并重新启动调试器？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "释放端口并启动")
            alert.addButton(withTitle: "直接启动")
            alert.addButton(withTitle: "取消")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                for conflict in conflicts {
                    PortChecker.release(conflict)
                    logStore.append(.launcher, "已释放端口 \(conflict.port) 的占用进程")
                }
            case .alertSecondButtonReturn:
                break
            default:
                logStore.append(.launcher, "已取消启动调试器（端口被占用）")
                return
            }
        }
        debugger.start(projectRoot: projectRoot, nodePath: env.nodePath)
    }

    func stopDebugger() {
        logStore.append(.launcher, "请求关闭调试器")
        debugger.stop()
    }

    func restartDebugger() {
        logStore.append(.launcher, "请求重启调试器")
        debugger.restart(projectRoot: projectRoot, nodePath: env.nodePath)
    }

    func startMCP() {
        logStore.append(.launcher, "请求启动 MCP 服务")
        Task {
            do {
                try await mcp.start(projectRoot: projectRoot, pythonPath: env.pythonPath)
            } catch {
                // 状态已在 MCPClient 中记录
            }
        }
    }

    func stopMCP() {
        logStore.append(.launcher, "请求关闭 MCP 服务")
        mcp.stop()
    }

    func restartMCP() {
        logStore.append(.launcher, "请求重启 MCP 服务")
        mcp.stop { [weak self] in
            self?.startMCP()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else {
            logStore.append(.launcher, "当前 macOS 版本不支持开机自启")
            return false
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logStore.append(.launcher, "已启用开机自启")
            } else {
                try SMAppService.mainApp.unregister()
                logStore.append(.launcher, "已关闭开机自启")
            }
            return true
        } catch {
            logStore.append(.launcher, "更新开机自启失败：\(error.localizedDescription)")
            return false
        }
    }

    private func restartDebuggerAfterUnexpectedTermination() {
        guard Self.setting("autoRestart", default: true) else { return }
        logStore.append(.launcher, "调试器异常退出，1 秒后自动重启")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, isRestartable(self.debugger.state) else { return }
            self.startDebugger()
        }
    }

    private func restartMCPAfterUnexpectedTermination() {
        guard Self.setting("autoRestart", default: true) else { return }
        logStore.append(.launcher, "MCP 服务异常退出，1 秒后自动重启")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, isRestartable(self.mcp.state) else { return }
            self.startMCP()
        }
    }

    private func isRestartable(_ state: ServiceState) -> Bool {
        switch state {
        case .stopped, .failed:
            return true
        case .starting, .stopping, .running:
            return false
        }
    }

    private static func setting(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    var combinedLog: String {
        debugger.log + "\n" + mcp.log
    }

    var mcpConfigJSON: String {
        let pythonPath = env.pythonPath
        let runPath = (projectRoot as NSString)
            .appendingPathComponent("miniapp-reverse-mcp/run_mcp_server.py")
        let cwd = (projectRoot as NSString).appendingPathComponent("miniapp-reverse-mcp")
        let config: [String: Any] = [
            "mcpServers": [
                "miniapp-reverse-mcp": [
                    "command": pythonPath,
                    "args": [runPath],
                    "cwd": cwd,
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
