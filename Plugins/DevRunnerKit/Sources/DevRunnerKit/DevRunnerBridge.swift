//
//  DevRunnerBridge.swift
//  DevRunnerKit
//
//  Swift FFI bridge wrapping the dev_runner_app C functions.
//  Follows the MCPRouterBridge pattern: @MainActor ObservableObject,
//  opaque handle lifecycle, @Published state for UI binding.

import Foundation
import DevRunnerFFI

// MARK: - Per-project UI state

public struct ProjectState: Identifiable {
    public var id: String { project.path }
    public let project: ProjectInfo
    public var targets: [TargetInfo] = []
    public var selectedTarget: String? = nil
    public var process: ProcessInfo? = nil
    public var metrics: MetricsInfo? = nil
    public var isExpanded: Bool = true
    /// Terminal tab ID if a terminal is open for this project
    public var terminalId: Int? = nil
    /// Daemon session ID — 用于终端关闭后 reattach
    public var daemonSessionId: String? = nil

    public init(project: ProjectInfo) {
        self.project = project
    }
}

// MARK: - Bridge

/// DevRunner Bridge — 封装 Rust FFI 调用，供 SwiftUI 视图绑定
@MainActor
public final class DevRunnerBridge: ObservableObject {

    public static let shared = DevRunnerBridge()

    /// 每个已打开项目的 UI 状态（含 targets / process / metrics）
    @Published public var projectStates: [ProjectState] = []

    /// 正在追踪的所有进程（不局限于已打开项目）
    @Published public var processes: [ProcessInfo] = []

    private var handle: OpaquePointer?

    private init() {
        handle = dev_runner_init()
        if handle == nil {
            logError("[DevRunner] init returned nil handle")
        }
        // Rust init 已自动恢复持久化的项目，刷新到 UI 状态
        refreshOpened()
        loadTargetsForRestoredProjects()
    }

    /// 为恢复的项目加载 targets
    private func loadTargetsForRestoredProjects() {
        for i in projectStates.indices {
            if projectStates[i].targets.isEmpty {
                if let targets = try? listTargets(for: projectStates[i].project.path) {
                    projectStates[i].targets = targets
                    if projectStates[i].selectedTarget == nil, let first = targets.first {
                        projectStates[i].selectedTarget = first.name
                    }
                }
            }
        }
    }

    deinit {
        if let handle = handle {
            dev_runner_free(handle)
        }
    }

    // MARK: - Project Discovery (stateless)

    /// 检测路径下的项目（无需 handle）
    public func detectProjects(at path: String) throws -> [ProjectInfo] {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let jsonPtr = path.withCString { pathPtr in
            dev_runner_detect(pathPtr, &errorPtr)
        }
        return try decodeFFIArray(jsonPtr, errorPtr: errorPtr)
    }

    /// 扫描路径下所有项目（深度搜索，无需 handle）
    public func scanProjects(at path: String) throws -> [ProjectInfo] {
        var errorPtr: UnsafeMutablePointer<CChar>?
        let jsonPtr = path.withCString { pathPtr in
            dev_runner_scan(pathPtr, &errorPtr)
        }
        return try decodeFFIArray(jsonPtr, errorPtr: errorPtr)
    }

    // MARK: - Project Lifecycle

    /// 打开项目，并刷新 projectStates
    public func openProject(_ path: String) throws {
        let handle = try requireHandle()
        var errorPtr: UnsafeMutablePointer<CChar>?
        let jsonPtr = path.withCString { pathPtr in
            dev_runner_open(handle, pathPtr, &errorPtr)
        }
        // open 返回的是 ProjectInfo JSON，但我们只需要刷新列表
        if let jsonPtr = jsonPtr {
            dev_runner_free_string(jsonPtr)
        }
        if let errorPtr = errorPtr {
            let msg = String(cString: errorPtr)
            dev_runner_free_string(errorPtr)
            throw DevRunnerError.ffiError(msg)
        }
        refreshOpened()
    }

    /// 关闭项目，并刷新 projectStates
    public func closeProject(_ path: String) throws {
        let handle = try requireHandle()
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = path.withCString { pathPtr in
            dev_runner_close(handle, pathPtr, &errorPtr)
        }
        if !success {
            let msg = extractError(&errorPtr) ?? "Unknown error"
            throw DevRunnerError.ffiError(msg)
        }
        refreshOpened()
    }

    // MARK: - Targets

