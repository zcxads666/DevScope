import Foundation
import Darwin

// MARK: - 原生进程信息（sysctl / libproc，无需 ps）

enum ProcUtil {
    static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, 4096)
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    static func arguments(for pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return [] }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let total = min(Int(size), buf.count)
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var args: [String] = []
        var i = 4
        while args.count < Int(argc) && i < total {
            while i < total && buf[i] == 0 { i += 1 }
            guard i < total else { break }
            let start = i
            while i < total && buf[i] != 0 { i += 1 }
            let bytes = buf[start..<i].map { UInt8(bitPattern: $0) }
            args.append(String(decoding: bytes, as: UTF8.self))
        }
        return args
    }

    static func currentDirectory(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r > 0 else { return nil }
        var data = withUnsafeBytes(of: info.pvi_cdir.vip_path) { Data($0) }
        if let zero = data.firstIndex(of: 0) { data = data[data.startIndex..<zero] }
        return String(data: data, encoding: .utf8)
    }

    static func userID(for pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard r > 0 else { return nil }
        return info.pbi_uid
    }

    static func parentPID(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
            return pid_t(info.pbi_ppid)
        }
        // 对 setuid / root 进程（如 login）proc_pidinfo 会失败，回退 sysctl
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0,
              size >= MemoryLayout<kinfo_proc>.size else { return nil }
        return pid_t(kinfo.kp_eproc.e_ppid)
    }

    /// 进程物理内存占用（RSS）
    static func residentSize(for pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        guard r > 0 else { return nil }
        return info.pti_resident_size
    }
}

// MARK: - 子进程执行

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
        await Task.detached(priority: .utility) { () -> Result in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch { return Result(stdout: nil, stderr: nil, code: -1) }

            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                outData = out.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            if group.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                return Result(stdout: nil, stderr: nil, code: -1)
            }
            process.waitUntilExit()
            return Result(
                stdout: String(data: outData, encoding: .utf8),
                stderr: String(data: errData, encoding: .utf8),
                code: process.terminationStatus
            )
        }.value
    }
}

// MARK: - 扫描器

enum Scanner {
    struct Listener {
        let pid: pid_t
        let host: String
        let port: UInt16
    }

    static let projectMarkers = [
        ".git", "package.json", "go.mod", "Cargo.toml", "pyproject.toml",
        "requirements.txt", "pom.xml", "build.gradle", "build.gradle.kts",
        "settings.gradle", "Gemfile", "composer.json", "docker-compose.yml",
        "docker-compose.yaml", "compose.yml", "compose.yaml", "mix.exs",
        "deno.json", "bun.lockb", "pnpm-workspace.yaml",
    ]

    // MARK: 主入口

    static func scanServices() async -> [ServiceInfo] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let uid = getuid()
        // 并行执行：端口监听 / 容器列表 / 容器内存
        async let listenerTask = listeners()
        async let dockerTask = dockerContainers()
        async let statsTask = dockerStats()
        let listenerList = await listenerTask
        let dockerMap = await dockerTask
        let statsMap = await statsTask

