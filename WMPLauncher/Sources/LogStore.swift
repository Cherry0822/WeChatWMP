import Foundation
import Combine

final class LogStore: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case all = "全部"
        case launcher = "启动器"
        case debugger = "调试器"
        case mcp = "MCP"

        var id: String { rawValue }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let source: Source
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 2000

    func append(_ source: Source, _ message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.append(source, message)
            }
            return
        }
        let lines = message.components(separatedBy: "\n")
        var newEntries: [Entry] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let entry = Entry(time: Date(), source: source, message: trimmed)
            entries.append(entry)
            newEntries.append(entry)
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        appendToDisk(newEntries)
    }

    func clear() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.clear()
            }
            return
        }
        entries.removeAll()
    }

    private func appendToDisk(_ newEntries: [Entry]) {
        guard UserDefaults.standard.bool(forKey: "logToDisk"), !newEntries.isEmpty else { return }
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/WMPLauncher", isDirectory: true)
        let file = logsDirectory.appendingPathComponent("launcher.log")
        let formatter = ISO8601DateFormatter()
        let text = newEntries.map { "[\(formatter.string(from: $0.time))] [\($0.source.rawValue)] \($0.message)" }
            .joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file)
            }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } catch {
            // Logging must never affect the launcher workflow.
        }
    }
}
