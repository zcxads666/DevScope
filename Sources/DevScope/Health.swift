import Foundation
import Network

// MARK: - 健康检查

enum HealthChecker {
    /// NWConnection 状态回调与超时可能同时完成，只恢复一次 continuation。
    private final class TCPCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Double?, Never>?

        init(_ continuation: CheckedContinuation<Double?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: Double?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

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
            let completion = TCPCompletion(continuation)
            let start = Date()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(Date().timeIntervalSince(start) * 1000)
                    connection.cancel()
                case .failed:
                    completion.finish(nil)
                    connection.cancel()
                case .cancelled:
                    completion.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "devscope.tcp"))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                completion.finish(nil)
                connection.cancel()
            }
        }
    }
}
