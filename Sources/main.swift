import Cocoa
import SwiftUI

// MARK: - JSON Models

struct GatewayStatus: Codable {
    let service: ServiceInfo?
    let gateway: GatewayInfo?
    let port: PortInfo?
    let rpc: RpcInfo?
    let health: HealthInfo?
}

struct ServiceInfo: Codable {
    let label: String?
    let loaded: Bool?
    let runtime: RuntimeInfo?
}

struct RuntimeInfo: Codable {
    let status: String?
    let state: String?
    let pid: Int?
}

struct GatewayInfo: Codable {
    let bindMode: String?
    let bindHost: String?
    let port: Int?
    let portSource: String?
    let probeUrl: String?
    let probeNote: String?
}

struct PortInfo: Codable {
    let port: Int?
    let status: String?
    let listeners: [ListenerInfo]?
    let hints: [String]?
}

struct ListenerInfo: Codable {
    let pid: Int?
    let command: String?
    let address: String?
    let commandLine: String?
    let user: String?
    let ppid: Int?
}

struct RpcInfo: Codable {
    let ok: Bool?
    let url: String?
}

struct HealthInfo: Codable {
    let healthy: Bool?
    let staleGatewayPids: [Int]?
}

// MARK: - Health JSON Models (openclaw health --json)

struct HealthStatus: Codable {
    let ok: Bool?
    let ts: Int64?
    let durationMs: Int?
    let sessions: HealthSessionInfo?
    let agents: [HealthAgent]?
}

struct HealthSessionInfo: Codable {
    let path: String?
    let count: Int?
    let recent: [RecentSession]?
}

struct RecentSession: Codable {
    let key: String?
    let updatedAt: Int64?
    let age: Int64?
}

struct HealthAgent: Codable {
    let agentId: String?
    let isDefault: Bool?
    let sessions: HealthSessionInfo?
}

// MARK: - Service Manager

class ServiceManager: ObservableObject {
    static let shared = ServiceManager()
    
    let dashboardURL = "http://127.0.0.1:18789/chat?session=agent%3Amain%3Amain"
    let servicePort: UInt16 = 18789
    let startCommand = "openclaw gateway start"
    let stopCommand  = "openclaw gateway stop"
    let restartCommand = "openclaw gateway restart"
    let statusCommand = "openclaw gateway status --json"
    let healthCommand = "openclaw health --json"
    
    @Published var isRunning = false
    @Published var statusText = "检测中..."
    @Published var isLoading = false
    @Published var appIcon: NSImage?
    
    // Detail info from gateway status JSON
    @Published var pid: Int?
    @Published var bindAddress: String?
    @Published var rpcOk: Bool?
    @Published var healthy: Bool?
    @Published var portStatus: String?
    @Published var serviceLoaded: Bool?
    @Published var runtimeState: String?
    @Published var probeNote: String?
    
    // Detail info from health JSON
    @Published var healthOk: Bool?
    @Published var sessionCount: Int?
    @Published var uptimeString: String?
    
    private var timer: Timer?
    
    init() {
        loadAppIcon()
        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }
    
    deinit {
        timer?.invalidate()
        timer = nil
    }
    
    func loadAppIcon() {
        if let bundlePath = Bundle.main.resourcePath {
            let icnsPath = (bundlePath as NSString).appendingPathComponent("AppIcon.icns")
            if let img = NSImage(contentsOfFile: icnsPath), img.isValid {
                let sized = resizeImage(img, to: NSSize(width: 512, height: 512))
                appIcon = sized
                NSApp.applicationIconImage = sized
                return
            }
        }
        let executablePath = CommandLine.arguments[0]
        let executableDir = (executablePath as NSString).deletingLastPathComponent
        let iconPath = (executableDir as NSString).appendingPathComponent("icon.png")
        if let img = NSImage(contentsOfFile: iconPath), img.isValid {
            let sized = resizeImage(img, to: NSSize(width: 512, height: 512))
            appIcon = sized
            NSApp.applicationIconImage = sized
        }
    }
    
    func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
    
