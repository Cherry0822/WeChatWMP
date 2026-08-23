import Foundation
import SwiftUI
import Combine

extension AnyTransition {
    static let liquidGlass: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
        removal: .opacity.combined(with: .scale(scale: 1.03, anchor: .top))
    )
}
enum RuntimeCLI {
    static func scriptPath(projectRoot: String) -> String {
        (projectRoot as NSString)
            .appendingPathComponent("miniapp-reverse-mcp/run_runtime_cli.py")
    }

    static func run(
        pythonPath: String,
        scriptPath: String,
        projectRoot: String,
        arguments: [String]
    ) -> String {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.standardOutput = outPipe
        process.standardError = errPipe

        let group = DispatchGroup()
        let lock = NSLock()
        var outData = Data()
        var errData = Data()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outData.append(data)
            }
            lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock()
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errData.append(data)
            }
            lock.unlock()
        }

        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            group.leave()
            return "执行失败：\(error.localizedDescription)"
        }

        group.wait()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            return errText.isEmpty ? "命令退出码 \(process.terminationStatus)" : errText
        }
        return [outText, errText].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum RuntimeCommandRunner {
    private static let lock = NSLock()
    private static var daemon: RuntimeDaemon?

    static func call(
        model: AppModel,
        arguments: [String],
        completion: @escaping (String) -> Void
    ) {
        let pythonPath = model.env.pythonPath
        let projectRoot = model.projectRoot
        Task.detached(priority: .userInitiated) {
            let text: String
            if RuntimeDaemon.sessionCommands.contains(arguments.first ?? "") {
                let runtime = RuntimeCommandRunner.runtime(pythonPath: pythonPath, projectRoot: projectRoot)
                text = runtime.call(arguments: arguments)
            } else {
                text = RuntimeCLI.run(
                    pythonPath: pythonPath,
                    scriptPath: RuntimeCLI.scriptPath(projectRoot: projectRoot),
                    projectRoot: projectRoot,
                    arguments: arguments
                )
            }
            await MainActor.run { completion(text) }
        }
    }

    private static func runtime(pythonPath: String, projectRoot: String) -> RuntimeDaemon {
        lock.lock()
        defer { lock.unlock() }
        if let daemon, daemon.matches(pythonPath: pythonPath, projectRoot: projectRoot) { return daemon }
        daemon?.stop()
        let created = RuntimeDaemon(pythonPath: pythonPath, projectRoot: projectRoot)
        daemon = created
        return created
    }
}

private final class RuntimeDaemon {
    static let sessionCommands: Set<String> = [
        "route-config", "route", "redirect-guard", "debug-state", "set-debug",
        "cloud-start", "cloud-stop", "cloud-poll", "cloud-clear", "cloud-call", "cloud-static-scan",
        "targets", "targets-json", "target-attach",
        "wxapi-start", "wxapi-stop", "wxapi-poll", "wxapi-clear", "wxapi-replay"
    ]

    private let pythonPath: String
    private let projectRoot: String
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output = Data()
    private var nextID = 1

    init(pythonPath: String, projectRoot: String) {
        self.pythonPath = pythonPath
        self.projectRoot = projectRoot
    }

    func matches(pythonPath: String, projectRoot: String) -> Bool {
        self.pythonPath == pythonPath && self.projectRoot == projectRoot
    }

    func call(arguments: [String]) -> String {
        lock.lock()
        defer { lock.unlock() }
        do {
            try ensureStarted()
            guard let input, let process, process.isRunning else { return "RUNTIME_ERROR: runtime daemon exited" }
            let id = nextID
            nextID += 1
            let payload: [String: Any] = ["id": id, "args": arguments]
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A)
            try input.write(contentsOf: data)

            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if let response = readResponse(id: id) {
                    if response["ok"] as? Bool == true { return response["data"] as? String ?? "" }
                    return "RUNTIME_ERROR: \(response["error"] as? String ?? "runtime command failed")"
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            return "RUNTIME_ERROR: runtime command timed out"
        } catch {
            stop()
            return "RUNTIME_ERROR: \(error.localizedDescription)"
        }
    }

    private func ensureStarted() throws {
        if process?.isRunning == true { return }
        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["run_runtime_server.py"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectRoot).appendingPathComponent("miniapp-reverse-mcp")
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.standardError
        proc.terminationHandler = { [weak self] _ in
            self?.process = nil
            self?.input = nil
        }
        try proc.run()
        process = proc
        input = stdin.fileHandleForWriting
        output = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.outputLock.lock()
            self?.output.append(data)
            self?.outputLock.unlock()
        }
    }

    private func readResponse(id: Int) -> [String: Any]? {
        outputLock.lock()
        defer { outputLock.unlock() }
        guard let newline = output.firstIndex(of: 0x0A) else { return nil }
        let line = output.prefix(upTo: newline)
        output.removeSubrange(...newline)
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["id"] as? Int == id else { return nil }
        return object
    }

    func stop() {
        process?.terminate()
        process = nil
        input = nil
        output.removeAll()
    }
}

enum JSONText {
    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return "\(value)"
        }
        return String(data: data, encoding: .utf8) ?? "\(value)"
    }

    static func parseArray(_ text: String) -> [[String: Any]]? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return array
    }
}

