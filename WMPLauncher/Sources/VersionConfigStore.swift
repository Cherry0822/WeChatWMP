import Foundation

struct WMPArchTable: Codable {
    var LoadStartHookOffset: String
    var LoadStartHookOffset2: String
    var CDPFilterHookOffset: String
    var ResourceCachePolicyHookOffset: String
    var StructOffset: Int
    var SceneOffset: Int?

    init(
        loadStart: String,
        loadStart2: String,
        cdpFilter: String,
        resourceCache: String,
        structOffset: Int,
        sceneOffset: Int?
    ) {
        LoadStartHookOffset = loadStart
        LoadStartHookOffset2 = loadStart2
        CDPFilterHookOffset = cdpFilter
        ResourceCachePolicyHookOffset = resourceCache
        StructOffset = structOffset
        SceneOffset = sceneOffset
    }
}

struct WMPArchConfig: Codable {
    var arm64: WMPArchTable? = nil
    var x64: WMPArchTable? = nil
}

struct WMPVersionConfigFile: Codable {
    var Version: Int? = nil
    var WeChatVersion: String? = nil
    var Arch: WMPArchConfig? = nil
}

struct VersionConfigEntry: Identifiable {
    var id: String { version }
    let version: String
    let fileName: String
    let path: String
    let config: WMPVersionConfigFile
}

enum VersionConfigStore {
    static func configDirectory(projectRoot: String) -> String {
        (projectRoot as NSString)
            .appendingPathComponent("WMPFDebugger-mac/frida/config")
    }

    static func loadAll(projectRoot: String) -> [VersionConfigEntry] {
        let dir = configDirectory(projectRoot: projectRoot)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        var entries: [VersionConfigEntry] = []
        for file in files where file.hasPrefix("addresses.") && file.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let config = try? JSONDecoder().decode(WMPVersionConfigFile.self, from: data) else {
                continue
            }
            let version = file
                .replacingOccurrences(of: "addresses.", with: "")
                .replacingOccurrences(of: ".json", with: "")
            entries.append(VersionConfigEntry(
                version: version,
                fileName: file,
                path: path,
                config: config
            ))
        }
        return entries.sorted {
            (Int($0.version) ?? 0) > (Int($1.version) ?? 0)
        }
    }

    static func save(
        projectRoot: String,
        version: String,
        wechatVersion: String?,
        arm64: WMPArchTable?,
        x64: WMPArchTable?,
        oldVersion: String?
    ) throws -> String {
        let dir = configDirectory(projectRoot: projectRoot)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var config = WMPVersionConfigFile()
        config.Version = Int(version) ?? Int(oldVersion ?? "")
        if let wechatVersion, !wechatVersion.isEmpty {
            config.WeChatVersion = wechatVersion
        }
        config.Arch = WMPArchConfig(arm64: arm64, x64: x64)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        let fileName = "addresses.\(version).json"
        let path = (dir as NSString).appendingPathComponent(fileName)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)

        if let oldVersion, oldVersion != version {
            let oldPath = (dir as NSString).appendingPathComponent("addresses.\(oldVersion).json")
            try? FileManager.default.removeItem(atPath: oldPath)
        }
        return path
    }

    static func template(projectRoot: String, arch: String) -> WMPArchTable? {
        let path = (configDirectory(projectRoot: projectRoot) as NSString)
            .appendingPathComponent("addresses.18788.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let config = try? JSONDecoder().decode(WMPVersionConfigFile.self, from: data) else {
            return nil
        }
        return arch == "x64" ? config.Arch?.x64 : config.Arch?.arm64
    }
}
