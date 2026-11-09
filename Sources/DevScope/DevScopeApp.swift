import SwiftUI
import AppKit
import Combine

// MARK: - 数据中心：定时扫描 + 健康检查

@MainActor
final class ServiceStore: ObservableObject {
    static let shared = ServiceStore()

    @Published private(set) var groups: [ProjectGroup] = []
    @Published private(set) var allServices: [ServiceInfo] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false

    private var autoTask: Task<Void, Never>?
    private static let refreshInterval: UInt64 = 10_000_000_000 // 10s

    private init() {
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshInterval)
            }
        }
    }

    func refresh() async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var services = await Scanner.scanServices()
        let probes = await HealthChecker.probe(services)
        for index in services.indices {
            services[index].probe = probes[services[index].id]
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            allServices = services
            groups = makeGroups(services)
            lastUpdated = Date()
        }
    }

    /// 乐观移除（点击停止按钮时立即从界面消失）
    func removeService(id: String) {
        guard allServices.contains(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            allServices.removeAll { $0.id == id }
            groups = makeGroups(allServices)
        }
    }
}

// MARK: - 应用委托

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
    }
}

// MARK: - 菜单栏控制器：NSStatusItem + NSPopover（毛玻璃）

@MainActor
final class StatusBarController: NSObject {
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private let store = ServiceStore.shared

    override init() {
        super.init()

        // 1. 菜单栏图标 + 服务计数
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "DevScope") {
                image.isTemplate = true // 跟随菜单栏深浅色
                button.image = image
            }
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.imagePosition = .imageLeading
            button.title = "…"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // 2. 面板内容：SwiftUI 视图 + 系统毛玻璃背景
        let hosting = NSHostingController(
            rootView: PanelView()
                .environmentObject(store)
        )
        let effect = NSVisualEffectView()
        effect.material = .popover          // macOS 原生「毛玻璃」材质，自动适配深浅色
        effect.blendingMode = .behindWindow
        effect.state = .active

        let container = NSView()
        container.addSubview(effect)
        container.addSubview(hosting.view)
        effect.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        popover.behavior = .transient   // 点击面板外自动收起
        popover.animates = true
        popover.contentSize = NSSize(width: PanelMetrics.width, height: PanelMetrics.height(for: []))

        // 失焦自动收起：应用失活 / 面板窗口失去按键状态（如切到其他应用窗口）
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification, object: nil
        )

        // 兜底：全局监听鼠标按下（发送到其他应用的事件）→ 立即收起
        // 覆盖面板窗口未能成为 key 的场景
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }

        // 3. 数据变化 → 更新菜单栏计数与面板尺寸
        store.$groups
            .receive(on: RunLoop.main)
            .sink { [weak self] groups in
                guard let self else { return }
                let count = groups.reduce(0) { $0 + $1.services.count }
                self.statusItem.button?.title = "\(count)"
                self.popover.contentSize = NSSize(
                    width: PanelMetrics.width,
                    height: PanelMetrics.height(for: groups)
                )
            }
            .store(in: &cancellables)
    }

    // 4. 点击展开 / 收起
    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // 打开时若数据较旧（或尚未扫描），立即刷新一次
        if store.lastUpdated == nil || Date().timeIntervalSince(store.lastUpdated ?? .distantPast) > 5 {
            Task { await store.refresh() }
        }
        // 激活应用并让面板窗口成为 key，失焦（resignKey/resignActive）才能可靠触发
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // 失焦自动收起
    @objc private func appDidResignActive() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if popover.isShown, window == popover.contentViewController?.view.window {
            popover.performClose(nil)
        }
    }
}