    /// 列出项目的可用 targets
    public func listTargets(for projectPath: String) throws -> [TargetInfo] {
        let handle = try requireHandle()
        var errorPtr: UnsafeMutablePointer<CChar>?
        let jsonPtr = projectPath.withCString { pathPtr in
            dev_runner_list_targets(handle, pathPtr, &errorPtr)
        }
        return try decodeFFIArray(jsonPtr, errorPtr: errorPtr)
    }

    // MARK: - Run / Build / Stop

    /// 启动监控模式进程：获取命令 → 生成包装命令，返回 MonitoredProcessResult
    ///
    /// 不直接 spawn 进程，而是返回包装命令字符串，由 Swift 通过
    /// `createTerminalTab(cwd:)` + `sendInput(wrappedCommand)` 发送到 shell tab。
    /// Rust 端监控线程通过状态文件跟踪进程生命周期。
    public func startMonitored(projectPath: String, target: String) throws -> MonitoredProcessResult {
        let handle = try requireHandle()

        // 1. 获取运行命令
        var errorPtr: UnsafeMutablePointer<CChar>?
        let cmdJsonPtr = projectPath.withCString { pathPtr in
            target.withCString { targetPtr in
                dev_runner_run_cmd(handle, pathPtr, targetPtr, nil, &errorPtr)
            }
        }
        let commandJson = try extractString(cmdJsonPtr, errorPtr: &errorPtr)

        // 2. 创建监控进程（返回 process_id + wrapped_command + cwd）
        var startErrorPtr: UnsafeMutablePointer<CChar>?
        let resultJsonPtr = projectPath.withCString { pathPtr in
            target.withCString { targetPtr in
                commandJson.withCString { cmdPtr in
                    dev_runner_start_monitored(handle, pathPtr, targetPtr, cmdPtr, &startErrorPtr)
                }
            }
        }
        let resultJson = try extractString(resultJsonPtr, errorPtr: &startErrorPtr)

        return try decodeJSON(resultJson)
    }

    /// 编译 target（监控模式）
    public func buildMonitored(projectPath: String, target: String, options: [String: Any]? = nil) throws -> MonitoredProcessResult {
        let handle = try requireHandle()

        let optionsJson: String?
        if let options = options {
            let data = try JSONSerialization.data(withJSONObject: options)
            optionsJson = String(data: data, encoding: .utf8)
        } else {
            optionsJson = nil
        }

        // 1. 获取 build 命令
        var errorPtr: UnsafeMutablePointer<CChar>?
        let cmdJsonPtr: UnsafeMutablePointer<CChar>?
        if let optionsJson = optionsJson {
            cmdJsonPtr = projectPath.withCString { pathPtr in
                target.withCString { targetPtr in
                    optionsJson.withCString { optsPtr in
                        dev_runner_build_cmd(handle, pathPtr, targetPtr, optsPtr, &errorPtr)
                    }
                }
            }
        } else {
            cmdJsonPtr = projectPath.withCString { pathPtr in
                target.withCString { targetPtr in
                    dev_runner_build_cmd(handle, pathPtr, targetPtr, nil, &errorPtr)
                }
            }
        }
        let commandJson = try extractString(cmdJsonPtr, errorPtr: &errorPtr)

        // 2. 创建监控进程
        var startErrorPtr: UnsafeMutablePointer<CChar>?
        let resultJsonPtr = projectPath.withCString { pathPtr in
            target.withCString { targetPtr in
                commandJson.withCString { cmdPtr in
                    dev_runner_start_monitored(handle, pathPtr, targetPtr, cmdPtr, &startErrorPtr)
                }
            }
        }
        let resultJson = try extractString(resultJsonPtr, errorPtr: &startErrorPtr)

        return try decodeJSON(resultJson)
    }

    /// 停止进程
    public func stopProcess(_ processId: String) throws {
        let handle = try requireHandle()
        var errorPtr: UnsafeMutablePointer<CChar>?
        let success = processId.withCString { idPtr in
            dev_runner_stop_process(handle, idPtr, &errorPtr)
        }
        if !success {
            let msg = extractError(&errorPtr) ?? "Unknown error"
            throw DevRunnerError.ffiError(msg)
        }
    }

    // MARK: - Metrics

