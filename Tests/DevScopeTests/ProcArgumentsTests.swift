import Foundation
import Testing
@testable import DevScope

struct ProcArgumentsTests {
    private func buffer(_ arguments: [String], environment: [String] = []) -> [UInt8] {
        var argc = Int32(arguments.count)
        var result = withUnsafeBytes(of: &argc) { Array($0) }
        result += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
        for argument in arguments { result += Array(argument.utf8) + [0] }
        result += [0]
        for value in environment { result += Array(value.utf8) + [0] }
        return result
    }

    @Test func skipsExecutablePathAndKeepsLastArgument() {
        let arguments = ["node", "/work/api/server.js", "--port", "3000"]
        #expect(ProcUtil.parseArguments(buffer(arguments)) == arguments)
    }

    @Test func preservesEmptyArgumentsAndUnicode() {
        let arguments = ["node", "", "/项目/我的服务.js", ""]
        #expect(ProcUtil.parseArguments(buffer(arguments)) == arguments)
    }

    @Test func doesNotReadEnvironmentAsArguments() {
        #expect(ProcUtil.parseArguments(buffer(["node"], environment: ["TOKEN=secret"])) == ["node"])
    }

    @Test func rejectsInvalidBuffers() {
        #expect(ProcUtil.parseArguments([]).isEmpty)
        #expect(ProcUtil.parseArguments([1, 0, 0]).isEmpty)
        #expect(ProcUtil.parseArguments([255, 255, 255, 255, 0]).isEmpty)
        let truncated = Array(buffer(["node", "server.js"]).dropLast(2))
        #expect(ProcUtil.parseArguments(truncated).isEmpty)
    }
}
