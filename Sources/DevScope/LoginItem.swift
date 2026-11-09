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

    static func setEnabled(_ enabled: Bool) {
        guard isBundleApp else { return }

        if enabled {
            do {
                try SMAppService.mainApp.register()
                removeLaunchAgent()   // 防止与回退方案双启动
                return
            } catch {
                // 注册失败 → 回退 LaunchAgent
            }
            try? SMAppService.mainApp.unregister()
            installLaunchAgent()
        } else {
            removeLaunchAgent()
            try? SMAppService.mainApp.unregister()
        }
    }

    // MARK: LaunchAgent 回退（仅写 plist，登录时由 launchd 拉起；不立即加载以免双开）

    private static func installLaunchAgent() {
        let binary = Bundle.main.bundlePath + "/Contents/MacOS/DevScope"
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(agentLabel)</string>
            <key>ProgramArguments</key>
            <array><string>\(binary)</string></array>
            <key>RunAtLoad</key><true/>
            <key>ProcessType</key><string>Background</string>
        </dict>
        </plist>
        """
        try? plist.write(to: agentURL, atomically: true, encoding: .utf8)
    }

    private static func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: agentURL)
    }
}
