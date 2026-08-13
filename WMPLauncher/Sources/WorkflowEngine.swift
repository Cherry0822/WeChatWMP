import Foundation
import Combine

final class WorkflowEngine: ObservableObject {
    @Published var currentStep: WorkflowStep = .clear
    @Published var doneSteps: Set<Int> = []
    @Published var detailResult = ""
    @Published var selectedRequestID = ""
    @Published var selectedScriptURL = ""
    @Published var breakpointText = ""
    @Published var captureWaitSeconds = 3
    @Published var busy = false
    @Published var lastError: String?
    @Published var finished = false

    private let mcp: MCPClient
    var onLog: ((String) -> Void)?

    init(mcp: MCPClient) {
        self.mcp = mcp
    }

    var isDone: Bool { currentStep == .cleanup && doneSteps.contains(WorkflowStep.cleanup.rawValue) }

    func reset() {
        currentStep = .clear
        doneSteps = []
        detailResult = ""
        lastError = nil
        finished = false
        selectedRequestID = ""
        selectedScriptURL = ""
    }

    func select(_ step: WorkflowStep) {
        currentStep = step
        lastError = nil
    }

    func runCurrentStep() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            onLog?("执行工作流步骤 \(currentStep.rawValue + 1) \(currentStep.title)：\(currentStep.toolCall)")
            switch currentStep {
            case .clear:
                detailResult = try await mcp.call(name: "list_network_requests", arguments: ["clear_existing": true])
            case .capture:
                detailResult = try await mcp.call(
                    name: "list_network_requests",
                    arguments: ["wait_ms": captureWaitSeconds * 1000]
                )
                extractRequestID(from: detailResult)
            case .trace:
                detailResult = try await mcp.call(
                    name: "get_request_initiator",
                    arguments: ["request_id": selectedRequestID]
                )
            case .source:
                detailResult = try await mcp.call(
                    name: "get_script_source",
                    arguments: ["url": selectedScriptURL, "start_line": 1, "end_line": 80]
                )
            case .breakpoint:
                detailResult = try await mcp.call(
                    name: "set_breakpoint_on_text",
                    arguments: ["text": breakpointText]
                )
            case .paused:
                detailResult = try await mcp.call(
                    name: "get_paused_info",
                    arguments: ["include_scopes": true]
                )
            case .cleanup:
                detailResult = try await mcp.call(
                    name: "remove_breakpoints",
                    arguments: ["clear_all": true]
                )
            }
            markDone(currentStep)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func captureNow() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            onLog?("工作流 · 立即抓取")
            detailResult = try await mcp.call(name: "list_network_requests")
            extractRequestID(from: detailResult)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func listScripts() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            onLog?("工作流 · 列出脚本")
            let result = try await mcp.call(name: "list_scripts")
            detailResult = result
            extractScriptURL(from: result)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func step(_ action: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            onLog?("工作流 · 单步 \(action)")
            detailResult = try await mcp.call(name: "step", arguments: ["action": action])
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resume() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            onLog?("工作流 · 恢复执行")
            detailResult = try await mcp.call(name: "resume_execution")
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func markDone(_ step: WorkflowStep) {
        doneSteps.insert(step.rawValue)
        if step == .cleanup {
            finished = true
        } else if let next = WorkflowStep(rawValue: step.rawValue + 1) {
            currentStep = next
        }
    }

    private func extractRequestID(from text: String) {
        guard selectedRequestID.isEmpty else { return }
        let pattern = "reqid=([0-9]+)"
        if let range = text.range(of: pattern, options: .regularExpression) {
            let match = text[range]
            selectedRequestID = match.replacingOccurrences(of: "reqid=", with: "")
        }
    }

    private func extractScriptURL(from text: String) {
        guard selectedScriptURL.isEmpty else { return }
        let pattern = "URL: ([^\\s]+)"
        if let range = text.range(of: pattern, options: .regularExpression) {
            let match = text[range]
            selectedScriptURL = match.replacingOccurrences(of: "URL: ", with: "")
        }
    }
}
