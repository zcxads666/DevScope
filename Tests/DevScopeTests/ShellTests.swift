import Foundation
import Testing
import Darwin
@testable import DevScope

struct ShellTests {
    @Test func capturesBothStreamsAndExitStatus() async {
        let result = await Shell.runEx("/bin/sh", ["-c", "printf output; printf problem >&2; exit 7"], timeout: 3)
        #expect(result.stdout == "output")
        #expect(result.stderr == "problem")
        #expect(result.code == 7)
        #expect(!result.success)
    }

    @Test func drainsLargeOutputsWithoutBlocking() async {
        let script = "BEGIN {for(i=0;i<20000;i++){print \"stdout\"; print \"stderr\" > \"/dev/stderr\"}}"
        let result = await Shell.runEx("/usr/bin/awk", [script], timeout: 5)
        #expect(result.success)
        #expect(result.stdout?.utf8.count == 140_000)
        #expect(result.stderr?.utf8.count == 140_000)
    }

    @Test func launchFailureReturnsError() async {
        let result = await Shell.runEx("/nonexistent/devscope-command", [], timeout: 1)
        #expect(result.code == -1)
        #expect(result.stderr != nil)
    }

    @Test func timeoutIncludesProcessExitAfterPipesClose() async {
        let start = Date()
        let result = await Shell.runEx("/bin/sh", ["-c", "exec 1>&- 2>&-; exec /bin/sleep 30"], timeout: 0.2)
        #expect(result.code == -1)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func timeoutClosesPipesInheritedByDescendants() async {
        let start = Date()
        let result = await Shell.runEx("/bin/sh", ["-c", "/bin/sleep 0.8 & exit 0"], timeout: 0.1)
        #expect(result.code == -1)
        #expect(Date().timeIntervalSince(start) < 0.7)
    }

    @Test func forceKillsProcessIgnoringTermination() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        // 路径通过参数传入，避免将路径插入 shell 脚本。
        let script = "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 30"
        let result = await Shell.runEx("/bin/sh", ["-c", script, "devscope-test", file.path], timeout: 0.3)
        #expect(result.code == -1)
        let pid = try #require(pid_t(String(contentsOf: file, encoding: .utf8)))
        // 超时返回后给强制终止及系统回收留出时间。
        for _ in 0..<20 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed-out process was not reaped")
    }

    @Test func concurrentCommandsKeepTheirOwnOutput() async {
        await withTaskGroup(of: (Int, String?).self) { group in
            for index in 0..<12 {
                group.addTask {
                    (index, await Shell.run("/usr/bin/printf", ["%s", String(index)], timeout: 3))
                }
            }
            for await (index, output) in group { #expect(output == String(index)) }
        }
    }

    @Test func rejectsInvalidTimeouts() async {
        for timeout in [0, -1, Double.infinity, Double.nan] {
            let result = await Shell.runEx("/usr/bin/true", [], timeout: timeout)
            #expect(result.code == -1)
        }
    }
}
