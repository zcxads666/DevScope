import Foundation
import AppKit
import ServiceManagement

// 入口：支持 `--scan` / `--json` 命令行模式（打印检测结果），
// 无参数时启动菜单栏应用（NSStatusItem + NSPopover）。
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--login"), arguments.count > index + 1 {
    let enable = arguments[index + 1].lowercased() != "off"
    do {
        try LoginItem.setEnabled(enable)
    } catch {
        FileHandle.standardError.write(Data("开机自启设置失败：\(error.localizedDescription)\n".utf8))
        exit(1)
    }
    print("开机自启: \(LoginItem.isEnabled ? "已开启 ✓" : "未开启")（SMAppService=\(SMAppService.mainApp.status == .enabled ? "on" : "off")，LaunchAgent=\(FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/local.devscope.app.plist") ? "on" : "off")）")
    exit(0)
}
if arguments.contains("--scan") || arguments.contains("--json") {
    CLI.main(json: arguments.contains("--json"))
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
