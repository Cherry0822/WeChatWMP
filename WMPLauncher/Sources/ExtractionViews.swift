import SwiftUI
import AppKit
import Combine

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
        RuntimeCommandRunner.call(model: model, arguments: ["route-config"]) { text in
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
