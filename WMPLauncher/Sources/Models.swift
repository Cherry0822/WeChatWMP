import Foundation
import AppKit
import SwiftUI

enum LauncherTab: String, CaseIterable, Identifiable {
    case overview
    case services
    case logs
    case versions
    case tools
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .services: return "服务"
        case .logs: return "日志"
        case .versions: return "版本"
        case .tools: return "工具"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .services: return "server.rack"
        case .logs: return "doc.plaintext"
        case .versions: return "slider.horizontal.3"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }
}

enum ServiceState: Equatable {
    case stopped
    case starting
    case stopping
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "已停止"
        case .starting: return "启动中…"
        case .stopping: return "停止中…"
        case .running: return "运行中"
        case .failed: return "失败"
        }
    }

    var isRunning: Bool { self == .running }
    var isBusy: Bool { self == .starting || self == .stopping }
}

struct EnvCheckItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let status: Status
    var suggestion = ""

    enum Status {
        case ok, warn, fail
    }
}

struct EnvironmentSnapshot {
    var checks: [EnvCheckItem] = []
    var nodePath: String = "node"
    var pythonPath: String = "python3"
    var wechatVersion: String = "未知"
    var arch: String = ""
    var wechatAppExRunning = false

    var okCount: Int { checks.filter { $0.status == .ok }.count }
    var warnCount: Int { checks.filter { $0.status == .warn }.count }
    var failCount: Int { checks.filter { $0.status == .fail }.count }
}

struct ToolInfo: Identifiable {
    let id = UUID()
    let name: String
    let group: String
    let groupIcon: String
    let desc: String
    let params: [String]
}

