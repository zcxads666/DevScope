import Foundation
import Darwin

enum Shell {
    struct Result {
        let stdout: String?
        let stderr: String?
        let code: Int32
        var success: Bool { code == 0 }
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> String? {
        let result = await runEx(path, arguments, timeout: timeout)
        return result.success ? (result.stdout ?? "") : nil
    }

    @discardableResult
    static func runEx(_ path: String, _ arguments: [String], timeout: TimeInterval) async -> Result {
        guard timeout.isFinite, timeout > 0 else {
            return Result(stdout: nil, stderr: nil, code: -1)
        }
        return await withCheckedContinuation { continuation in
            let command = Command(path: path, arguments: arguments, timeout: timeout, continuation: continuation)
            command.queue.async { command.start() }
        }
    }

    /// 所有可变状态仅在 queue 上访问；非阻塞管道同时读取 stdout / stderr。
    private final class Command: @unchecked Sendable {
        let queue = DispatchQueue(label: "devscope.command", qos: .utility)
        private let process = Process()
        private let out = Pipe()
        private let err = Pipe()
        private let timeout: TimeInterval
        private var continuation: CheckedContinuation<Result, Never>?
        private var readers: [DispatchSourceRead] = []
        private var deadline: DispatchWorkItem?
        private var stdout = Data()
        private var stderr = Data()
        private var closedStreams = 0
        private var exited = false

        init(path: String, arguments: [String], timeout: TimeInterval,
             continuation: CheckedContinuation<Result, Never>) {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            self.timeout = timeout
            self.continuation = continuation
        }

        func start() {
            process.terminationHandler = { [self] _ in
                queue.async { [self] in
                    exited = true
                    completeIfReady()
                }
            }
            do {
                try process.run()
            } catch {
                try? out.fileHandleForWriting.close()
                try? err.fileHandleForWriting.close()
                try? out.fileHandleForReading.close()
                try? err.fileHandleForReading.close()
                finish(Result(stdout: nil, stderr: error.localizedDescription, code: -1))
                return
            }
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            read(out.fileHandleForReading, isStdout: true)
            read(err.fileHandleForReading, isStdout: false)
            guard continuation != nil else { return }

            let deadline = DispatchWorkItem { [weak self] in self?.timedOut() }
            self.deadline = deadline
            queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        }

        private func read(_ handle: FileHandle, isStdout: Bool) {
            guard continuation != nil else {
                try? handle.close()
                return
            }
            let fd = handle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
                try? handle.close()
                timedOut()
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setCancelHandler { try? handle.close() }
            source.setEventHandler { [self, weak source] in
                guard continuation != nil else { return }
                var buffer = [UInt8](repeating: 0, count: 16_384)
                // 持续大量输出时也要让出队列，保证超时回调能执行。
                for _ in 0..<16 {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if count > 0 {
                        if isStdout { stdout.append(contentsOf: buffer.prefix(count)) }
                        else { stderr.append(contentsOf: buffer.prefix(count)) }
                    } else if count == -1 && errno == EINTR {
                        continue
                    } else if count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        return
                    } else {
                        source?.setEventHandler(handler: nil)
                        source?.cancel()
                        closedStreams += 1
                        completeIfReady()
                        return
                    }
                }
            }
            readers.append(source)
            source.resume()
        }

        private func completeIfReady() {
            guard exited, closedStreams == 2 else { return }
            finish(Result(stdout: String(data: stdout, encoding: .utf8),
                          stderr: String(data: stderr, encoding: .utf8),
                          code: process.terminationStatus))
        }

        private func timedOut() {
            guard continuation != nil else { return }
            if process.isRunning {
                process.terminate()
                // 忽略 SIGTERM 的命令也必须被回收；不等待其退出才返回。
                queue.asyncAfter(deadline: .now() + 0.2) { [process] in
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            finish(Result(stdout: nil, stderr: nil, code: -1))
        }

        private func finish(_ result: Result) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel()
            deadline = nil
            process.terminationHandler = nil
            for reader in readers {
                reader.setEventHandler(handler: nil)
                reader.cancel()
            }
            readers.removeAll()
            continuation.resume(returning: result)
        }
    }
}
