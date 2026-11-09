import Foundation
import SwiftUI

// MARK: - 角色

enum ServiceRole: String, CaseIterable {
    case frontend = "前端"
    case backend = "后端"
    case database = "数据库"
    case middleware = "中间件"
    case other = "其他"

    var order: Int {
        switch self {
        case .frontend: return 0
        case .backend: return 1
        case .database: return 2
        case .middleware: return 3
        case .other: return 4
        }
    }

    var color: Color {
        switch self {
        case .frontend: return .blue
        case .backend: return .purple
        case .database: return .orange
        case .middleware: return .teal
        case .other: return .gray
        }
    }
}

// MARK: - 健康状态

enum HealthState: String {
    case ok, degraded, down, unknown

    var color: Color {
        switch self {
        case .ok: return .green
        case .degraded: return .orange
        case .down: return .red
        case .unknown: return Color.gray.opacity(0.55)
        }
    }
}

// MARK: - Docker

struct DockerContainer {
    let name: String
    let image: String
    let composeProject: String?
}

// MARK: - 终端宿主（进程由哪个终端应用启动）

enum TerminalKind {
    case appleTerminal   // Terminal.app，支持按 tty 精准定位标签页
    case iterm2          // iTerm2，支持按 tty 定位会话
    case generic         // 其他终端 / IDE：只能激活应用
}

struct TerminalContext {
    let appPath: String
    let displayName: String
    let kind: TerminalKind
    var tty: String?
}

// MARK: - 服务

enum GroupKind: Int {
    case project = 0        // 代码目录（git / 包管理器识别）
    case dockerCompose = 1  // docker compose 项目
    case docker = 2         // 独立 docker 容器
    case standalone = 3     // 独立安装的服务（brew 数据库等）
}

struct ProbeResult {
    var state: HealthState
    var latencyMs: Double?
    var httpStatus: Int?
    var note: String?
}

struct ServiceInfo: Identifiable {
    let id: String          // "pid:port"
    let pid: pid_t
    let port: UInt16
    let bindHost: String    // "*", "127.0.0.1", "::1" ...
    let processName: String
    let command: String
    let workingDirectory: String?
    let role: ServiceRole
    let stack: String
    let projectName: String
    let projectPath: String?
    let projectKey: String
    let groupKind: GroupKind
    let isHTTPCandidate: Bool
    let docker: DockerContainer?
    var terminal: TerminalContext?
    var memoryBytes: UInt64?
    var probe: ProbeResult?

    var displayEndpoint: String { "\(bindHost):\(port)" }

    /// 用于探测 / 打开的 host
    var probeHost: String { bindHost == "*" ? "127.0.0.1" : bindHost }

    var url: String {
        let h = probeHost.contains(":") ? "[\(probeHost)]" : probeHost
        return "http://\(h):\(port)/"
    }

    var copyTarget: String {
        isHTTPCandidate ? url : "\(probeHost):\(port)"
    }
}

struct ProjectGroup: Identifiable {
    let id: String
    let name: String
    let path: String?
    let kind: GroupKind
    let services: [ServiceInfo]
}

// MARK: - 格式化

func formatMemoryBytes(_ bytes: UInt64?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    let mb = Double(bytes) / 1_048_576
    if mb < 10 { return String(format: "%.1f MB", mb) }
    if mb < 1024 { return "\(Int(mb)) MB" }
    return String(format: "%.1f GB", mb / 1024)
}

// MARK: - 分组

func makeGroups(_ services: [ServiceInfo]) -> [ProjectGroup] {
    let dict = Dictionary(grouping: services, by: { $0.projectKey })
    let groups = dict.map { key, list -> ProjectGroup in
        let sorted = list.sorted { a, b in
            if a.role.order != b.role.order { return a.role.order < b.role.order }
            return a.port < b.port
        }
        let representative = sorted.first!
        return ProjectGroup(
            id: key,
            name: representative.projectName,
            path: representative.projectPath,
            kind: representative.groupKind,
            services: sorted
        )
    }
    return groups.sorted { a, b in
        if a.kind.rawValue != b.kind.rawValue { return a.kind.rawValue < b.kind.rawValue }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
