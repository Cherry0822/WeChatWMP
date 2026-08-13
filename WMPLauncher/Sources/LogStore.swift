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
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            entries.append(Entry(time: Date(), source: source, message: trimmed))
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
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
}
