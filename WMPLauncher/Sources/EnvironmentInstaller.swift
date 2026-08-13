import Foundation

enum InstallError: LocalizedError {
    case unsupportedArchitecture
    case invalidNodeIndex
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture: return "不支持的 CPU 架构"
        case .invalidNodeIndex: return "无法获取 Node.js 版本信息"
        case .installFailed(let message): return message
        }
    }
}

struct InstallReport {
    var installedAny = false
}

enum EnvironmentInstaller {
    static let runtimeDir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WMPLauncher/runtime", isDirectory: true).path
    }()

    static func managedNodePath() -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: runtimeDir) else { return nil }
        for item in items where item.hasPrefix("node-v") {
            let candidate = (runtimeDir as NSString).appendingPathComponent("\(item)/bin/node")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func managedUVPath() -> String? {
        let candidate = (runtimeDir as NSString).appendingPathComponent("uv/uv")
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    static func ensureAll(projectRoot: String, log: @escaping (String) -> Void) async throws -> InstallReport {
        var report = InstallReport()
        let fm = FileManager.default
        let debuggerDir = (projectRoot as NSString).appendingPathComponent("WMPFDebugger-mac")
        let mcpDir = (projectRoot as NSString).appendingPathComponent("miniapp-reverse-mcp")
        let venvPython = (mcpDir as NSString).appendingPathComponent(".venv/bin/python")
        try fm.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true)

        // 1. Node.js
        let systemNode = EnvChecker.resolveNode()
        if nodeVersionOK(systemNode) {
            log("Node.js 已就绪：\(systemNode)")
        } else {
            report.installedAny = true
            log("未找到 Node.js ≥ 22，开始自动下载安装…")
            let node = try await installNode(log: log)
            log("Node.js 安装完成：\(node)")
        }
        let nodePath = EnvChecker.resolveNode()

        // 2. Python
        let basePython = EnvChecker.resolveBasePython()
        let baseOK = pythonVersionOK(basePython)
        var uvPath: String?
        if baseOK {
            log("Python 已就绪：\(basePython)")
        } else {
            report.installedAny = true
            log("未找到 Python ≥ 3.11，开始安装托管 Python…")
            uvPath = try await ensureUV(log: log)
            log("安装 Python 3.13…")
            try await runProcess(uvPath!, ["python", "install", "3.13"], cwd: mcpDir, env: nil, log: log)
            log("托管 Python 安装完成")
        }

        // 3. Python 虚拟环境与依赖
        let venvExists = fm.fileExists(atPath: venvPython)
        let depsOK = venvExists && depsInstalled(venvPython)
        if !venvExists {
            report.installedAny = true
            log("创建 Python 虚拟环境…")
            if baseOK {
                try await runProcess(basePython, ["-m", "venv", ".venv"], cwd: mcpDir, env: nil, log: log)
            } else if let uv = uvPath {
                try await runProcess(uv, ["venv", "--python", "3.13", ".venv"], cwd: mcpDir, env: nil, log: log)
            }
        }
        if !depsOK {
            report.installedAny = true
            log("安装 Python 依赖（requirements.txt）…")
            if baseOK, fm.fileExists(atPath: venvPython) {
                try await runProcess(
                    venvPython,
                    ["-m", "pip", "install", "-r", "requirements.txt"],
                    cwd: mcpDir, env: nil, log: log
                )
            } else if let uv = uvPath, fm.fileExists(atPath: venvPython) {
                try await runProcess(
                    uv,
                    ["pip", "install", "--python", venvPython, "-r", "requirements.txt"],
                    cwd: mcpDir, env: nil, log: log
                )
            }
            log("Python 依赖安装完成")
        } else {
            log("miniapp-reverse-mcp 依赖已就绪")
        }

        // 4. WMPFDebugger node_modules
        let nodeModules = (debuggerDir as NSString).appendingPathComponent("node_modules")
        let nodeDepsOK = ["frida", "ws", "protobufjs"].allSatisfy {
            fm.fileExists(atPath: (nodeModules as NSString).appendingPathComponent($0))
        }
        if !nodeDepsOK {
            report.installedAny = true
            log("安装 WMPFDebugger 依赖（npm install）…")
            var env = ProcessInfo.processInfo.environment
            let nodeBin = (nodePath as NSString).deletingLastPathComponent
            env["PATH"] = [nodeBin, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
            try await runProcess(
                "/usr/bin/env",
                ["npm", "install", "--no-audit", "--no-fund"],
                cwd: debuggerDir, env: env, log: log
            )
            log("WMPFDebugger 依赖安装完成")
        } else {
            log("WMPFDebugger 依赖已就绪")
        }

        log("环境检查与安装全部完成")
        return report
    }

    // MARK: - 内部实现

    private static func runProcess(
        _ executable: String,
        _ args: [String],
        cwd: String?,
        env: [String: String]?,
        log: @escaping (String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe
            if let cwd {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            if let env {
                process.environment = env
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    log(text)
                }
            }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: InstallError.installFailed(
                        "命令退出码 \(p.terminationStatus)：\(executable) \(args.joined(separator: " "))"
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private static func installNode(log: @escaping (String) -> Void) async throws -> String {
        let fm = FileManager.default
        let arch = EnvChecker.runCommand("/usr/bin/uname", ["-m"])
        guard arch == "arm64" || arch == "x86_64" else {
            throw InstallError.unsupportedArchitecture
        }

        log("获取 Node.js 最新 LTS 版本…")
        let indexFile = fm.temporaryDirectory.appendingPathComponent("wmp-node-index.json")
        try await runProcess(
            "/usr/bin/curl",
            ["-L", "--fail", "--silent", "--show-error", "-o", indexFile.path, "https://nodejs.org/dist/index.json"],
            cwd: nil, env: nil, log: log
        )
        let data = try Data(contentsOf: indexFile)
        try? fm.removeItem(at: indexFile)
        let list = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        guard let entry = list.first(where: { item -> Bool in
            guard let lts = item["lts"] as? String, !lts.isEmpty,
                  let version = item["version"] as? String else { return false }
            return version.hasPrefix("v2")
        }), let version = entry["version"] as? String else {
            throw InstallError.invalidNodeIndex
        }

        let fileName = "node-\(version)-darwin-\(arch).tar.gz"
        let url = "https://nodejs.org/dist/\(version)/\(fileName)"
        let tarball = fm.temporaryDirectory.appendingPathComponent(fileName)
        log("下载 \(fileName)…")
        try await runProcess(
            "/usr/bin/curl",
            ["-L", "--fail", "--silent", "--show-error", "-o", tarball.path, url],
            cwd: nil, env: nil, log: log
        )
        log("解压到运行时目录…")
        try await runProcess("/usr/bin/tar", ["-xzf", tarball.path, "-C", runtimeDir], cwd: nil, env: nil, log: log)
        try? fm.removeItem(at: tarball)

        guard let node = managedNodePath() else {
            throw InstallError.installFailed("Node.js 解压后未找到可执行文件")
        }
        return node
    }

    private static func ensureUV(log: @escaping (String) -> Void) async throws -> String {
        if let uv = managedUVPath() {
            return uv
        }
        let fm = FileManager.default
        let arch = EnvChecker.runCommand("/usr/bin/uname", ["-m"])
        let platform = arch == "arm64" ? "aarch64" : (arch == "x86_64" ? "x86_64" : nil)
        guard let platform else { throw InstallError.unsupportedArchitecture }

        let fileName = "uv-\(platform)-apple-darwin.tar.gz"
        let url = "https://github.com/astral-sh/uv/releases/latest/download/\(fileName)"
        let tarball = fm.temporaryDirectory.appendingPathComponent(fileName)
        log("下载 \(fileName)…")
        try await runProcess(
            "/usr/bin/curl",
            ["-L", "--fail", "--silent", "--show-error", "-o", tarball.path, url],
            cwd: nil, env: nil, log: log
        )

        let uvDir = (runtimeDir as NSString).appendingPathComponent("uv")
        try fm.createDirectory(atPath: uvDir, withIntermediateDirectories: true)
        log("解压 uv…")
        try await runProcess("/usr/bin/tar", ["-xzf", tarball.path, "-C", uvDir], cwd: nil, env: nil, log: log)
        try? fm.removeItem(at: tarball)

        let extracted = (uvDir as NSString).appendingPathComponent("uv-\(platform)-apple-darwin/uv")
        let target = (uvDir as NSString).appendingPathComponent("uv")
        if fm.fileExists(atPath: extracted), !fm.fileExists(atPath: target) {
            try fm.moveItem(atPath: extracted, toPath: target)
        }
        guard let uv = managedUVPath() else {
            throw InstallError.installFailed("uv 解压后未找到可执行文件")
        }
        return uv
    }

    private static func nodeVersionOK(_ path: String) -> Bool {
        let out = EnvChecker.runCommand(path, ["--version"])
        let major = out
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .first
            .flatMap { Int($0) } ?? 0
        return major >= 22
    }

    private static func pythonVersionOK(_ path: String) -> Bool {
        let out = EnvChecker.runCommand(path, ["--version"])
        let parts = out
            .replacingOccurrences(of: "Python ", with: "")
            .split(separator: ".")
            .prefix(2)
            .compactMap { Int($0) }
        return parts.count == 2 && (parts[0] > 3 || (parts[0] == 3 && parts[1] >= 11))
    }

    private static func depsInstalled(_ venvPython: String) -> Bool {
        let out = EnvChecker.runCommand(venvPython, ["-c", "import cdp_use, mcp"])
        return !out.localizedCaseInsensitiveContains("error")
            && !out.localizedCaseInsensitiveContains("traceback")
    }
}
