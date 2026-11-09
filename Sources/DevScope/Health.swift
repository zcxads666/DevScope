import Foundation
import Network

// MARK: - 健康检查

enum HealthChecker {
    static func probe(_ services: [ServiceInfo]) async -> [String: ProbeResult] {
        await withTaskGroup(of: (String, ProbeResult?).self) { group in
            for service in services {
                group.addTask {
                    if service.isHTTPCandidate {
                        return (service.id, await httpProbe(service))
                    }
                    if let ms = await tcpPing(host: service.probeHost, port: service.port) {
                        return (service.id, ProbeResult(state: .ok, latencyMs: ms, httpStatus: nil, note: "TCP"))
                    }
                    return (service.id, ProbeResult(state: .down, latencyMs: nil, httpStatus: nil, note: "无法连接"))
                }
            }
            var results: [String: ProbeResult] = [:]
            for await (id, result) in group {
                if let result = result { results[id] = result }
            }
            return results
        }
    }

    static func httpProbe(_ service: ServiceInfo) async -> ProbeResult? {
        guard let url = URL(string: service.url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Date().timeIntervalSince(start) * 1000
            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(state: .ok, latencyMs: ms, httpStatus: nil, note: nil)
            }
            if http.statusCode >= 500 {
                return ProbeResult(state: .degraded, latencyMs: ms, httpStatus: http.statusCode, note: "HTTP \(http.statusCode)")
            }
            return ProbeResult(state: .ok, latencyMs: ms, httpStatus: http.statusCode, note: nil)
        } catch {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                return ProbeResult(state: .down, latencyMs: nil, httpStatus: nil, note: "响应超时")
            }
            return ProbeResult(state: .down, latencyMs: nil, httpStatus: nil, note: "无法连接")
        }
    }

    static func tcpPing(host: String, port: UInt16, timeout: TimeInterval = 2.0) async -> Double? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            let lock = NSLock()
            var finished = false
            func finish(_ value: Double?) {
                lock.lock()
                let already = finished
                finished = true
                lock.unlock()
                if !already { continuation.resume(returning: value) }
            }
            let start = Date()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    finish(Date().timeIntervalSince(start) * 1000)
                case .failed:
                    finish(nil)
                case .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "devscope.tcp"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
            }
        }
    }
}
