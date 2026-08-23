import SwiftUI
import AppKit

final class ToolsSelection: ObservableObject {
    @Published var selectedTool: ToolInfo?
}

final class SettingsUIState: ObservableObject {
    @Published var copied = false
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
                            .onChange(of: model.projectRoot) { _, newValue in
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
                    toggleRow("开机自启", "登录时自动启动调试服务", launchAtLoginBinding)
                    Divider()
                    toggleRow("崩溃自动重启", "调试器或 MCP 意外退出后自动拉起", $autoRestart)
                    Divider()
                    toggleRow("日志落盘", "保存到 ~/Library/Logs/WMPLauncher/", $logToDisk)
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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                if model.setLaunchAtLogin(enabled) {
                    launchAtLogin = enabled
                }
            }
        )
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
