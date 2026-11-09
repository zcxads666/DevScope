import AppKit
import Darwin

// MARK: - 服务快捷操作

enum Actions {
    /// 在 Terminal.app 中打开目录（定位到进程工作目录）
    /// 通过 Launch Services「以应用打开文件夹」实现，无需 AppleScript 自动化权限
    static func openTerminal(at path: String) {
        let folder = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()

        // 优先按 bundle id 定位 Terminal.app
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: configuration)
            return
        }
        // 兜底：open -a Terminal <dir>
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal", path]
        try? task.run()
    }

    /// 直达进程所在的**原始终端**窗口/标签页（进程日志就在那里输出）
    static func focusTerminal(of service: ServiceInfo) async {
        guard let term = service.terminal else {
            // 无终端宿主（如 launchd / pm2 detached）：退回「在目录打开新终端」
            if let path = service.workingDirectory ?? service.projectPath {
                openTerminal(at: path)
            }
            return
        }

        // 支持脚本控制的终端：按 tty 精准定位到对应窗口/标签页
        if let tty = term.tty {
            switch term.kind {
            case .appleTerminal:
                if await selectAppleTerminalTab(appPath: term.appPath, tty: tty) { return }
            case .iterm2:
                if await selectITermSession(tty: tty) { return }
            case .generic:
                break
            }
        }

        // 无法精准定位 → 至少激活宿主终端应用
        _ = try? await NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: term.appPath),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: Terminal.app 标签页定位

    @discardableResult
    private static func selectAppleTerminalTab(appPath: String, tty: String) async -> Bool {
        let short = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    set theTty to tty of t
                    if theTty is "\(tty)" or theTty is "\(short)" then
                        set selected tab of w to t
                        set index of w to 1
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        let result = await Shell.runEx("/usr/bin/osascript", ["-e", script], timeout: 30)
        if result.success {
            return (result.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        showAutomationHelpIfNeeded(stderr: result.stderr ?? "")
        return false
    }

    // MARK: iTerm2 会话定位

    @discardableResult
    private static func selectITermSession(tty: String) async -> Bool {
        let short = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set theTty to tty of s
                        if theTty is "\(tty)" or theTty is "\(short)" then
                            select w
                            select t
                            select s
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
        let result = await Shell.runEx("/usr/bin/osascript", ["-e", script], timeout: 30)
        if result.success {
            return (result.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        showAutomationHelpIfNeeded(stderr: result.stderr ?? "")
        return false
    }

    // MARK: 自动化授权引导（仅授权失败时提示一次）

    private static var shownAutomationHelp = false

    private static func showAutomationHelpIfNeeded(stderr: String) {
        let text = stderr.lowercased()
        guard text.contains("not authorized") || text.contains("-1743") else { return }
        DispatchQueue.main.async {
            guard !shownAutomationHelp else { return }
            shownAutomationHelp = true
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "无法直达原始终端窗口"
            alert.informativeText = "需要授权 DevScope 控制终端：\n系统设置 → 隐私与安全性 → 自动化 → DevScope → 勾选「终端」，然后再次点击即可。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// 停止本地进程：SIGTERM 优雅退出，1.5s 后仍存活则 SIGKILL 强制终止
    static func stopProcess(_ pid: pid_t) async {
        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if kill(pid, 0) == 0 {   // 进程仍存在
            kill(pid, SIGKILL)
        }
    }

    /// 停止 Docker 容器
    static func stopDockerContainer(_ name: String) async {
        guard let docker = Scanner.dockerExecutablePath() else { return }
        _ = await Shell.run(docker, ["stop", name], timeout: 20)
    }

    /// 打开 Docker Desktop
    static func openDockerApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Docker"]
        try? task.run()
    }
}