enum ToolCatalog {
    static let all: [ToolInfo] = [
        ToolInfo(name: "list_network_requests", group: "网络抓包", groupIcon: "wifi",
                 desc: "自动连接 CDP 并监控当前 target 的 XHR/Fetch，返回请求列表或单条详情（最新在前，默认 20 条/页）。",
                 params: ["endpoint", "reqid", "url_filter", "resource_types", "wait_ms", "clear_existing", "page_size", "page_idx"]),
        ToolInfo(name: "get_response_body", group: "网络抓包", groupIcon: "wifi",
                 desc: "读取某个请求的响应体（超过 10KB 截断，二进制显示 <binary data>）。",
                 params: ["request_id"]),
        ToolInfo(name: "get_request_post_data", group: "网络抓包", groupIcon: "wifi",
                 desc: "读取某个请求的 POST 数据（默认截断 20KB）。",
                 params: ["request_id", "max_size"]),
        ToolInfo(name: "get_request_initiator", group: "网络抓包", groupIcon: "wifi",
                 desc: "查看发起该请求的 JS 调用栈，用于溯源。",
                 params: ["request_id"]),
        ToolInfo(name: "get_websocket_messages", group: "网络抓包", groupIcon: "wifi",
                 desc: "列出 WebSocket 连接，或查看某个连接的收发帧。",
                 params: ["wsid", "direction", "show_content", "page_size", "page_idx"]),

        ToolInfo(name: "list_scripts", group: "源码分析", groupIcon: "doc.text.magnifyingglass",
                 desc: "列出当前页面已加载的 JS（含 URL 和 SourceMap 信息）。",
                 params: ["url_filter"]),
        ToolInfo(name: "get_script_source", group: "源码分析", groupIcon: "doc.text.magnifyingglass",
                 desc: "按 URL 或 script ID 读取源码片段；普通文件按行区间，压缩文件用 offset/length。",
                 params: ["url / script_id", "start_line / end_line 或 offset / length"]),
        ToolInfo(name: "save_script_source", group: "源码分析", groupIcon: "doc.text.magnifyingglass",
                 desc: "把完整源码保存到本地文件（WASM 脚本保存为 .wasm）。",
                 params: ["file_path", "url / script_id"]),
        ToolInfo(name: "search_in_sources", group: "源码分析", groupIcon: "doc.text.magnifyingglass",
                 desc: "在所有已加载源码中搜索字符串或正则，返回命中的脚本、行号和内容。",
                 params: ["query", "is_regex", "exclude_minified", "url_filter", "max_results"]),
        ToolInfo(name: "evaluate_script", group: "源码分析", groupIcon: "doc.text.magnifyingglass",
                 desc: "执行 JS 表达式；暂停时自动在指定调用帧上下文求值。",
                 params: ["expression", "await_promise", "context_id", "frame_index"]),

        ToolInfo(name: "break_on_xhr", group: "断点调试", groupIcon: "ladybug",
                 desc: "当 XHR/Fetch 请求 URL 包含指定字符串时暂停。",
                 params: ["url"]),
        ToolInfo(name: "set_breakpoint_on_text", group: "断点调试", groupIcon: "ladybug",
                 desc: "在文本首次出现的位置设置代码断点（仅第一个匹配）。注意：不要设在函数名或赋值处。",
                 params: ["text", "condition", "case_sensitive"]),
        ToolInfo(name: "set_event_listener_breakpoint", group: "断点调试", groupIcon: "ladybug",
                 desc: "设置 DOM 事件监听断点（如 click、input）。",
                 params: ["event_name", "target_name"]),
        ToolInfo(name: "list_breakpoints", group: "断点调试", groupIcon: "ladybug",
                 desc: "查看全部 XHR / 代码 / 事件断点。",
                 params: []),
        ToolInfo(name: "remove_breakpoints", group: "断点调试", groupIcon: "ladybug",
                 desc: "按 ID / URL 删除断点，或 clear_all 清空全部。",
                 params: ["breakpoint_id", "xhr_url", "clear_all"]),
        ToolInfo(name: "get_paused_info", group: "断点调试", groupIcon: "ladybug",
                 desc: "暂停时查看调用栈与作用域变量。",
                 params: ["frame_index", "include_scopes", "max_scope_depth"]),
        ToolInfo(name: "resume_execution", group: "断点调试", groupIcon: "ladybug",
                 desc: "恢复执行。",
                 params: []),
        ToolInfo(name: "step", group: "断点调试", groupIcon: "ladybug",
                 desc: "单步执行：over / into / out。",
                 params: ["action"]),
        ToolInfo(name: "remove_event_listener_breakpoint", group: "断点调试", groupIcon: "ladybug",
                 desc: "删除指定的事件监听断点。",
                 params: ["event_name", "target_name"]),

        ToolInfo(name: "get_runtime_events", group: "运行时与性能", groupIcon: "cpu",
                 desc: "获取捕获的 console / exception / execution context 事件。",
                 params: ["event_type", "clear", "limit"]),
        ToolInfo(name: "start_cpu_profile", group: "运行时与性能", groupIcon: "cpu",
                 desc: "启动 CPU 采样，定位热点函数。",
                 params: ["sampling_interval"]),
        ToolInfo(name: "stop_cpu_profile", group: "运行时与性能", groupIcon: "cpu",
                 desc: "停止采样并汇总热点函数。",
                 params: ["limit", "include_profile"]),
        ToolInfo(name: "precise_coverage", group: "运行时与性能", groupIcon: "cpu",
                 desc: "精确覆盖率控制：start / take / stop。",
                 params: ["action", "reset", "limit"]),

        ToolInfo(name: "list_targets", group: "目标切换", groupIcon: "scope",
                 desc: "列出当前所有 target（AppService、WebView 等）。",
                 params: []),
        ToolInfo(name: "switch_target", group: "目标切换", groupIcon: "scope",
                 desc: "切换到指定 target 线程（会清空记录与断点）。",
                 params: ["target_id"])
    ]

    static func groups() -> [(name: String, icon: String, tools: [ToolInfo])] {
        let names = ["网络抓包", "源码分析", "断点调试", "运行时与性能", "目标切换"]
        return names.compactMap { name in
            let tools = all.filter { $0.group == name }
            guard let first = tools.first else { return nil }
            return (name, first.groupIcon, tools)
        }
    }
}