    func refreshStatus() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            
            // 1. Gateway status
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", self.statusCommand]
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory()
            ]
            
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                
                if process.terminationStatus == 0,
                   let status = try? JSONDecoder().decode(GatewayStatus.self, from: data) {
                    self.applyStatus(status)
                } else {
                    // Fallback: port check
                    let running = self.checkPort(port: self.servicePort)
                    DispatchQueue.main.async {
                        self.clearDetails()
                        self.isRunning = running
                        if !self.isLoading {
                            self.statusText = running
                                ? "✅ 运行中 (端口 \(self.servicePort))"
                                : "❌ 已停止"
                        }
                    }
                }
            } catch {
                let running = self.checkPort(port: self.servicePort)
                DispatchQueue.main.async {
                    self.clearDetails()
                    self.isRunning = running
                    if !self.isLoading {
                        self.statusText = running
                            ? "✅ 运行中 (端口 \(self.servicePort))"
                            : "❌ 已停止"
                    }
                }
            }
            
            // 2. Health status
            self.refreshHealthStatus()
        }
    }
    
    private func refreshHealthStatus() {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", healthCommand]
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory()
        ]
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            if process.terminationStatus == 0,
               let health = try? JSONDecoder().decode(HealthStatus.self, from: data) {
                self.applyHealthStatus(health)
            } else {
                DispatchQueue.main.async {
                    self.healthOk = nil
                    self.sessionCount = nil
                    self.uptimeString = nil
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.healthOk = nil
                self.sessionCount = nil
                self.uptimeString = nil
            }
        }
    }
    
    private func applyHealthStatus(_ health: HealthStatus) {
        let count = health.sessions?.count
        
        // 从 sessions.recent 中找到 agent:main:main 的 updatedAt，计算运行时间
        var uptime: String? = nil
        if let recent = health.sessions?.recent,
           let mainSession = recent.first(where: { $0.key == "agent:main:main" }),
           let updatedAt = mainSession.updatedAt {
            let updatedDate = Date(timeIntervalSince1970: Double(updatedAt) / 1000.0)
            uptime = Self.formatDuration(from: updatedDate, to: Date())
        }
        
        DispatchQueue.main.async {
            self.healthOk = health.ok
            self.sessionCount = count
            self.uptimeString = uptime
        }
    }
    
    /// 将时间间隔格式化为人类可读的字符串
    static func formatDuration(from start: Date, to end: Date) -> String {
        let interval = end.timeIntervalSince(start)
        if interval < 0 { return "-" }
        
        let totalSeconds = Int(interval)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60
        
        if days > 0 {
            return "\(days)天\(hours)小时"
        } else if hours > 0 {
            return "\(hours)小时\(minutes)分钟"
        } else if minutes > 0 {
            return "\(minutes)分钟"
        } else {
            return "刚刚"
        }
    }
    
    private func applyStatus(_ status: GatewayStatus) {
        let running = status.service?.runtime?.status == "running"
            || status.health?.healthy == true
        
        DispatchQueue.main.async {
            self.isRunning = running
            self.pid = status.service?.runtime?.pid
            self.serviceLoaded = status.service?.loaded
            self.runtimeState = status.service?.runtime?.state
            self.healthy = status.health?.healthy
            self.rpcOk = status.rpc?.ok
            self.portStatus = status.port?.status
            self.probeNote = status.gateway?.probeNote
            
            if let host = status.gateway?.bindHost, let port = status.gateway?.port {
                self.bindAddress = "\(host):\(port)"
            } else {
                self.bindAddress = nil
            }
            
            if !self.isLoading {
                if running {
                    let pidStr = self.pid.map { " · PID \($0)" } ?? ""
                    self.statusText = "✅ 运行中 (端口 \(self.servicePort))\(pidStr)"
                } else {
                    self.statusText = "❌ 已停止"
                }
            }
        }
    }
    
    private func clearDetails() {
        pid = nil
        bindAddress = nil
        rpcOk = nil
        healthy = nil
        portStatus = nil
        serviceLoaded = nil
        runtimeState = nil
        probeNote = nil
        healthOk = nil
        sessionCount = nil
        uptimeString = nil
    }
    
    func startService() {
        isLoading = true
        statusText = "⏳ 启动中..."
        runCommandAsync(startCommand) { [weak self] success, output in
            DispatchQueue.main.async {
                if !success { self?.showAlert(title: "启动失败", message: output) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.isLoading = false
                    self?.refreshStatus()
                }
            }
        }
    }
    
    func stopService() {
        isLoading = true
        statusText = "⏳ 停止中..."
        runCommandAsync(stopCommand) { [weak self] success, output in
            DispatchQueue.main.async {
                if !success { self?.showAlert(title: "停止失败", message: output) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.isLoading = false
                    self?.refreshStatus()
                }
            }
        }
    }
    
    func restartService() {
        isLoading = true
        statusText = "⏳ 重启中..."
        runCommandAsync(restartCommand) { [weak self] success, output in
            DispatchQueue.main.async {
                if !success { self?.showAlert(title: "重启失败", message: output) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.isLoading = false
                    self?.refreshStatus()
                }
            }
        }
    }
    
    func openDashboard() {
        if let url = URL(string: dashboardURL) { NSWorkspace.shared.open(url) }
    }
    
    // MARK: - Private
    
    private func checkPort(port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
    
    private func runCommandAsync(_ command: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory()
            ]
            do {
                try process.run(); process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                completion(process.terminationStatus == 0, output)
            } catch { completion(false, error.localizedDescription) }
        }
    }
    
    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }
}

