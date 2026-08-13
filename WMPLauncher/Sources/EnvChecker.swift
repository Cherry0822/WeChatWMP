import Foundation

enum EnvChecker {
    static func runCommand(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func resolveNode() -> String {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let managed = EnvironmentInstaller.managedNodePath() {
            return managed
        }
        return "node"
    }

    static func resolveBasePython() -> String {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "python3"
    }

    static func resolvePython(projectRoot: String) -> String {
        let venv = (projectRoot as NSString)
            .appendingPathComponent("miniapp-reverse-mcp/.venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venv) {
            return venv
        }
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "python3"
    }

    static func snapshot(projectRoot: String) -> EnvironmentSnapshot {
        var snapshot = EnvironmentSnapshot()
        snapshot.nodePath = resolveNode()
        snapshot.pythonPath = resolvePython(projectRoot: projectRoot)
        snapshot.arch = runCommand("/usr/bin/uname", ["-m"])

        let sip = runCommand("/usr/bin/csrutil", ["status"])
        let sipEnabled = sip.localizedCaseInsensitiveContains("enabled")
        snapshot.checks.append(EnvCheckItem(
            name: "SIP 已关闭",
            detail: sip.isEmpty ? "无法读取 csrutil 状态" : sip,
            status: sipEnabled ? .fail : .ok,
            suggestion: "请重启 Mac 并进入恢复模式，在终端执行 csrutil disable 后再次重启。"
        ))

        let nodeOut = runCommand(snapshot.nodePath, ["--version"])
        let nodeMajor = nodeOut
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".").first.flatMap { Int($0) } ?? 0
        snapshot.checks.append(EnvCheckItem(
            name: "Node.js ≥ 22",
            detail: nodeOut.isEmpty ? "未找到 node" : "\(nodeOut)（WMPFDebugger-mac 依赖）",
            status: nodeOut.isEmpty ? .fail : (nodeMajor >= 22 ? .ok : .fail),
            suggestion: "点击概览页「检测环境」自动下载安装，或手动安装 Node.js ≥ 22。"
        ))

        let pyOut = runCommand(snapshot.pythonPath, ["--version"])
        let pyParts = pyOut
            .replacingOccurrences(of: "Python ", with: "")
            .split(separator: ".").prefix(2).compactMap { Int($0) }
        let pyOK = pyParts.count == 2 && (pyParts[0] > 3 || (pyParts[0] == 3 && pyParts[1] >= 11))
        snapshot.checks.append(EnvCheckItem(
            name: "Python ≥ 3.11",
            detail: pyOut.isEmpty ? "未找到 python3" : "\(pyOut)（miniapp-reverse-mcp 依赖）",
            status: pyOut.isEmpty ? .fail : (pyOK ? .ok : .fail),
            suggestion: "点击「检测环境」自动安装托管 Python 3.13。"
        ))

        let nodeModules = (projectRoot as NSString)
            .appendingPathComponent("WMPFDebugger-mac/node_modules")
        let nodeDepsOK = ["frida", "ws", "protobufjs"].allSatisfy {
            FileManager.default.fileExists(
                atPath: (nodeModules as NSString).appendingPathComponent($0)
            )
        }
        snapshot.checks.append(EnvCheckItem(
            name: "WMPFDebugger 依赖",
            detail: nodeDepsOK
                ? "node_modules 依赖已就绪"
                : "缺少依赖包（点击「检测环境」自动安装）",
            status: nodeDepsOK ? .ok : .warn,
            suggestion: "点击「检测环境」自动执行 npm install 补齐依赖。"
        ))

        let venvPython = (projectRoot as NSString)
            .appendingPathComponent("miniapp-reverse-mcp/.venv/bin/python")
        var depsOK = false
        var depsDetail = "缺少 Python 虚拟环境（点击「检测环境」自动创建）"
        if FileManager.default.fileExists(atPath: venvPython) {
            let out = runCommand(venvPython, ["-c", "import cdp_use, mcp"])
            depsOK = !out.localizedCaseInsensitiveContains("error")
                && !out.localizedCaseInsensitiveContains("traceback")
            depsDetail = depsOK
                ? "venv 已就绪 · cdp_use / mcp 已安装"
                : "venv 存在但依赖缺失（点击「检测环境」自动安装）"
        }
        snapshot.checks.append(EnvCheckItem(
            name: "miniapp-reverse-mcp 依赖",
            detail: depsDetail,
            status: depsOK ? .ok : .warn,
            suggestion: "点击「检测环境」自动创建虚拟环境并安装 requirements.txt。"
        ))

        let plist = "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/Info.plist"
        let wechatExists = FileManager.default.fileExists(atPath: plist)
        var version = "未知"
        if wechatExists {
            let v = runCommand("/usr/bin/defaults", ["read", plist, "CFBundleVersion"])
            version = v.isEmpty ? "未知" : v
        }
        snapshot.wechatVersion = version
        snapshot.checks.append(EnvCheckItem(
            name: "微信 / WeChatAppEx",
            detail: wechatExists ? "已安装 · 版本 \(version)" : "未找到 WeChatAppEx.app",
            status: wechatExists ? .ok : .fail,
            suggestion: "请安装 macOS 版微信，并打开过至少一个小程序。"
        ))

        let shortVersion = version.split(separator: ".").dropFirst().first.map(String.init) ?? version
        let configPath = (projectRoot as NSString)
            .appendingPathComponent("WMPFDebugger-mac/frida/config/addresses.\(shortVersion).json")
        let hasConfig = FileManager.default.fileExists(atPath: configPath)
        snapshot.checks.append(EnvCheckItem(
            name: "版本配置文件",
            detail: hasConfig
                ? "addresses.\(shortVersion).json 已匹配"
                : "缺少 addresses.\(shortVersion).json（可在版本管理中用 generate-address.js 生成）",
            status: hasConfig ? .ok : .warn,
            suggestion: "在 WMPFDebugger-mac 中运行 scripts/generate-address.js 生成 addresses.\(shortVersion).json。"
        ))

        let isX64 = snapshot.arch == "x86_64"
        snapshot.checks.append(EnvCheckItem(
            name: "x64 偏移表",
            detail: isX64
                ? "当前是 Intel，x64 偏移沿用了 addresses.18788.json 旧值，请手动核对"
                : "当前架构 \(snapshot.arch.isEmpty ? "未知" : snapshot.arch) 使用对应架构配置",
            status: isX64 ? .warn : .ok,
            suggestion: "手动核对 frida/config 中对应配置的 x64 偏移值。"
        ))

        let pidCheck = runCommand("/usr/bin/pgrep", ["-f", "WeChatAppEx"])
        snapshot.wechatAppExRunning = !pidCheck.isEmpty
        return snapshot
    }
}
