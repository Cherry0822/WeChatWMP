import SwiftUI
import AppKit

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
