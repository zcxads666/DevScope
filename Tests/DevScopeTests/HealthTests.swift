import Foundation
import Testing
import Network
@testable import DevScope

struct HealthTests {
    @Test func tcpProbeAndTimeoutRaceCompleteOnce() async throws {
        let queue = DispatchQueue(label: "devscope.test.listener")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        }
        listener.start(queue: queue)
        for _ in 0..<60 {
            if listener.state == .ready { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(listener.state == .ready)
        let port = try #require(listener.port?.rawValue)
        try #require(port > 0)
        let latency = await HealthChecker.tcpPing(host: "127.0.0.1", port: port)
        #expect(latency != nil)
        // 同时安排立即超时和真实连接完成，不能重复恢复 continuation。
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = await HealthChecker.tcpPing(host: "127.0.0.1", port: port, timeout: 0)
                }
            }
        }
    }
}
