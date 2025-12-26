//
//  ExtensionHostManager.swift
//  ETerm
//
//  Extension Host 进程管理器
//  负责启动、监控和重启 Extension Host 进程

import Foundation
import ETermKit

/// Extension Host 状态
enum ExtensionHostState: Equatable {
    case stopped
    case starting
    case running
    case crashed(exitCode: Int32)
    case restarting
}

/// Extension Host 管理器
///
/// 职责：
/// - 启动 Extension Host 可执行文件
/// - 监控进程状态
/// - 崩溃后自动重启
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

    /// Socket 路径
    private var socketPath: String {
        "/tmp/eterm-extension-host.sock"
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
        let etermBinPath = NSHomeDirectory() + "/.eterm/bin/ETermExtensionHost"
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

    /// 启动 Extension Host
    func start() async throws {
        guard state == .stopped || state.isCrashed else {
            return
        }

        state = .starting

        // 1. 启动 IPC 服务端
        let bridge = PluginIPCBridge(socketPath: socketPath)
        try await bridge.start()
        self.ipcBridge = bridge

        // 2. 启动 Host 进程
        try startHostProcess()

        // 3. 等待握手完成
        try await bridge.waitForHandshake(timeout: 10.0)

        state = .running
        restartCount = 0

        print("[ExtensionHostManager] Extension Host started successfully")
    }

    /// 停止 Extension Host
    func stop() async {
        state = .stopped

        // 1. 停止 IPC 服务端
        await ipcBridge?.stop()
        ipcBridge = nil

        // 2. 终止进程
        hostProcess?.terminate()
        hostProcess = nil

        // 3. 清理 socket 文件
        try? FileManager.default.removeItem(atPath: socketPath)

        print("[ExtensionHostManager] Extension Host stopped")
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

    /// 启动 Host 进程
    private func startHostProcess() throws {
        let execPath = hostExecutablePath
        print("[ExtensionHostManager] Launching: \(execPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = ["--socket", socketPath]

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

        // 设置终止处理
        process.terminationHandler = { [weak self] proc in
            Task {
                await self?.handleProcessTermination(exitCode: proc.terminationStatus)
            }
        }

        // 启动进程
        try process.run()
        self.hostProcess = process

        print("[ExtensionHostManager] Started Extension Host process (PID: \(process.processIdentifier))")
    }

    /// 处理进程终止
    private func handleProcessTermination(exitCode: Int32) async {
        print("[ExtensionHostManager] Extension Host terminated with exit code: \(exitCode)")

        hostProcess = nil

        // 正常退出不重启
        if exitCode == 0 {
            state = .stopped
            return
        }

        // 崩溃处理
        state = .crashed(exitCode: exitCode)

        // 检查是否需要重启
        if shouldRestart() {
            await attemptRestart()
        } else {
            print("[ExtensionHostManager] Too many restarts, giving up")
        }
    }

    /// 判断是否应该重启
    private func shouldRestart() -> Bool {
        let now = Date()

        // 如果距离上次重启超过 1 分钟，重置计数器
        if let lastRestart = lastRestartTime,
           now.timeIntervalSince(lastRestart) > 60 {
            restartCount = 0
        }

        return restartCount < maxRestartsPerMinute
    }

    /// 尝试重启
    private func attemptRestart() async {
        state = .restarting
        restartCount += 1
        lastRestartTime = Date()

        // 退避延迟：随重启次数增加
        let delay = Double(restartCount) * 0.5
        print("[ExtensionHostManager] Restarting in \(delay)s (attempt \(restartCount))")

        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        do {
            try await start()
        } catch {
            print("[ExtensionHostManager] Restart failed: \(error)")
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
