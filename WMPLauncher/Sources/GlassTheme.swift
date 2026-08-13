import SwiftUI
import AppKit

// MARK: - 全局玻璃主题

/// 液态玻璃主题：控制全局磨砂玻璃透明度，并在设置页实时调节。
final class GlassTheme: ObservableObject {
    static let defaultOpacity: Double = 0.68

    @Published var opacity: Double {
        didSet {
            UserDefaults.standard.set(opacity, forKey: "glassOpacity")
        }
    }

    init() {
        if let saved = UserDefaults.standard.object(forKey: "glassOpacity") as? Double {
            opacity = min(max(saved, 0.0), 1.0)
        } else {
            opacity = Self.defaultOpacity
        }
    }

    var percentage: Int {
        Int((opacity * 100).rounded())
    }
}

// MARK: - 颜色体系

enum GlassPalette {
    static let void = Color(red: 0.022, green: 0.027, blue: 0.048)
    static let deep = Color(red: 0.055, green: 0.070, blue: 0.110)
    static let surface = Color(red: 0.095, green: 0.115, blue: 0.170)
    static let hairline = Color.white.opacity(0.13)
    static let highlight = Color.white.opacity(0.24)
    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.56)
}

// MARK: - 多层液态玻璃背景

/// 液态玻璃背景：仅使用 behindWindow 毛玻璃透出桌面。
struct CelosiaBackground: View {
    @EnvironmentObject private var theme: GlassTheme

    var body: some View {
        GlassBackground(
            material: .underWindowBackground,
            blendingMode: .behindWindow,
            cornerRadius: 0,
            opacity: theme.opacity
        )
        .ignoresSafeArea()
    }
}

// MARK: - 真毛玻璃实现

/// 用 NSVisualEffectView 实现真正的磨砂玻璃，透明度可实时调节。
/// 比 SwiftUI Material 更适合做“全局可调透明度”的液态玻璃效果。
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active
    var cornerRadius: CGFloat = 8
    var opacity: Double = GlassTheme.defaultOpacity

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        view.alphaValue = CGFloat(opacity)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.alphaValue = CGFloat(opacity)
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.masksToBounds = true
    }
}

// MARK: - 玻璃修饰器

extension View {
    /// 主卡片 / 面板：边缘锐利、多层半透明、带固定高光。
    func glassPanel(cornerRadius: CGFloat = 8, opacity: Double = GlassTheme.defaultOpacity) -> some View {
        self
            .background(
                ZStack {
                    GlassBackground(
                        material: .hudWindow,
                        blendingMode: .withinWindow,
                        cornerRadius: cornerRadius,
                        opacity: opacity
                    )

                    // 顶部微弱高光，模拟玻璃边缘的固定反光。
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            LinearGradient(
                                colors: [GlassPalette.highlight, Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .padding(0.5)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(GlassPalette.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.32), radius: 10, x: 0, y: 5)
    }

    /// 小型表面：行、字段、日志区，保持哑光玻璃质感。
    func glassSurface(cornerRadius: CGFloat = 7, opacity: Double = GlassTheme.defaultOpacity) -> some View {
        self
            .background(
                GlassBackground(
                    material: .underWindowBackground,
                    blendingMode: .withinWindow,
                    cornerRadius: cornerRadius,
                    opacity: opacity
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(GlassPalette.hairline, lineWidth: 1)
            )
    }
}

// MARK: - 玻璃按钮

struct GlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var opacity: Double = GlassTheme.defaultOpacity

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundColor(tint == nil ? GlassPalette.text : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    GlassBackground(
                        material: .hudWindow,
                        blendingMode: .withinWindow,
                        cornerRadius: 8,
                        opacity: configuration.isPressed ? 0.55 : opacity
                    )
                    if let tint {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(tint.opacity(configuration.isPressed ? 0.22 : 0.38))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke((tint ?? GlassPalette.hairline).opacity(0.35), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 4, x: 0, y: 2)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

// MARK: - 玻璃状态胶囊

struct GlassPill: View {
    let text: String
    var color: Color = GlassPalette.text
    var opacity: Double = GlassTheme.defaultOpacity

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
        }
        .foregroundColor(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            GlassBackground(
                material: .hudWindow,
                blendingMode: .withinWindow,
                cornerRadius: 999,
                opacity: opacity * 0.65
            )
        )
        .overlay(
            Capsule().stroke(color.opacity(0.24), lineWidth: 1)
        )
    }
}

// MARK: - 透明窗口访问器

/// 让 SwiftUI 窗口背景透明，从而允许 behindWindow 毛玻璃透出桌面。
struct WindowTransparency: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            apply(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(window: nsView.window)
    }

    private func apply(window: NSWindow?) {
        let target = window ?? NSApp.windows.first
        guard let target else { return }
        DispatchQueue.main.async {
            target.isOpaque = false
            target.backgroundColor = .clear
            target.titlebarAppearsTransparent = true
        }
    }
}
