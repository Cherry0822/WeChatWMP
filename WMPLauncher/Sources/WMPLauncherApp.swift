import SwiftUI

@main
struct WMPLauncherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("WMP Launcher") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.debugger)
                .environmentObject(model.mcp)
                .environmentObject(model.workflow)
                .environmentObject(model.logStore)
        }
        .defaultSize(width: 1080, height: 720)
    }
}