        var services: [ServiceInfo] = []
        for l in listenerList where l.pid != myPid && l.pid > 1 {
            guard let exe = ProcUtil.executablePath(for: l.pid) else { continue }
            let base = (exe as NSString).lastPathComponent
            let isDockerProc = base == "docker-proxy" || base.hasPrefix("com.docker") || base == "docker"
            guard isDockerProc || !isNoisePath(exe) else { continue }
            guard let owner = ProcUtil.userID(for: l.pid), owner == uid else { continue }
            let args = ProcUtil.arguments(for: l.pid)
            let cwd = ProcUtil.currentDirectory(for: l.pid)

            // JetBrains IDE 自身的 JVM（内部 RPC 端口）
            if base == "java" {
                let joinedArgs = args.map { $0.lowercased() }.joined(separator: " ")
                if joinedArgs.contains("com.intellij") || joinedArgs.contains("idea.home.path")
                    || joinedArgs.contains("intellij") || joinedArgs.contains("datagrip") {
                    continue
                }
            }

            // Docker 转发端口 → 关联容器
            if isDockerProc, let container = dockerMap[l.port] {
                services.append(dockerService(listener: l, container: container))
                continue
            }

            let (role, rawStack) = classify(exeBase: base, exePath: exe, args: args)
            let root = projectRoot(for: cwd) ?? rootFromArgs(args)
            // 技术栈精修用「最近的依赖清单目录」（monorepo 场景依赖在子目录）
            let refineDir = nearestMarkerDir(for: cwd, markers: ["package.json", "pyproject.toml", "requirements.txt"])
                ?? rootFromArgs(args) ?? root
            let stack = refineStack(rawStack, role: role, projectPath: refineDir)

            var projectName: String
            var projectKey: String
            var projectPath: String?
            var kind: GroupKind

            if let root, let name = basename(of: root), !name.isEmpty {
                projectName = name
                projectKey = "path:\(root)"
                projectPath = root
                kind = .project
            } else {
                projectName = stack
                projectKey = "standalone:\(stack)"
                projectPath = role == .database || role == .middleware ? dataDir(args: args) : cwd
                kind = .standalone
            }

            services.append(ServiceInfo(
                id: "\(l.pid):\(l.port)",
                pid: l.pid,
                port: l.port,
                bindHost: l.host,
                processName: base,
                command: args.isEmpty ? exe : args.joined(separator: " "),
                workingDirectory: cwd,
                role: role,
                stack: stack,
                projectName: projectName,
                projectPath: projectPath,
                projectKey: projectKey,
                groupKind: kind,
                isHTTPCandidate: role != .database && role != .middleware,
                docker: nil,
                terminal: terminalAncestor(of: l.pid),
                probe: nil
            ))
        }

        // 内存占用：本地进程取内核 RSS；Docker 容器取 docker stats
        for index in services.indices {
            let pid = services[index].pid
            if services[index].docker == nil {
                services[index].memoryBytes = ProcUtil.residentSize(for: pid)
            } else if let name = services[index].docker?.name {
                services[index].memoryBytes = statsMap[name]
            }
        }

