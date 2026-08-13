import SwiftUI

@main
struct WMPLauncherApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var theme = GlassTheme()

    var body: some Scene {
        WindowGroup("WMP Launcher") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.debugger)
                .environmentObject(model.mcp)
                .environmentObject(model.logStore)
                .environmentObject(theme)
        }
        .defaultSize(width: 1080, height: 720)
    }
}
