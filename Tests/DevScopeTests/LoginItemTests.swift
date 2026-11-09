import Foundation
import Testing
@testable import DevScope

struct LoginItemTests {
    @Test func createsMissingDirectoriesAndEscapesExecutablePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Library/LaunchAgents/local.devscope.app.plist")
        let binary = "/Applications/开发 & Tools <test>/DevScope.app/Contents/MacOS/DevScope"
        try LoginItem.writeLaunchAgent(binary: binary, at: url)
        let data = try Data(contentsOf: url)
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [binary])
        #expect(plist["Label"] as? String == "local.devscope.app")
        #expect(plist["RunAtLoad"] as? Bool == true)
    }

    @Test func reportsWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        #expect(throws: (any Error).self) {
            try LoginItem.writeLaunchAgent(binary: "/example/DevScope", at: root.appendingPathComponent("agent.plist"))
        }
    }
}
