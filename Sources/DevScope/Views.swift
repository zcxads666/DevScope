import SwiftUI
import AppKit

// MARK: - 面板尺寸（NSPopover 需要确定的高度，ScrollView 自适应会塌陷为 0）

enum PanelMetrics {
    static let width: CGFloat = 380

    static func height(for groups: [ProjectGroup]) -> CGFloat {
        let headerH: CGFloat = 46
        let footerH: CGFloat = 20
        let outerH: CGFloat = 24
        let cardSpacing: CGFloat = 10

        var total = outerH + headerH + footerH + cardSpacing * CGFloat(groups.count + 1)
        for group in groups {
            total += 44 + 44 * CGFloat(group.services.count) // 内边距+卡片头 + 每行
        }
        if groups.isEmpty { total += 150 } // 空状态
        return min(max(total, 240), 620)
    }
}

// MARK: - 下拉面板

struct PanelView: View {
    @EnvironmentObject private var store: ServiceStore

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                HeaderView()
                if store.groups.isEmpty {
                    EmptyStateView()
                } else {
                    ForEach(store.groups) { group in
                        ProjectCard(group: group)
                    }
                }
                FooterView()
            }
            .padding(12)
        }
        .frame(
            width: PanelMetrics.width,
            height: PanelMetrics.height(for: store.groups)
        )
        // 毛玻璃背景由 NSPopover 内的 NSVisualEffectView 提供
    }
}

// MARK: - 头部

struct HeaderView: View {
    @EnvironmentObject private var store: ServiceStore

    private var subtitle: String {
        "\(store.groups.count) 个项目 · \(store.allServices.count) 个服务"
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.02, green: 0.71, blue: 0.65), location: 0),
                        .init(color: Color(red: 0.00, green: 0.42, blue: 0.52), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .white.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "stethoscope")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("DevScope")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let time = store.lastUpdated {
                    Text("更新于 \(time.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("重新扫描")
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 项目卡片

struct ProjectCard: View {
    let group: ProjectGroup

    private var kindTag: String? {
        switch group.kind {
        case .dockerCompose: return "Compose"
        case .docker: return "Docker"
        case .standalone: return "本地"
        case .project: return nil
        }
    }

    private var groupIcon: String {
        switch group.kind {
        case .project: return "folder.fill"
        case .dockerCompose, .docker: return "shippingbox.fill"
        case .standalone: return "cylinder.split.1x2.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 卡片头：项目名
            HStack(spacing: 6) {
                Image(systemName: groupIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let tag = kindTag {
                    MiniTag(text: tag)
                }
                Spacer(minLength: 4)
                Text("\(group.services.count) 个服务")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let path = group.path {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(path.isEmpty ? "在 Finder 中显示" : "在 Finder 中显示：\(path)")
                }
            }
            .padding(.horizontal, 4)

            // 服务列表
            VStack(spacing: 0) {
                ForEach(Array(group.services.enumerated()), id: \.element.id) { index, service in
                    ServiceRow(service: service)
                    if index < group.services.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 0.5)
                            .padding(.leading, 22)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - 服务行

struct ServiceRow: View {
    let service: ServiceInfo
    @EnvironmentObject private var store: ServiceStore

    private var secondaryLine: String {
        if let container = service.docker {
            return "\(service.displayEndpoint) · \(container.name)"
        }
        return "\(service.displayEndpoint) · \(service.processName) · PID \(service.pid)"
    }

    private var statusText: String {
        guard let probe = service.probe else { return "未检测" }
        switch probe.state {
        case .ok:
            var parts = ["运行正常"]
            if let code = probe.httpStatus { parts.append("HTTP \(code)") }
            if let ms = probe.latencyMs { parts.append(formatLatency(ms)) }
            return parts.joined(separator: " · ")
        case .degraded:
            var parts = [probe.note ?? "响应异常"]
            if let code = probe.httpStatus { parts.append("HTTP \(code)") }
            return parts.joined(separator: " · ")
        case .down:
            return probe.note ?? "无法连接"
        case .unknown:
            return "未检测"
        }
    }

    /// 状态点颜色：绿=响应快(<200ms) 黄=较慢(200ms–1s) 红=极慢(≥1s)/不可达
    private var dotColor: Color {
        guard let probe = service.probe else { return Color.gray.opacity(0.55) }
        switch probe.state {
        case .down:
            return .red
        case .degraded:
            return .orange
        case .unknown:
            return Color.gray.opacity(0.55)
        case .ok:
            guard let ms = probe.latencyMs else { return .green }
            if ms < 200 { return .green }
            if ms < 1000 { return .orange }
            return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: dotColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    RoleBadge(role: service.role)
                    Text(service.stack)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(secondaryLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if let memory = formatMemoryBytes(service.memoryBytes) {
                Text(memory)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            actionButtons
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .help(service.command)
    }

    // MARK: 操作按钮

    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 4) {
            // 浏览器：仅前端
            if service.role == .frontend && service.isHTTPCandidate {
                CircleIconButton(icon: "safari", tint: .blue, help: "在浏览器打开 \(service.url)") {
                    if let url = URL(string: service.url) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            // 终端 / Docker
            if service.docker != nil {
                CircleIconButton(icon: "shippingbox", tint: .accentColor, help: "打开 Docker Desktop") {
                    Actions.openDockerApp()
                }
            } else if let term = service.terminal {
                // 仅当检测到终端宿主时显示（可直达原始终端）
                CircleIconButton(icon: "terminal", help: "转到 \(term.displayName) 中的原始终端（查看运行日志）") {
                    Task { await Actions.focusTerminal(of: service) }
                }
            }
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            Task {
                // 乐观移除：立即从面板消失
                store.removeService(id: service.id)
                if let container = service.docker {
                    await Actions.stopDockerContainer(container.name)
                } else {
                    await Actions.stopProcess(service.pid)
                }
                await store.refresh()
            }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.red)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.red.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(service.docker != nil
              ? "停止容器 \(service.docker?.name ?? "")"
              : "终止进程（PID \(service.pid)，先 SIGTERM 后强制）")
    }

    private func formatLatency(_ ms: Double) -> String {
        if ms < 1000 {
            return "\(Int(ms.rounded())) ms"
        }
        return String(format: "%.1f s", ms / 1000)
    }
}

// MARK: - 小组件

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.55), radius: color == .green ? 3.5 : 1.5)
    }
}

struct RoleBadge: View {
    let role: ServiceRole

    var body: some View {
        Text(role.rawValue)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(role.color.opacity(0.16)))
            .foregroundStyle(role.color)
            .overlay(Capsule().strokeBorder(role.color.opacity(0.22), lineWidth: 0.5))
    }
}

struct MiniTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct CircleIconButton: View {
    let icon: String
    var tint: Color = .secondary
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
            Text("未检测到正在运行的服务")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("启动你的前端、后端或数据库后\n它们会自动出现在这里")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 底部

struct FooterView: View {
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        HStack(spacing: 6) {
            Text("每 10 秒自动刷新")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 5) {
                Text("开机自启")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                        } catch {
                            let alert = NSAlert(error: error)
                            alert.messageText = "无法设置开机自启"
                            alert.runModal()
                        }
                        launchAtLogin = LoginItem.isEnabled   // 同步真实状态
                    }
                    .disabled(!LoginItem.isBundleApp)
            }
            .help("登录 macOS 后自动在菜单栏启动 DevScope（可在系统设置 → 登录项中管理）")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("退出")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("退出 DevScope")
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }
}