// MARK: - SwiftUI Views

struct ContentView: View {
    @ObservedObject var manager = ServiceManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            if manager.isRunning {
                detailGrid
                Divider()
            }
            controlButtons
            Divider()
            toolButtons
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private var statusHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(manager.isRunning
                          ? Color.green.opacity(0.15)
                          : Color.gray.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                if let icon = manager.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: manager.isRunning ? "shield.checkered" : "shield")
                        .font(.system(size: 36))
                        .foregroundColor(manager.isRunning ? .green : .gray)
                }
            }
            
            Text("OpenClaw")
                .font(.title)
                .fontWeight(.semibold)
            
            Text(manager.statusText)
                .font(.body)
                .foregroundColor(.secondary)
            
            if manager.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Color(.controlBackgroundColor))
    }
    
    private var detailGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 10) {
            DetailCell(label: "PID",
                       value: manager.pid.map { "\($0)" } ?? "-",
                       icon: "number",
                       color: .blue)
            
            DetailCell(label: "健康状态",
                       value: (manager.healthOk ?? manager.healthy) == true ? "健康" : "异常",
                       icon: (manager.healthOk ?? manager.healthy) == true ? "heart.fill" : "heart.slash",
                       color: (manager.healthOk ?? manager.healthy) == true ? .green : .red)
            
            DetailCell(label: "会话数量",
                       value: manager.sessionCount.map { "\($0)" } ?? "-",
                       icon: "bubble.left.and.bubble.right.fill",
                       color: .teal)
            
            DetailCell(label: "运行时间",
                       value: manager.uptimeString ?? "-",
                       icon: "clock.fill",
                       color: .indigo)
            
        }
        .padding(16)
    }
    
    private var controlButtons: some View {
        HStack(spacing: 16) {
            Button(action: { manager.startService() }) {
                Label("启动", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(manager.isRunning || manager.isLoading)
            
            Button(action: { manager.stopService() }) {
                Label("停止", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!manager.isRunning || manager.isLoading)
            
            Button(action: { manager.restartService() }) {
                Label("重启", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(!manager.isRunning || manager.isLoading)
        }
        .controlSize(.large)
        .padding(20)
    }
    
    private var toolButtons: some View {
        HStack(spacing: 12) {
            ToolButton(title: "控制面板", icon: "globe", color: .blue) { manager.openDashboard() }
            ToolButton(title: "刷新状态", icon: "arrow.triangle.2.circlepath", color: .teal) { manager.refreshStatus() }
        }
        .padding(20)
    }
}

struct DetailCell: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct ToolButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var statusItem: NSStatusItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window?.title = "OpenClaw Manager"
        window?.contentView = NSHostingView(rootView: contentView)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.isReleasedWhenClosed = false
        setupMainMenu()
        setupStatusBarItem()
    }

    // MARK: - Main Menu (左上角菜单栏)
    func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // 1. 应用菜单（最左侧，显示应用名）
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "OpenClaw")
        appMenu.addItem(withTitle: "关于 OpenClaw", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        
        let servicesMenuItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesMenuItem.submenu = servicesMenu
        appMenu.addItem(servicesMenuItem)
        NSApp.servicesMenu = servicesMenu
        
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 OpenClaw", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 OpenClaw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        
        // 2. 文件菜单
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let closeItem = NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        
        // 3. 服务菜单（控制操作）
        let serviceMenuItem = NSMenuItem()
        let serviceMenu = NSMenu(title: "服务控制")
        
        let startItem = NSMenuItem(title: "启动服务", action: #selector(trayStartService), keyEquivalent: "")
        startItem.target = self
        serviceMenu.addItem(startItem)
        
        let stopItem = NSMenuItem(title: "停止服务", action: #selector(trayStopService), keyEquivalent: "")
        stopItem.target = self
        serviceMenu.addItem(stopItem)
        
        let restartItem = NSMenuItem(title: "重启服务", action: #selector(trayRestartService), keyEquivalent: "")
        restartItem.target = self
        serviceMenu.addItem(restartItem)
        
        serviceMenu.addItem(NSMenuItem.separator())
        
        let dashboardItem = NSMenuItem(title: "打开控制面板", action: #selector(trayOpenDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        serviceMenu.addItem(dashboardItem)
        
        let refreshItem = NSMenuItem(title: "刷新状态", action: #selector(menuRefreshStatus), keyEquivalent: "r")
        refreshItem.target = self
        serviceMenu.addItem(refreshItem)
        
        serviceMenuItem.submenu = serviceMenu
        mainMenu.addItem(serviceMenuItem)
        
        // 4. 窗口菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu
        
        NSApp.mainMenu = mainMenu
    }

    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OpenClaw Manager",
            .applicationVersion: "1.0.0",
            .credits: NSAttributedString(string: "OpenClaw 网关服务管理工具")
        ])
    }
    
    @objc func menuRefreshStatus() {
        ServiceManager.shared.refreshStatus()
    }
    
    func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let manager = ServiceManager.shared
            if let icon = manager.appIcon {
                let trayIcon = manager.resizeImage(icon, to: NSSize(width: 18, height: 18))
                trayIcon.isTemplate = false
                button.image = trayIcon
            } else {
                button.title = "🐾"
            }
            button.toolTip = "OpenClaw Manager"
        }
        let menu = NSMenu()
        let statusMenuItem = NSMenuItem(title: ServiceManager.shared.statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        let startItem = NSMenuItem(title: "启动服务", action: #selector(trayStartService), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
        let stopItem = NSMenuItem(title: "停止服务", action: #selector(trayStopService), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)
        let restartItem = NSMenuItem(title: "重启服务", action: #selector(trayRestartService), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)
        menu.addItem(NSMenuItem.separator())
        let dashboardItem = NSMenuItem(title: "打开控制面板", action: #selector(trayOpenDashboard), keyEquivalent: "")
        dashboardItem.target = self
        menu.addItem(dashboardItem)
        let showWindowItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "s")
        showWindowItem.target = self
        menu.addItem(showWindowItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 OpenClaw", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
    }
    
    @objc func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func trayStartService() {
        ServiceManager.shared.startService()
    }
    
    @objc func trayStopService() {
        ServiceManager.shared.stopService()
    }
    
    @objc func trayRestartService() {
        ServiceManager.shared.restartService()
    }
    
    @objc func trayOpenDashboard() {
        ServiceManager.shared.openDashboard()
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// MARK: - Entry Point

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let statusMenuItem = menu.items.first {
            let manager = ServiceManager.shared
            statusMenuItem.title = manager.isRunning
                ? "✅ 运行中 (端口 \(manager.servicePort))"
                : "❌ 已停止"
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()