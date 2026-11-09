import Foundation
import ServiceManagement

// MARK: - 开机自启
// 优先 SMAppService（系统「登录项」机制，系统设置可见）；
// ad-hoc 签名等场景注册失败时，回退到用户级 LaunchAgent。

enum LoginItem {
    private static let agentLabel = "local.devscope.app"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// 是否以 .app 包方式运行（裸二进制无法注册登录项）
    static var isBundleApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isBundleApp else { return }

        if enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                // 注册失败 → 回退 LaunchAgent
                try? SMAppService.mainApp.unregister()
                try installLaunchAgent()
                return
            }
            try removeLaunchAgent()   // 防止与回退方案双启动
        } else {
            try removeLaunchAgent()
            if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    // MARK: LaunchAgent 回退（仅写 plist，登录时由 launchd 拉起；不立即加载以免双开）

    private static func installLaunchAgent() throws {
        let binary = Bundle.main.bundlePath + "/Contents/MacOS/DevScope"
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: binary])
        }
        try writeLaunchAgent(binary: binary, at: agentURL)
    }

    static func writeLaunchAgent(binary: String, at url: URL) throws {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [binary],
            "RunAtLoad": true,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func removeLaunchAgent() throws {
        do {
            try FileManager.default.removeItem(at: agentURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // 未使用回退方案时无需删除。
        }
    }
}
