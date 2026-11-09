import Foundation

// MARK: - 命令行模式：`DevScope --scan`（文本）/ `DevScope --json`

enum CLI {
    static func main(json: Bool) {
        let services = syncAwait { await Scanner.scanServices() }
        let probes = syncAwait { await HealthChecker.probe(services) }
        var scanned = services
        for index in scanned.indices {
            scanned[index].probe = probes[scanned[index].id]
        }
        let groups = makeGroups(scanned)
        if json {
            printJSON(scanned)
        } else {
            printText(groups)
        }
    }

    private final class Ref<T>: @unchecked Sendable {
        var value: T?
    }

    static func syncAwait<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let ref = Ref<T>()
        Task.detached {
            ref.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return ref.value!
    }

    // MARK: 文本输出

    private static func printText(_ groups: [ProjectGroup]) {
        print("DevScope · 本机服务扫描")
        print("══════════════════════════════════════")
        if groups.isEmpty {
            print("（未检测到正在运行的本地服务）")
            return
        }
        for group in groups {
            let location = group.path.map { " — \($0)" } ?? ""
            print("■ \(group.name)\(location)")
            for service in group.services {
                let state = service.probe?.state ?? .unknown
                let dot = statusDot(state)
                let memory = formatMemoryBytes(service.memoryBytes) ?? "—"
                let detail = service.probe?.httpStatus.map { "HTTP \($0)" } ?? (service.isHTTPCandidate ? "" : "TCP")
                let padding = String(repeating: " ", count: max(1, 6 - service.role.rawValue.count))
                print("  \(dot) \(service.role.rawValue)\(padding)\(service.stack.padded(to: 18)) \(service.displayEndpoint.padded(to: 21)) \(detail.padded(to: 9)) \(memory)")
                if state == .down, let note = service.probe?.note {
                    print("     ↳ \(note)")
                }
            }
            print()
        }
    }

    private static func statusDot(_ state: HealthState) -> String {
        switch state {
        case .ok: return "\u{001B}[32m●\u{001B}[0m"
        case .degraded: return "\u{001B}[33m●\u{001B}[0m"
        case .down: return "\u{001B}[31m●\u{001B}[0m"
        case .unknown: return "\u{001B}[90m●\u{001B}[0m"
        }
    }

    private static func formatLatency(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded()))ms" : String(format: "%.1fs", ms / 1000)
    }

    // MARK: JSON 输出

    private static func printJSON(_ services: [ServiceInfo]) {
        var output: [[String: Any]] = []
        for service in services {
            var item: [String: Any] = [
                "id": service.id,
                "project": service.projectName,
                "projectPath": service.projectPath ?? NSNull(),
                "role": service.role.rawValue,
                "stack": service.stack,
                "endpoint": service.displayEndpoint,
                "port": Int(service.port),
                "pid": Int(service.pid),
                "process": service.processName,
                "command": service.command,
                "state": (service.probe?.state ?? .unknown).rawValue,
                "terminal": service.terminal.map { [
                    "app": $0.displayName,
                    "kind": "\($0.kind)",
                    "tty": $0.tty ?? NSNull(),
                ] as [String: Any] } ?? NSNull(),
                "memoryMB": service.memoryBytes.map { Double(round(Double($0) / 10485.76) / 100) } ?? NSNull(),
            ]
            if let probe = service.probe {
                item["latencyMs"] = probe.latencyMs.map { Double(round($0 * 10) / 10) } ?? NSNull()
                item["httpStatus"] = probe.httpStatus ?? NSNull()
                item["note"] = probe.note ?? NSNull()
            }
            output.append(item)
        }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}

extension String {
    func padded(to length: Int) -> String {
        if count >= length { return self + " " }
        return self + String(repeating: " ", count: length - count)
    }
}
