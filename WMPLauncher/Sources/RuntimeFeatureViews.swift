import SwiftUI
import AppKit
import Combine

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

