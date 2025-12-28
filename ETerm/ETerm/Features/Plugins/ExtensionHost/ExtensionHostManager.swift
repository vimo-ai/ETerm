//
//  ExtensionHostManager.swift
//  ETerm
//
//  Extension Host 进程管理器（客户端模式）
//
//  改造后的架构：
//  - Extension Host 作为服务端常驻运行
//  - ETerm 作为客户端连接到 Host
//  - 检测 Host 是否存活，如果不存活则启动
//  - 支持 Host 常驻，ETerm 退出后 Host 继续运行

import Foundation
import ETermKit

/// Extension Host 状态
enum ExtensionHostState: Equatable {
    case stopped
    case starting
    case connecting
    case running
    case crashed(exitCode: Int32)
    case restarting
}

/// Extension Host 管理器
///
/// 职责：
/// - 检测 Extension Host 是否已在运行
/// - 如果不在运行，启动 Host 进程
/// - 作为客户端连接到 Host
/// - 管理 IPC 连接
actor ExtensionHostManager {

    // MARK: - Singleton

    static let shared = ExtensionHostManager()

    // MARK: - Properties

    private var hostProcess: Process?
    private var state: ExtensionHostState = .stopped
    private var ipcBridge: PluginIPCBridge?

    /// 重启计数器（用于退避策略）
    private var restartCount = 0
    private var lastRestartTime: Date?

    /// 最大重启次数（1分钟内）
    private let maxRestartsPerMinute = 5

    /// 是否正在运行
    var isRunning: Bool {
        state == .running
    }

    /// Socket 路径（固定路径，所有 ETerm 实例共享）
    private var socketPath: String {
        ETermPaths.run + "/extension-host.sock"
    }

    /// PID 文件路径
    private var pidPath: String {
        ETermPaths.run + "/extension-host.pid"
    }

    /// Extension Host 可执行文件路径
    private var hostExecutablePath: String {
        let fm = FileManager.default

        // 1. 环境变量优先（方便调试）
        if let envPath = ProcessInfo.processInfo.environment["ETERM_EXTENSION_HOST_PATH"],
           fm.fileExists(atPath: envPath) {
            return envPath
        }

        // 2. App Bundle 内（发布版本）
        let bundlePath = Bundle.main.bundlePath + "/Contents/MacOS/ETermExtensionHost"
        if fm.fileExists(atPath: bundlePath) {
            return bundlePath
        }

        // 3. PlugIns 目录
        if let pluginsPath = Bundle.main.builtInPlugInsPath {
            let hostPath = pluginsPath + "/ETermExtensionHost"
            if fm.fileExists(atPath: hostPath) {
                return hostPath
            }
        }

        // 4. ~/.eterm/bin/（开发环境安装位置）
        let etermBinPath = ETermPaths.root + "/bin/ETermExtensionHost"
        if fm.fileExists(atPath: etermBinPath) {
            return etermBinPath
        }

        return bundlePath  // 默认路径（会触发文件不存在错误）
    }

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// 获取当前状态
    func getState() -> ExtensionHostState {
        return state
    }

    /// 启动/连接 Extension Host
    func start() async throws {
        guard state == .stopped || state.isCrashed else {
            return
        }

        state = .starting

        // 1. 检测 Host 是否已在运行
        if isHostAlive() {
            print("[ExtensionHostManager] Host already running, connecting...")
            state = .connecting
        } else {
            // 2. Host 未运行，启动它
            print("[ExtensionHostManager] Host not running, starting...")
            try startHostProcess()

            // 等待 Host 启动
            try await waitForHostReady(timeout: 10.0)
            state = .connecting
        }

        // 3. 作为客户端连接到 Host
        let bridge = PluginIPCBridge(socketPath: socketPath)
        try await bridge.connectAsClient()
        self.ipcBridge = bridge

        state = .running
        restartCount = 0

        print("[ExtensionHostManager] Connected to Extension Host successfully")
    }

    /// 停止 Extension Host
    ///
    /// 注意：这只是断开连接，不会终止 Host 进程（Host 有自己的生命周期管理）
    func stop() async {
        state = .stopped

        // 断开 IPC 连接
        await ipcBridge?.stop()
        ipcBridge = nil

        print("[ExtensionHostManager] Disconnected from Extension Host")
    }

    /// 强制终止 Host 进程（用于热重载）
    func terminateHost() async {
        await stop()

        // 读取 PID 并发送终止信号
        if let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
            print("[ExtensionHostManager] Sent SIGTERM to Host (PID: \(pid))")
        }

        // 清理 socket 文件
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// 获取 IPC Bridge（供其他组件调用）
    func getBridge() -> PluginIPCBridge? {
        return ipcBridge
    }

    /// 获取缓存的 ViewModel 数据
    func getCachedViewModel(for pluginId: String) async -> [String: Any]? {
        return await ipcBridge?.getCachedViewModel(for: pluginId)
    }

    /// 发送请求给插件
    func sendRequest(pluginId: String, requestId: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let bridge = ipcBridge else {
            throw IPCConnectionError.notConnected
        }
        return try await bridge.sendRequest(pluginId: pluginId, requestId: requestId, params: params)
    }

    /// 发送事件给插件
    func sendEvent(name: String, payload: [String: Any], targetPluginId: String? = nil) async {
        await ipcBridge?.sendEvent(name: name, payload: payload, targetPluginId: targetPluginId)
    }

    // MARK: - Private

    /// 检测 Host 是否存活
    private func isHostAlive() -> Bool {
        // 1. 检查 PID 文件
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }

        // 2. 检查进程是否存在
        let result = kill(pid, 0)
        if result != 0 {
            // 进程不存在，清理旧文件
            try? FileManager.default.removeItem(atPath: pidPath)
            try? FileManager.default.removeItem(atPath: socketPath)
            return false
        }

        // 3. 检查 socket 文件是否存在
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return false
        }

        return true
    }

    /// 启动 Host 进程
    private func startHostProcess() throws {
        let execPath = hostExecutablePath
        print("[ExtensionHostManager] Launching Host: \(execPath)")

        // 确保目录存在
        let runDir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = ["--socket", socketPath, "--lifecycle", "persist1Hour"]

        // 设置环境变量
        var environment = ProcessInfo.processInfo.environment
        environment["ETERM_HOST_PID"] = String(ProcessInfo.processInfo.processIdentifier)

        // 设置 DYLD_FRAMEWORK_PATH，让插件能找到 ETermKit.framework
        let frameworksPath = Bundle.main.bundlePath + "/Contents/Frameworks"
        environment["DYLD_FRAMEWORK_PATH"] = frameworksPath

        process.environment = environment

        // 捕获 stderr 输出
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                print("[ExtensionHost stderr] \(str)", terminator: "")
            }
        }

        // 启动进程（不设置 terminationHandler，让 Host 自己管理生命周期）
        try process.run()
        self.hostProcess = process

        print("[ExtensionHostManager] Started Extension Host process (PID: \(process.processIdentifier))")
    }

    /// 等待 Host 就绪
    private func waitForHostReady(timeout: TimeInterval) async throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            // 检查 socket 文件是否存在
            if FileManager.default.fileExists(atPath: socketPath) {
                print("[ExtensionHostManager] Host socket ready")
                return
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        throw IPCConnectionError.timeout
    }

    /// 处理连接断开（自动重连）
    func handleDisconnect() async {
        print("[ExtensionHostManager] Connection lost, attempting to reconnect...")

        state = .stopped
        ipcBridge = nil

        // 尝试重连
        if restartCount < maxRestartsPerMinute {
            restartCount += 1
            lastRestartTime = Date()

            let delay = Double(restartCount) * 0.5
            print("[ExtensionHostManager] Reconnecting in \(delay)s (attempt \(restartCount))")

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            do {
                try await start()
            } catch {
                print("[ExtensionHostManager] Reconnect failed: \(error)")
                state = .crashed(exitCode: -1)
            }
        } else {
            print("[ExtensionHostManager] Too many reconnect attempts, giving up")
            state = .crashed(exitCode: -1)
        }
    }
}

// MARK: - State Extension

extension ExtensionHostState {
    var isCrashed: Bool {
        if case .crashed = self { return true }
        return false
    }
}