        // 附加 tty（用于直达原始终端标签页）
        let localPids = Array(Set(services.filter { $0.docker == nil }.map { $0.pid }))
        let ttys = await ttyMap(for: localPids)
        for index in services.indices where services[index].docker == nil {
            let pid = services[index].pid
            services[index].terminal?.tty = ttys[pid]
        }
        return services
    }

    // MARK: 噪声过滤（系统进程与 GUI 应用）

    static func isNoisePath(_ exe: String) -> Bool {
        if exe.hasPrefix("/System/") || exe.hasPrefix("/usr/libexec/")
            || exe.hasPrefix("/usr/sbin/") || exe.hasPrefix("/Library/Apple/") {
            return true
        }
        if exe.contains(".app/Contents/MacOS/") {
            // 本地 Electron 开发（node_modules 内的 Electron）放行
            return !exe.contains("/node_modules/")
        }
        return false
    }

    // MARK: lsof 监听端口

    static func listeners() async -> [Listener] {
        guard let out = await Shell.run(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fcpn"],
            timeout: 10
        ) else { return [] }

        var result: [Listener] = []
        var seen = Set<String>()
        var currentPid: pid_t = 0
        for line in out.split(separator: "\n") {
            guard let key = line.first else { continue }
            let body = line.dropFirst()
            if key == "p" {
                currentPid = pid_t(body) ?? 0
            } else if key == "n", currentPid > 0 {
                guard let endpoint = parseEndpoint(String(body)) else { continue }
                let dedupeKey = "\(currentPid)#\(endpoint.port)"
                guard seen.insert(dedupeKey).inserted else { continue }
                result.append(Listener(pid: currentPid, host: endpoint.host, port: endpoint.port))
            }
        }
        return result
    }

    static func parseEndpoint(_ s: String) -> (host: String, port: UInt16)? {
        guard let colon = s.lastIndex(of: ":") else { return nil }
        guard let port = UInt16(s[s.index(after: colon)...]) else { return nil }
        var host = String(s[s.startIndex..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return (host.isEmpty ? "*" : host, port)
    }

    // MARK: Docker 容器

    static func dockerContainers() async -> [UInt16: DockerContainer] {
        guard let docker = dockerExecutablePath() else { return [:] }
        let format = "{{.Names}}|{{.Image}}|{{.Ports}}|{{.Label \"com.docker.compose.project\"}}"
        guard let out = await Shell.run(docker, ["ps", "--format", format], timeout: 4),
              !out.isEmpty else { return [:] }

        var map: [UInt16: DockerContainer] = [:]
        for line in out.split(separator: "\n") {
            let parts = String(line).components(separatedBy: "|")
            guard parts.count >= 3 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let image = parts[1].trimmingCharacters(in: .whitespaces)
            let portsField = parts[2]
            let label = (parts.count > 3 ? parts[3] : "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let container = DockerContainer(name: name, image: image, composeProject: label.isEmpty ? nil : label)

            for token in portsField.components(separatedBy: ", ") {
                guard let arrow = token.range(of: "->") else { continue }
                let hostPart = String(token[token.startIndex..<arrow.lowerBound])
                guard let c = hostPart.lastIndex(of: ":"),
                      let port = UInt16(hostPart[hostPart.index(after: c)...]) else { continue }
                if map[port] == nil { map[port] = container }
            }
        }
        return map
    }

    static func dockerExecutablePath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.docker/bin/docker",
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/bin/docker",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 容器内存占用（docker stats）
    static func dockerStats() async -> [String: UInt64] {
        guard let docker = dockerExecutablePath() else { return [:] }
        guard let out = await Shell.run(
            docker,
            ["stats", "--no-stream", "--format", "{{.Name}}|{{.MemUsage}}"],
            timeout: 4
        ), !out.isEmpty else { return [:] }

        var result: [String: UInt64] = [:]
        for line in out.split(separator: "\n") {
            let parts = String(line).components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            if let bytes = parseSizeBytes(parts[1].trimmingCharacters(in: .whitespaces)) {
                result[name] = bytes
            }
        }
        return result
    }

    /// 解析 "45.6MiB / 4GiB" 这类容量文本
    static func parseSizeBytes(_ text: String) -> UInt64? {
        let first = text.components(separatedBy: " ").first ?? text
        let number = first.prefix { $0.isNumber || $0 == "." }
        let unit = first.dropFirst(number.count).lowercased()
        guard let value = Double(number), value > 0 else { return nil }
        let multiplier: Double
        switch unit {
        case "b": multiplier = 1
        case "kib", "kb": multiplier = 1_024
        case "mib", "mb": multiplier = 1_048_576
        case "gib", "gb": multiplier = 1_073_741_824
        case "tib", "tb": multiplier = 1_099_511_627_776
        default: return nil
        }
        return UInt64(value * multiplier)
    }

    static func dockerService(listener: Listener, container: DockerContainer) -> ServiceInfo {
        let (role, stack) = classifyDockerImage(container.image)
        let key = container.composeProject.map { "compose:\($0)" } ?? "docker:loose"
        return ServiceInfo(
            id: "\(listener.pid):\(listener.port)",
            pid: listener.pid,
            port: listener.port,
            bindHost: listener.host,
            processName: container.name,
            command: "docker · \(container.image)",
            workingDirectory: nil,
            role: role,
            stack: stack,
            projectName: container.composeProject ?? "Docker",
            projectPath: nil,
            projectKey: key,
            groupKind: container.composeProject != nil ? .dockerCompose : .docker,
            isHTTPCandidate: role != .database && role != .middleware,
            docker: container,
            terminal: nil,
            probe: nil
        )
    }

    // MARK: 终端宿主识别（沿父进程链向上找终端 / IDE 应用）

    static func terminalAncestor(of pid: pid_t) -> TerminalContext? {
        var current = pid
        for _ in 0..<24 {
            guard let parent = ProcUtil.parentPID(for: current), parent > 1 else { return nil }
            if let exe = ProcUtil.executablePath(for: parent),
               let context = matchTerminalApp(exePath: exe) {
                return context
            }
            current = parent
        }
        return nil
    }

    static func appBundlePath(of exe: String) -> String? {
        guard let range = exe.range(of: ".app/Contents/") else { return nil }
        return String(exe[exe.startIndex..<range.lowerBound]) + ".app"
    }

    static func matchTerminalApp(exePath: String) -> TerminalContext? {
        guard let appPath = appBundlePath(of: exePath) else { return nil }
        let lower = appPath.lowercased()
        let name = (((appPath as NSString).lastPathComponent) as NSString).deletingPathExtension

        if lower.hasSuffix("/terminal.app") {
            return TerminalContext(appPath: appPath, displayName: "Terminal", kind: .appleTerminal, tty: nil)
        }
        if lower.hasSuffix("/iterm.app") || lower.hasSuffix("/iterm2.app") {
            return TerminalContext(appPath: appPath, displayName: "iTerm2", kind: .iterm2, tty: nil)
        }
        // 通用终端
        for app in ["warp", "ghostty", "kitty", "alacritty", "wezterm", "hyper", "tabby", "contour"] {
            if lower.contains("/\(app).app") {
                return TerminalContext(appPath: appPath, displayName: name, kind: .generic, tty: nil)
            }
        }
        // IDE（集成终端）
        for app in ["visual studio code", "code", "cursor", "vscodium", "windsurf", "trae", "zed",
                    "intellij idea", "pycharm", "webstorm", "goland", "clion", "datagrip",
                    "rustrover", "phpstorm", "rubymine", "fleet", "android studio", "xcode"] {
            if lower.contains("/\(app).app") {
                return TerminalContext(appPath: appPath, displayName: name, kind: .generic, tty: nil)
            }
        }
        return nil
    }

    /// 批量获取进程控制终端（一次 lsof 调用）
    static func ttyMap(for pids: [pid_t]) async -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = await Shell.run(
            "/usr/sbin/lsof",
            ["-w", "-a", "-p", list, "-d", "0,1,2", "-Fpfn"],
            timeout: 8
        ) else { return [:] }

        var result: [pid_t: String] = [:]
        var currentPid: pid_t = 0
        var currentFd: Int?
        for line in out.split(separator: "\n") {
            guard let key = line.first else { continue }
            let body = String(line.dropFirst())
            switch key {
            case "p":
                currentPid = pid_t(body) ?? 0
                currentFd = nil
            case "f":
                currentFd = Int(body.prefix { $0.isNumber })
            case "n":
                if currentPid > 0, currentFd != nil,
                   body.hasPrefix("/dev/ttys"), result[currentPid] == nil {
                    result[currentPid] = body
                }
            default:
                break
            }
        }
        return result
    }

    // MARK: 角色与技术栈识别

    static func classify(exeBase: String, exePath: String, args: [String]) -> (role: ServiceRole, stack: String) {
        let lowered = args.map { $0.lowercased() }
        let joined = lowered.joined(separator: " ")
        func hasToken(_ t: String) -> Bool { lowered.contains(t) }

        // 数据库 / 中间件：按可执行文件名
        switch exeBase {
        case "postgres", "postmaster": return (.database, "PostgreSQL")
        case "mysqld": return (.database, "MySQL")
        case "mariadbd": return (.database, "MariaDB")
        case "redis-server": return (.database, "Redis")
        case "valkey-server", "valkey": return (.database, "Valkey")
        case "mongod", "mongos": return (.database, "MongoDB")
        case "clickhouse-server", "clickhouse": return (.database, "ClickHouse")
        case "elasticsearch": return (.database, "Elasticsearch")
        case "opensearch": return (.database, "OpenSearch")
        case "influxd": return (.database, "InfluxDB")
        case "neo4j": return (.database, "Neo4j")
        case "memcached": return (.middleware, "Memcached")
        case "etcd": return (.middleware, "etcd")
        case "nats-server", "gnatsd": return (.middleware, "NATS")
        case "vault": return (.middleware, "Vault")
        case "minio": return (.middleware, "MinIO")
        case "beam.smp":
            if joined.contains("rabbit") { return (.middleware, "RabbitMQ") }
            return (.other, "Erlang")
        case "java":
            if joined.contains("neo4j") { return (.database, "Neo4j") }
            if joined.contains("kafka") { return (.middleware, "Kafka") }
            if joined.contains("spring") { return (.backend, "Spring Boot") }
            return (.backend, "Java")
        default: break
        }

        // 前端 dev server
        if joined.contains("bin/vite") || hasToken("vite") || joined.contains("vinxi") { return (.frontend, "Vite") }
        if joined.contains("bin/next") || hasToken("next") || joined.contains("next-server") { return (.frontend, "Next.js") }
        if joined.contains("vue-cli-service") { return (.frontend, "Vue CLI") }
        if joined.contains("webpack-dev-server") || (joined.contains("webpack") && joined.contains("serve")) { return (.frontend, "Webpack") }
        if joined.contains("bin/nuxt") || hasToken("nuxt") || joined.contains("nuxt-core") { return (.frontend, "Nuxt") }
        if joined.contains("bin/astro") || hasToken("astro") { return (.frontend, "Astro") }
        if joined.contains("@angular/cli") || joined.contains("ng serve") || exeBase == "ng" { return (.frontend, "Angular") }
        if joined.contains("react-scripts") { return (.frontend, "React (CRA)") }
        if joined.contains("expo") || joined.contains("metro") { return (.frontend, "Expo") }
        if joined.contains("storybook") { return (.frontend, "Storybook") }
        if joined.contains("bin/parcel") || hasToken("parcel") { return (.frontend, "Parcel") }
        if joined.contains("bin/quasar") || joined.contains("quasar") { return (.frontend, "Quasar") }
        if joined.contains("ionic") { return (.frontend, "Ionic") }
        if joined.contains("electron") { return (.frontend, "Electron") }
        if joined.contains("live-server") { return (.frontend, "Live Server") }
        if joined.contains("docusaurus") { return (.frontend, "Docusaurus") }
        if joined.contains("vitepress") { return (.frontend, "VitePress") }

        // 后端
        if joined.contains("uvicorn") { return (.backend, "Uvicorn") }
        if joined.contains("gunicorn") { return (.backend, "Gunicorn") }
        if joined.contains("manage.py") { return (.backend, "Django") }
        if joined.contains("flask") { return (.backend, "Flask") }
        if joined.contains("bin/nest") || joined.contains("nest start") { return (.backend, "NestJS") }
        if joined.contains("strapi") { return (.backend, "Strapi") }
        if joined.contains("hasura") { return (.backend, "Hasura") }
        if joined.contains("directus") { return (.backend, "Directus") }
        if joined.contains("puma") || joined.contains("rails") || joined.contains("rackup") { return (.backend, "Rails") }
        if joined.contains("artisan") { return (.backend, "Laravel") }
        if exeBase == "php" || joined.contains("php -s") { return (.backend, "PHP") }
        if joined.contains("wrangler") { return (.backend, "Wrangler") }
        if joined.contains("bin/prisma") && joined.contains("studio") { return (.other, "Prisma Studio") }
        if exePath.contains("go-build") || exeBase == "go" { return (.backend, "Go") }
        if exePath.contains("/target/debug/") || exePath.contains("/target/release/") || exeBase == "cargo" { return (.backend, "Rust") }
        if exeBase == "dotnet" { return (.backend, ".NET") }
        if exeBase == "bun" { return (.backend, "Bun") }
        if exeBase == "deno" { return (.backend, "Deno") }

        if exeBase == "node" || exeBase == "node.js" { return (.backend, "Node.js") }
        if exeBase.hasPrefix("python") { return (.backend, "Python") }
        if exeBase == "ruby" { return (.backend, "Ruby") }

        return (.other, exeBase.isEmpty ? "unknown" : exeBase)
    }

    static func classifyDockerImage(_ image: String) -> (role: ServiceRole, stack: String) {
        var name = image.lowercased()
        // 去掉 registry / namespace
        if let slash = name.lastIndex(of: "/") {
            let head = String(name[name.startIndex..<slash])
            if head.contains(".") || head.contains(":") || head == "localhost" {
                name = String(name[name.index(after: slash)...])
            }
        }
        let bare = name.components(separatedBy: ":").first ?? name

        let dbMap: [String: String] = [
            "postgres": "PostgreSQL", "mysql": "MySQL", "mariadb": "MariaDB",
            "redis": "Redis", "valkey": "Valkey", "mongo": "MongoDB",
            "clickhouse": "ClickHouse", "elasticsearch": "Elasticsearch",
            "opensearch": "OpenSearch", "influxdb": "InfluxDB", "neo4j": "Neo4j",
            "questdb": "QuestDB", "couchdb": "CouchDB", "tidb": "TiDB",
            "sqlserver": "SQL Server", "mssql": "SQL Server", "dynamodb": "DynamoDB Local",
        ]
        for (key, label) in dbMap where bare.contains(key) { return (.database, label) }

        let mwMap: [String: String] = [
            "memcached": "Memcached", "rabbitmq": "RabbitMQ", "kafka": "Kafka",
            "nats": "NATS", "zookeeper": "ZooKeeper", "etcd": "etcd",
            "minio": "MinIO", "nginx": "Nginx", "traefik": "Traefik",
            "caddy": "Caddy", "kong": "Kong", "vault": "Vault",
            "consul": "Consul", "localstack": "LocalStack", "emqx": "EMQX",
            "mosquitto": "Mosquitto", "pulsar": "Pulsar",
        ]
        for (key, label) in mwMap where bare.contains(key) { return (.middleware, label) }

        return (.backend, prettyImage(image))
    }

    static func prettyImage(_ image: String) -> String {
        var parts = image.components(separatedBy: "/")
        if let first = parts.first, first.contains(".") || first.contains(":") || first == "localhost" {
            parts.removeFirst()
        }
        var name = parts.joined(separator: "/")
        if let colon = name.firstIndex(of: ":") {
            let tag = String(name[name.index(after: colon)...])
            if tag == "latest" { name = String(name[name.startIndex..<colon]) }
        }
        return name.isEmpty ? image : name
    }

    // MARK: 项目根目录识别

    static func projectRoot(for cwd: String?) -> String? {
        guard var dir = cwd, dir.count > 1 else { return nil }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var gitRoot: String?
        var markerRoot: String?
        while dir.count > 1 {
            for marker in projectMarkers where fm.fileExists(atPath: dir + "/" + marker) {
                if marker == ".git" {
                    if gitRoot == nil { gitRoot = dir }
                } else if markerRoot == nil {
                    markerRoot = dir
                }
                break
            }
            if dir == home || dir == "/" { break }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent.count >= dir.count { break }
            dir = parent
        }
        return gitRoot ?? markerRoot
    }

    /// 向上找最近一个包含指定标记文件的目录（用于读取依赖清单）
    static func nearestMarkerDir(for cwd: String?, markers: [String]) -> String? {
        guard var dir = cwd, dir.count > 1 else { return nil }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        while dir.count > 1 {
            for marker in markers where fm.fileExists(atPath: dir + "/" + marker) {
                return dir
            }
            if dir == home || dir == "/" { break }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent.count >= dir.count { break }
            dir = parent
        }
        return nil
    }

    /// 从参数中的 node_modules 路径推断项目根（如 vite 在子目录启动时）
    static func rootFromArgs(_ args: [String]) -> String? {
        let fm = FileManager.default
        for arg in args {
            if let range = arg.range(of: "/node_modules/") {
                let prefix = String(arg[arg.startIndex..<range.lowerBound])
                if prefix.hasPrefix("/"), fm.fileExists(atPath: prefix + "/package.json") {
                    return prefix
                }
            }
        }
        return nil
    }

    // MARK: 技术栈精修（读 package.json / pyproject）

    static func refineStack(_ stack: String, role: ServiceRole, projectPath: String?) -> String {
        guard let path = projectPath else { return stack }
        let fm = FileManager.default

        if role == .backend, stack == "Node.js" || stack == "Bun" || stack == "NestJS" {
            guard let data = fm.contents(atPath: path + "/package.json"),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return stack }
            var names = Set<String>()
            for key in ["dependencies", "devDependencies"] {
                if let deps = json[key] as? [String: Any] { names.formUnion(deps.keys) }
            }
            let map: [(String, String)] = [
                ("@nestjs/", "NestJS"), ("express", "Express"), ("koa", "Koa"),
                ("fastify", "Fastify"), ("hono", "Hono"), ("strapi", "Strapi"),
                ("@adonisjs/", "AdonisJS"), ("egg", "Egg.js"),
            ]
            for (pkg, label) in map where names.contains(where: { $0 == pkg || $0.hasPrefix(pkg) }) {
                return label
            }
        }

        if role == .backend, stack == "Python" || stack == "Uvicorn" || stack == "Gunicorn" {
            var text = ""
            for file in ["pyproject.toml", "requirements.txt"] {
                if let data = fm.contents(atPath: path + "/" + file),
                   let content = String(data: data, encoding: .utf8) {
                    text += content.lowercased() + "\n"
                }
            }
            let map: [(String, String)] = [
                ("fastapi", "FastAPI"), ("django", "Django"), ("flask", "Flask"),
                ("tornado", "Tornado"), ("sanic", "Sanic"), ("starlette", "Starlette"),
                ("litestar", "Litestar"),
            ]
            for (keyword, label) in map where text.contains(keyword) {
                if stack == "Uvicorn" || stack == "Gunicorn" {
                    return "\(label) · \(stack)"
                }
                return label
            }
        }
        return stack
    }

    // MARK: 工具

    static func basename(of path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    static func dataDir(args: [String]) -> String? {
        let flags = ["-D", "--dir", "--data-dir", "--dbpath"]
        var i = 0
        while i < args.count - 1 {
            if flags.contains(args[i]) { return args[i + 1] }
            i += 1
        }
        return nil
    }
}