    /// 获取 pid 对应的资源使用指标
    public func getMetrics(pid: UInt32) throws -> MetricsInfo {
        let handle = try requireHandle()
        var errorPtr: UnsafeMutablePointer<CChar>?
        let jsonPtr = dev_runner_get_metrics(handle, pid, &errorPtr)
        let json = try extractString(jsonPtr, errorPtr: &errorPtr)
        return try decodeJSON(json)
    }

    // MARK: - Refresh (no-throw, updates @Published)

    /// 刷新已打开项目列表，更新 projectStates（保留已有的 targets/process/metrics）
    public func refreshOpened() {
        guard let handle = handle else {
            logError("[DevRunner] refreshOpened: handle not initialized")
            return
        }

        var errorPtr: UnsafeMutablePointer<CChar>?
        guard let jsonPtr = dev_runner_list_opened(handle, &errorPtr) else {
            if let errorPtr = errorPtr {
                logError("[DevRunner] list_opened error: \(String(cString: errorPtr))")
                dev_runner_free_string(errorPtr)
            }
            return
        }

        let json = String(cString: jsonPtr)
        dev_runner_free_string(jsonPtr)

        guard let data = json.data(using: .utf8) else { return }

        do {
            let projects = try JSONDecoder().decode([ProjectInfo].self, from: data)
            // Merge: preserve existing per-project state for unchanged projects
            let existingByPath = Dictionary(uniqueKeysWithValues: projectStates.map { ($0.project.path, $0) })
            projectStates = projects.map { project in
                existingByPath[project.path] ?? ProjectState(project: project)
            }
        } catch {
            logError("[DevRunner] Failed to decode opened projects: \(error)")
        }
    }

    /// 刷新所有进程列表，更新 @Published processes（不抛出，记录日志）
    public func refreshProcesses() {
        guard let handle = handle else {
            logError("[DevRunner] refreshProcesses: handle not initialized")
            return
        }

        var errorPtr: UnsafeMutablePointer<CChar>?
        guard let jsonPtr = dev_runner_list_processes(handle, &errorPtr) else {
            if let errorPtr = errorPtr {
                logError("[DevRunner] list_processes error: \(String(cString: errorPtr))")
                dev_runner_free_string(errorPtr)
            }
            return
        }

        let json = String(cString: jsonPtr)
        dev_runner_free_string(jsonPtr)

        guard let data = json.data(using: .utf8) else { return }

        do {
            processes = try JSONDecoder().decode([ProcessInfo].self, from: data)
        } catch {
            logError("[DevRunner] Failed to decode processes: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func requireHandle() throws -> OpaquePointer {
        guard let handle = handle else {
            throw DevRunnerError.handleNotInitialized
        }
        return handle
    }

    /// C 字符串错误指针 → Swift String + 释放
    private func extractError(_ errorPtr: inout UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr = errorPtr else { return nil }
        let msg = String(cString: ptr)
        dev_runner_free_string(ptr)
        errorPtr = nil
        return msg
    }

    /// FFI 返回 char* JSON 字符串 → Swift String，失败时抛出
    private func extractString(
        _ ptr: UnsafeMutablePointer<CChar>?,
        errorPtr: inout UnsafeMutablePointer<CChar>?
    ) throws -> String {
        if let errorPtr = errorPtr {
            let msg = String(cString: errorPtr)
            dev_runner_free_string(errorPtr)
            throw DevRunnerError.ffiError(msg)
        }
        guard let ptr = ptr else {
            throw DevRunnerError.nullResult
        }
        let result = String(cString: ptr)
        dev_runner_free_string(ptr)
        return result
    }

    /// FFI 返回 char* JSON → 解码为数组类型 T，失败时抛出
    private func decodeFFIArray<T: Decodable>(
        _ ptr: UnsafeMutablePointer<CChar>?,
        errorPtr: UnsafeMutablePointer<CChar>?
    ) throws -> [T] {
        if let errorPtr = errorPtr {
            let msg = String(cString: errorPtr)
            dev_runner_free_string(errorPtr)
            throw DevRunnerError.ffiError(msg)
        }
        guard let ptr = ptr else {
            throw DevRunnerError.nullResult
        }
        let json = String(cString: ptr)
        dev_runner_free_string(ptr)
        return try decodeJSON(json)
    }

    /// JSON 字符串 → 解码为类型 T
    private func decodeJSON<T: Decodable>(_ json: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw DevRunnerError.jsonDecodingFailed("UTF-8 conversion failed")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DevRunnerError.jsonDecodingFailed("\(error)")
        }
    }

    private func logError(_ message: String) {
        print(message)
    }
}
