import SwiftUI
import AppKit

final class VersionEditorState: ObservableObject {
    @Published var entries: [VersionConfigEntry] = []
    @Published var version = ""
    @Published var wechatVersion = ""

    @Published var arm64LoadStart = ""
    @Published var arm64LoadStart2 = ""
    @Published var arm64CDPFilter = ""
    @Published var arm64ResourceCache = ""
    @Published var arm64StructOffset = ""
    @Published var arm64SceneOffset = ""

    @Published var x64LoadStart = ""
    @Published var x64LoadStart2 = ""
    @Published var x64CDPFilter = ""
    @Published var x64ResourceCache = ""
    @Published var x64StructOffset = ""
    @Published var x64SceneOffset = ""

    @Published var editingOldVersion: String?
    @Published var message = ""
    @Published var messageIsError = false

    func reload(projectRoot: String) {
        entries = VersionConfigStore.loadAll(projectRoot: projectRoot)
    }

    func resetNew() {
        version = ""
        wechatVersion = ""
        arm64LoadStart = ""
        arm64LoadStart2 = ""
        arm64CDPFilter = ""
        arm64ResourceCache = ""
        arm64StructOffset = ""
        arm64SceneOffset = ""
        x64LoadStart = ""
        x64LoadStart2 = ""
        x64CDPFilter = ""
        x64ResourceCache = ""
        x64StructOffset = ""
        x64SceneOffset = ""
        editingOldVersion = nil
        message = ""
        messageIsError = false
    }

    func load(_ entry: VersionConfigEntry) {
        editingOldVersion = entry.version
        version = entry.version
        wechatVersion = entry.config.WeChatVersion ?? ""
        if let table = entry.config.Arch?.arm64 {
            fill(arch: "arm64", table: table)
        } else {
            clear(arch: "arm64")
        }
        if let table = entry.config.Arch?.x64 {
            fill(arch: "x64", table: table)
        } else {
            clear(arch: "x64")
        }
        message = ""
        messageIsError = false
    }

    func fillTemplate(arch: String, projectRoot: String) {
        guard let table = VersionConfigStore.template(projectRoot: projectRoot, arch: arch) else {
            message = "未找到 addresses.18788.json 模板"
            messageIsError = true
            return
        }
        fill(arch: arch, table: table)
        message = "已从 18788 模板填入 \(arch) 偏移"
        messageIsError = false
    }

    func arm64Table() -> WMPArchTable? {
        buildTable(
            loadStart: arm64LoadStart,
            loadStart2: arm64LoadStart2,
            cdpFilter: arm64CDPFilter,
            resourceCache: arm64ResourceCache,
            structOffset: arm64StructOffset,
            sceneOffset: arm64SceneOffset
        )
    }

    func x64Table() -> WMPArchTable? {
        buildTable(
            loadStart: x64LoadStart,
            loadStart2: x64LoadStart2,
            cdpFilter: x64CDPFilter,
            resourceCache: x64ResourceCache,
            structOffset: x64StructOffset,
            sceneOffset: x64SceneOffset
        )
    }

    private func fill(arch: String, table: WMPArchTable) {
        if arch == "arm64" {
            arm64LoadStart = table.LoadStartHookOffset
            arm64LoadStart2 = table.LoadStartHookOffset2
            arm64CDPFilter = table.CDPFilterHookOffset
            arm64ResourceCache = table.ResourceCachePolicyHookOffset
            arm64StructOffset = String(table.StructOffset)
            arm64SceneOffset = table.SceneOffset.map(String.init) ?? ""
        } else {
            x64LoadStart = table.LoadStartHookOffset
            x64LoadStart2 = table.LoadStartHookOffset2
            x64CDPFilter = table.CDPFilterHookOffset
            x64ResourceCache = table.ResourceCachePolicyHookOffset
            x64StructOffset = String(table.StructOffset)
            x64SceneOffset = table.SceneOffset.map(String.init) ?? ""
        }
    }

