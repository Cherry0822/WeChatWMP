import Foundation
import Combine

final class DebuggerService: ObservableObject {
    @Published var state: ServiceState = .stopped
    @Published var log: String = ""
    @Published var pid: Int32 = 0

    var onLog: ((String) -> Void)?
    private var process: Process?
    private let lock = NSLock()
    private let maxLogLines = 800

    func start(projectRoot: String, nodePath: String) {
        guard process == nil else { return }
        state = .starting

        let proc = Process()
        let out = Pipe()
        let err = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [nodePath, "src/index.js"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("WMPFDebugger-mac", isDirectory: true)
        proc.standardOutput = out
        proc.standardError = err

        func attach(_ handle: FileHandle) {
            handle.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard !data.isEmpty, let self else { return }
                let text = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    self.appendLog(text)
                }
            }
        }
        attach(out.fileHandleForReading)
        attach(err.fileHandleForReading)

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.pid = 0
                if self.state == .starting || self.state == .running || self.state == .stopping {
                    if self.state != .stopping && p.terminationStatus != 0 {
                        self.state = .failed("进程异常退出 (code \(p.terminationStatus))")
                    } else {
                        self.state = .stopped
                    }
                    self.appendLog("[debugger] 进程已退出 (code \(p.terminationStatus))")
                }
            }
        }

        do {
            try proc.run()
            process = proc
            pid = proc.processIdentifier
            state = .running
            appendLog("[debugger] 已启动 (PID \(pid))")
        } catch {
            state = .failed(error.localizedDescription)
            appendLog("[debugger] 启动失败: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let proc = process else { return }
        state = .stopping
        proc.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak proc] in
            guard let self, let proc else { return }
            if self.process != nil, proc.isRunning {
                proc.terminate()
            }
        }
    }

    func restart(projectRoot: String, nodePath: String) {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.start(projectRoot: projectRoot, nodePath: nodePath)
        }
    }

    private func appendLog(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let combined = log + text
        let lines = combined.components(separatedBy: "\n")
        log = Array(lines.suffix(maxLogLines)).joined(separator: "\n")
        onLog?(text)
    }
}

enum MCPError: LocalizedError {
    case notConnected
    case processExited
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "MCP 服务未连接"
        case .processExited: return "MCP 进程已退出"
        case .server(let message): return message
        }
    }
}

final class MCPClient: ObservableObject {
    @Published var state: ServiceState = .stopped
    @Published var log: String = ""
    @Published var connected = false

    var onLog: ((String) -> Void)?
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: (Result<Any?, Error>) -> Void] = [:]
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private let ioQueue = DispatchQueue(label: "wmp.mcp.io")
    private let lock = NSLock()
    private let maxLogLines = 500

    func start(projectRoot: String, pythonPath: String) async throws {
        if process != nil { return }

        await MainActor.run { state = .starting }

        let proc = Process()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [pythonPath, "run_mcp_server_quiet.py"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("miniapp-reverse-mcp", isDirectory: true)
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stdin = inPipe.fileHandleForWriting

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            self.ioQueue.sync {
                self.buffer.append(data)
                self.parseIncoming()
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.appendLog(text)
            }
        }
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.ioQueue.sync {
                self.failAllPending(MCPError.processExited)
            }
            DispatchQueue.main.async {
                self.process = nil
                self.connected = false
                self.startupContinuation?.resume(throwing: MCPError.processExited)
                self.startupContinuation = nil
                if self.state == .starting || self.state == .running || self.state == .stopping {
                    self.state = .stopped
                    self.appendLog("[mcp] 进程已退出")
                }
            }
        }

        try proc.run()
        process = proc
        await MainActor.run {
            state = .running
            appendLog("[mcp] 已启动 (PID \(proc.processIdentifier))")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startupContinuation = continuation
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self else { return }
                self.ioQueue.async {
                    if let cont = self.startupContinuation {
                        self.startupContinuation = nil
                        cont.resume(throwing: MCPError.server("MCP 握手超时"))
                    }
                }
            }
            do {
                try send(method: "initialize", params: [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "clientInfo": ["name": "WMPLauncher", "version": "0.1.0"]
                ]) { result in
                    switch result {
                    case .success:
                        try? self.sendNotification(method: "notifications/initialized", params: [:])
                        DispatchQueue.main.async {
                            self.connected = true
                            self.state = .running
                            self.appendLog("[mcp] MCP 握手完成，\(ToolCatalog.all.count) 个工具可用")
                        }
                    case .failure(let error):
                        DispatchQueue.main.async {
                            self.state = .failed(error.localizedDescription)
                        }
                    }
                    self.startupContinuation?.resume(returning: ())
                    self.startupContinuation = nil
                }
            } catch {
                self.startupContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func call(name: String, arguments: [String: Any] = [:]) async throws -> String {
        guard process != nil, connected else { throw MCPError.notConnected }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            do {
                try send(method: "tools/call", params: ["name": name, "arguments": arguments]) { result in
                    switch result {
                    case .success(let value):
                        let text = Self.extractText(value)
                        if text.isEmpty {
                            continuation.resume(returning: "(空结果)")
                        } else {
                            continuation.resume(returning: text)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        guard let proc = process else { return }
        state = .stopping
        proc.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak proc] in
            guard let self, let proc else { return }
            if self.process != nil, proc.isRunning {
                proc.terminate()
            }
        }
    }

    private func send(
        method: String,
        params: [String: Any],
        completion: @escaping (Result<Any?, Error>) -> Void
    ) throws {
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.pending[id] = completion
            try? self.stdin?.write(contentsOf: line)
            self.ioQueue.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self else { return }
                if let handler = self.pending.removeValue(forKey: id) {
                    handler(.failure(MCPError.server("MCP 调用超时")))
                }
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? self.stdin?.write(contentsOf: line)
        }
    }

    private func parseIncoming() {
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !lineData.isEmpty else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = json["id"] as? Int,
                  let handler = pending.removeValue(forKey: id) else {
                continue
            }
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "MCP 错误"
                handler(.failure(MCPError.server(message)))
            } else {
                handler(.success(json["result"]))
            }
        }
    }

    private func failAllPending(_ error: Error) {
        for (_, handler) in pending {
            handler(.failure(error))
        }
        pending.removeAll()
    }

    private static func extractText(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else {
            if let string = value as? String { return string }
            return "\(value ?? "")"
        }
        if dict["isError"] as? Bool == true,
           let content = dict["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let content = dict["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let structured = dict["structuredContent"] {
            if let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return "\(dict)"
    }

    private func appendLog(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let combined = log + text
        let lines = combined.components(separatedBy: "\n")
        log = Array(lines.suffix(maxLogLines)).joined(separator: "\n")
        onLog?(text)
    }
}
