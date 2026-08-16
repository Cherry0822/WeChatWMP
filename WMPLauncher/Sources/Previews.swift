import SwiftUI

// MARK: - SwiftUI 预览支持
// 在 Xcode 中打开 WMPLauncher.xcodeproj 后，可在 Canvas 中预览每个页面，
// 无需启动完整 App（不会启动调试器 / MCP 进程）。
// 这里使用 PreviewProvider 而不是 #Preview，是为了同时兼容命令行 swift build。

/// 统一预览容器：提供深色液态玻璃背景与全部 EnvironmentObject。
struct PreviewRoot<Content: View>: View {
    @StateObject private var model = AppModel()
    @StateObject private var theme = GlassTheme()

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            CelosiaBackground()
            content
                .padding(22)
        }
        .frame(width: 900, height: 640)
        .preferredColorScheme(.dark)
        .environmentObject(model)
        .environmentObject(model.debugger)
        .environmentObject(model.mcp)
        .environmentObject(model.logStore)
        .environmentObject(theme)
    }
}

/// 完整应用预览：使用更大窗口尺寸。
struct FullPreviewRoot: View {
    @StateObject private var model = AppModel()
    @StateObject private var theme = GlassTheme()

    var body: some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(model.debugger)
            .environmentObject(model.mcp)
            .environmentObject(model.logStore)
            .environmentObject(theme)
            .frame(width: 1080, height: 720)
    }
}

struct Overview_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { OverviewView() }
    }
}

struct Services_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { ServicesView() }
    }
}

struct Logs_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { LogsView() }
    }
}

struct Versions_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { VersionsView() }
    }
}

struct Extraction_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { ExtractionView() }
    }
}

struct RouteNavigation_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { RouteNavigationView() }
    }
}

struct CloudScan_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { CloudScanView() }
    }
}

struct WxApiCapture_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { WxApiCaptureView(ui: WxApiCaptureState()) }
    }
}

struct Target_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { TargetView() }
    }
}

struct Tools_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { ToolsView() }
    }
}

struct Settings_Previews: PreviewProvider {
    static var previews: some View {
        PreviewRoot { SettingsView() }
    }
}

struct FullInterface_Previews: PreviewProvider {
    static var previews: some View {
        FullPreviewRoot()
    }
}

struct Sidebar_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            CelosiaBackground()
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 190)
                    .environmentObject(AppModel())
                    .environmentObject(GlassTheme())
                Spacer()
            }
            .frame(width: 420, height: 640)
        }
        .preferredColorScheme(.dark)
    }
}

struct GlassButton_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            CelosiaBackground()
            HStack(spacing: 12) {
                Button(action: {}) {
                    Label("启动调试器", systemImage: "play.fill")
                }
                .buttonStyle(GlassButtonStyle())

                Button(action: {}) {
                    Label("复制配置", systemImage: "doc.on.doc")
                }
                .buttonStyle(GlassButtonStyle())
            }
            .padding(40)
        }
        .frame(width: 520, height: 220)
        .preferredColorScheme(.dark)
    }
}

struct StatusPill_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            CelosiaBackground()
            HStack(spacing: 12) {
                StatusPill(text: "运行中", color: .launcherGreen)
                StatusPill(text: "已停止", color: .launcherSecondary)
                StatusPill(text: "失败", color: .launcherRed)
            }
            .padding(40)
        }
        .frame(width: 420, height: 220)
        .preferredColorScheme(.dark)
    }
}