    private func clear(arch: String) {
        if arch == "arm64" {
            arm64LoadStart = ""
            arm64LoadStart2 = ""
            arm64CDPFilter = ""
            arm64ResourceCache = ""
            arm64StructOffset = ""
            arm64SceneOffset = ""
        } else {
            x64LoadStart = ""
            x64LoadStart2 = ""
            x64CDPFilter = ""
            x64ResourceCache = ""
            x64StructOffset = ""
            x64SceneOffset = ""
        }
    }

    private func buildTable(
        loadStart: String,
        loadStart2: String,
        cdpFilter: String,
        resourceCache: String,
        structOffset: String,
        sceneOffset: String
    ) -> WMPArchTable? {
        guard !loadStart.isEmpty,
              !loadStart2.isEmpty,
              !cdpFilter.isEmpty,
              !resourceCache.isEmpty,
              let structValue = Int(structOffset) else {
            return nil
        }
        return WMPArchTable(
            loadStart: loadStart,
            loadStart2: loadStart2,
            cdpFilter: cdpFilter,
            resourceCache: resourceCache,
            structOffset: structValue,
            sceneOffset: Int(sceneOffset)
        )
    }
}

struct VersionsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var editor = VersionEditorState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "版本配置", subtitle: "管理微信版本与各小程序版本对应的偏移量配置")

                LauncherCard {
                    HStack {
                        Label("当前检测", systemImage: "scope")
                            .font(.headline)
                        Spacer()
                        Button("重新检测") {
                            model.refreshEnv()
                            editor.reload(projectRoot: model.projectRoot)
                        }
                        .controlSize(.small)
                    }
                    HStack(spacing: 28) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("微信版本").font(.caption).foregroundColor(.launcherSecondary)
                            Text(model.env.wechatVersion)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("小程序版本").font(.caption).foregroundColor(.launcherSecondary)
                            Text(shortVersion)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("匹配配置").font(.caption).foregroundColor(.launcherSecondary)
                            Text(matchedConfigText)
                                .font(.body.monospaced())
                                .foregroundColor(hasMatchedConfig ? .launcherGreen : .launcherOrange)
                        }
                    }
                }

                SectionTitle(text: "已有版本配置")
                if editor.entries.isEmpty {
                    Text("暂无配置文件，点击下方「新增版本配置」创建。")
                        .font(.callout)
                        .foregroundColor(.launcherSecondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(editor.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }

                Button {
                    editor.resetNew()
                } label: {
                    Label("新增版本配置", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .padding(.top, 10)

                SectionTitle(text: "新增 / 编辑版本配置")
                editorForm
            }
        }
        .onAppear {
            editor.reload(projectRoot: model.projectRoot)
        }
        .onChange(of: model.projectRoot) { _ in
            editor.reload(projectRoot: model.projectRoot)
        }
    }

    private var shortVersion: String {
        let value = model.env.wechatVersion
        return value.split(separator: ".").dropFirst().first.map(String.init) ?? value
    }

    private var hasMatchedConfig: Bool {
        editor.entries.contains { $0.version == shortVersion }
    }

    private var matchedConfigText: String {
        hasMatchedConfig ? "addresses.\(shortVersion).json" : "未匹配"
    }

    private func entryRow(_ entry: VersionConfigEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.version)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(entry.fileName)
                    .font(.caption)
                    .foregroundColor(.launcherSecondary)
                    .textSelection(.enabled)
                if let note = entry.config.WeChatVersion, !note.isEmpty {
                    Text("微信版本：\(note)")
                        .font(.caption)
                        .foregroundColor(.launcherSecondary)
                }
            }
            Spacer(minLength: 0)
            if entry.config.Arch?.arm64 != nil {
                StatusPill(text: "arm64", color: .accentColor)
            }
            if entry.config.Arch?.x64 != nil {
                StatusPill(text: "x64", color: .launcherGreen)
            }
            Button("编辑") {
                editor.load(entry)
            }
            .controlSize(.small)
            Button("删除", role: .destructive) {
                delete(entry)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.launcherPanel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.launcherSeparator, lineWidth: 1))
    }

    private var editorForm: some View {
        LauncherCard {
            HStack(spacing: 12) {
                field("小程序版本号（配置文件名）", text: $editor.version)
                    .frame(maxWidth: 220)
                field("微信版本备注（可选，如 4.18788.xxx）", text: $editor.wechatVersion)
            }

            archEditor(
                title: "arm64（Apple Silicon）",
                templateAction: {
                    editor.fillTemplate(arch: "arm64", projectRoot: model.projectRoot)
                },
                loadStart: $editor.arm64LoadStart,
                loadStart2: $editor.arm64LoadStart2,
                cdpFilter: $editor.arm64CDPFilter,
                resourceCache: $editor.arm64ResourceCache,
                structOffset: $editor.arm64StructOffset,
                sceneOffset: $editor.arm64SceneOffset
            )

            archEditor(
                title: "x64（Intel）",
                templateAction: {
                    editor.fillTemplate(arch: "x64", projectRoot: model.projectRoot)
                },
                loadStart: $editor.x64LoadStart,
                loadStart2: $editor.x64LoadStart2,
                cdpFilter: $editor.x64CDPFilter,
                resourceCache: $editor.x64ResourceCache,
                structOffset: $editor.x64StructOffset,
                sceneOffset: $editor.x64SceneOffset
            )

            if !editor.message.isEmpty {
                Text(editor.message)
                    .font(.caption)
                    .foregroundColor(editor.messageIsError ? .launcherRed : .launcherGreen)
            }

            HStack(spacing: 10) {
                Button {
                    save()
                } label: {
                    Label("保存配置", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Button("取消编辑") {
                    editor.resetNew()
                }

                Spacer()
            }
        }
    }

    private func archEditor(
        title: String,
        templateAction: @escaping () -> Void,
        loadStart: Binding<String>,
        loadStart2: Binding<String>,
        cdpFilter: Binding<String>,
        resourceCache: Binding<String>,
        structOffset: Binding<String>,
        sceneOffset: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline).fontWeight(.medium)
                Spacer()
                Button("从 18788 模板填入", action: templateAction)
                    .controlSize(.small)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                field("LoadStartHookOffset", text: loadStart)
                field("LoadStartHookOffset2", text: loadStart2)
                field("CDPFilterHookOffset", text: cdpFilter)
                field("ResourceCachePolicyHookOffset", text: resourceCache)
                field("StructOffset", text: structOffset)
                field("SceneOffset（可选）", text: sceneOffset)
            }
        }
        .padding(10)
        .background(Color.launcherPanelAlt, in: RoundedRectangle(cornerRadius: 9))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(.launcherSecondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private func save() {
        guard !editor.version.isEmpty else {
            editor.message = "请填写小程序版本号"
            editor.messageIsError = true
            return
        }
        let arm64 = editor.arm64Table()
        let x64 = editor.x64Table()
        guard arm64 != nil || x64 != nil else {
            editor.message = "请至少填写一套完整的 arm64 或 x64 偏移"
            editor.messageIsError = true
            return
        }
        do {
            let path = try VersionConfigStore.save(
                projectRoot: model.projectRoot,
                version: editor.version,
                wechatVersion: editor.wechatVersion,
                arm64: arm64,
                x64: x64,
                oldVersion: editor.editingOldVersion
            )
            editor.message = "已保存：\(path)"
            editor.messageIsError = false
            editor.editingOldVersion = editor.version
            editor.reload(projectRoot: model.projectRoot)
            model.refreshEnv()
        } catch {
            editor.message = "保存失败：\(error.localizedDescription)"
            editor.messageIsError = true
        }
    }

    private func delete(_ entry: VersionConfigEntry) {
        let alert = NSAlert()
        alert.messageText = "删除配置文件"
        alert.informativeText = "确定要删除 \(entry.fileName) 吗？文件会被移到废纸篓。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: entry.path),
                resultingItemURL: nil
            )
            if editor.editingOldVersion == entry.version {
                editor.resetNew()
            }
            editor.reload(projectRoot: model.projectRoot)
            model.refreshEnv()
            model.logStore.append(.launcher, "已删除配置文件：\(entry.fileName)")
        } catch {
            model.logStore.append(.launcher, "删除配置文件失败：\(error.localizedDescription)")
        }
    }
}
