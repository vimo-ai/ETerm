// ExtensionHostBridge.swift
// ETermExtensionHost
//
// HostBridge 协议实现 - 通过 IPC 调用主进程能力

import Foundation
import AppKit
import ETermKit

/// Extension Host 端的 HostBridge 实现
///
/// 将插件的调用通过 IPC 转发到主进程执行
final class ExtensionHostBridge: HostBridge, @unchecked Sendable {

    private var connection: IPCConnection
    private var _hostInfo: HostInfo?

    /// 已注册的服务处理器
    private var serviceHandlers: [String: @Sendable ([String: Any]) -> [String: Any]?] = [:]
    private let lock = NSLock()

    init(connection: IPCConnection) {
        self.connection = connection
    }

    /// 更新连接（当新客户端连接时调用）
    func updateConnection(_ newConnection: IPCConnection) {
        lock.lock()
        self.connection = newConnection
        lock.unlock()
    }

    // MARK: - HostBridge

    public var hostInfo: HostInfo {
        if let info = _hostInfo {
            return info
        }
        return HostInfo(
            version: "0.0.0",
            sdkVersion: ETermKitVersion,
            protocolVersion: IPCProtocolVersion,
            isDebugBuild: true,
            pluginsDirectory: ""
        )
    }

    public func updateViewModel(_ viewModelId: String, data: [String: Any]) {
        // 复制数据以确保线程安全
        let dataCopy = copyDictionary(data)
        let id = viewModelId

        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .updateViewModel,
                pluginId: id,
                payload: dataCopy
            ))
        }
    }

    public func setTabDecoration(terminalId: Int, decoration: TabDecoration?) {
        let termId = terminalId
        let deco = decoration

        Task { @Sendable in
            var payload: [String: Any] = ["terminalId": termId]
            if let d = deco {
                payload["decoration"] = self.encodeDecoration(d)
            }
            try? await self.connection.send(IPCMessage(
                type: .setTabDecoration,
                payload: payload
            ))
        }
    }

    public func clearTabDecoration(terminalId: Int) {
        setTabDecoration(terminalId: terminalId, decoration: nil)
    }

    public func setTabTitle(terminalId: Int, title: String) {
        let termId = terminalId
        let t = title

        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .setTabTitle,
                payload: [
                    "terminalId": termId,
                    "title": t
                ]
            ))
        }
    }

    public func clearTabTitle(terminalId: Int) {
        let termId = terminalId

        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .clearTabTitle,
                payload: ["terminalId": termId]
            ))
        }
    }

    public func writeToTerminal(terminalId: Int, data: String) {
        let termId = terminalId
        let d = data

        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .writeTerminal,
                payload: [
                    "terminalId": termId,
                    "data": d
                ]
            ))
        }
    }

    public func sendInput(terminalId: Int, text: String, pressEnter: Bool) {
        let termId = terminalId
        let t = text
        let enter = pressEnter

        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .sendInput,
                payload: [
                    "terminalId": termId,
                    "text": t,
                    "pressEnter": enter
                ]
            ))
        }
    }

    public func createTerminalTab(cwd: String?) -> Int? {
        // isolated 模式暂不支持创建终端 Tab（需要访问 WindowManager）
        // 如果需要支持，可添加 IPC 消息类型 .createTerminalTab
        return nil
    }

    public func getTerminalInfo(terminalId: Int) -> TerminalInfo? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: TerminalInfo?
        let termId = terminalId

        Task { @Sendable in
            do {
                let response = try await self.connection.request(IPCMessage(
                    type: .getTerminalInfo,
                    payload: ["terminalId": termId]
                ))
                if response.type == .response {
                    result = self.decodeTerminalInfo(response.rawPayload)
                }
            } catch {
                // 超时或错误
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 30)
        return result
    }

    public func getAllTerminals() -> [TerminalInfo] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [TerminalInfo] = []

        Task { @Sendable in
            do {
                let response = try await self.connection.request(IPCMessage(
                    type: .getAllTerminals
                ))
                if response.type == .response,
                   let terminals = response.rawPayload["terminals"] as? [[String: Any]] {
                    result = terminals.compactMap { self.decodeTerminalInfo($0) }
                }
            } catch {
                // 超时或错误
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 30)
        return result
    }

    public func registerService(
        name: String,
        handler: @escaping @Sendable ([String: Any]) -> [String: Any]?
    ) {
        // 无调用方信息的版本（兼容性保留，但消息格式不完整）
        registerServiceWithCaller(callerPluginId: nil, name: name, handler: handler)
    }

    /// 带调用方信息的服务注册
    func registerServiceWithCaller(
        callerPluginId: String?,
        name: String,
        handler: @escaping @Sendable ([String: Any]) -> [String: Any]?
    ) {
        // 存储时使用完整 key: pluginId.name
        let storageKey = callerPluginId.map { "\($0).\(name)" } ?? name
        lock.lock()
        serviceHandlers[storageKey] = handler
        lock.unlock()

        let n = name
        let callerId = callerPluginId
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .registerService,
                pluginId: callerId,
                payload: ["name": n]
            ))
        }
    }

    public func callService(
        pluginId: String,
        name: String,
        params: [String: Any]
    ) -> [String: Any]? {
        // 无调用方信息的版本（兼容性保留，但消息格式不完整）
        callServiceWithCaller(callerPluginId: nil, targetPluginId: pluginId, name: name, params: params)
    }

    /// 带调用方信息的服务调用
    func callServiceWithCaller(
        callerPluginId: String?,
        targetPluginId: String,
        name: String,
        params: [String: Any]
    ) -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        let callerId = callerPluginId
        let targetId = targetPluginId
        let n = name
        let p = copyDictionary(params)

        Task { @Sendable in
            do {
                let response = try await self.connection.request(IPCMessage(
                    type: .callService,
                    pluginId: callerId,  // 调用方 ID（用于权限检查）
                    payload: [
                        "targetPluginId": targetId,  // 目标插件 ID
                        "name": n,
                        "params": p
                    ]
                ))
                if response.type == .response {
                    result = response.rawPayload["result"] as? [String: Any]
                }
            } catch {
                // 超时或错误
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 30)
        return result
    }

    public func emit(eventName: String, payload: [String: Any]) {
        let name = eventName
        let p = copyDictionary(payload)

        Task { @Sendable in
            var eventPayload = p
            eventPayload["eventName"] = name
            try? await self.connection.send(IPCMessage(
                type: .emit,
                payload: eventPayload
            ))
        }
    }

    // MARK: - 底部停靠视图控制

    public func showBottomDock(_ id: String) {
        let dockId = id
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .showBottomDock,
                payload: ["id": dockId]
            ))
        }
    }

    public func hideBottomDock(_ id: String) {
        let dockId = id
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .hideBottomDock,
                payload: ["id": dockId]
            ))
        }
    }

    public func toggleBottomDock(_ id: String) {
        let dockId = id
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .toggleBottomDock,
                payload: ["id": dockId]
            ))
        }
    }

    // MARK: - 底部 Overlay 控制

    public func showBottomOverlay(_ id: String) {
        let overlayId = id
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .showBottomOverlay,
                payload: ["id": overlayId]
            ))
        }
    }

    public func hideBottomOverlay(_ id: String) {
        let overlayId = id
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .hideBottomOverlay,
                payload: ["id": overlayId]
            ))
        }
    }

    public func toggleBottomOverlay(_ id: String) {
        let overlayId = id
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .toggleBottomOverlay,
                payload: ["id": overlayId]
            ))
        }
    }

    // MARK: - 信息面板控制

    public func showInfoPanel(_ id: String) {
        let panelId = id
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .showInfoPanel,
                payload: ["id": panelId]
            ))
        }
    }

    public func hideInfoPanel(_ id: String) {
        let panelId = id
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .hideInfoPanel,
                payload: ["id": panelId]
            ))
        }
    }

    // MARK: - 选中气泡控制

    public func showBubble(text: String, position: [String: Double]) {
        let t = text
        let pos = position
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .showBubble,
                payload: [
                    "text": t,
                    "position": pos
                ]
            ))
        }
    }

    public func expandBubble() {
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .expandBubble
            ))
        }
    }

    public func hideBubble() {
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .hideBubble
            ))
        }
    }

    // MARK: - 窗口与终端查询

    public func getActiveTabCwd() -> String? {
        // isolated 模式暂不支持，返回 nil
        return nil
    }

    public func getKeyWindowFrame() -> CGRect? {
        // isolated 模式暂不支持，返回 nil
        return nil
    }

    // MARK: - 嵌入终端

    public func createEmbeddedTerminal(cwd: String) -> Int {
        // isolated 模式不支持嵌入终端（需要 Metal 渲染）
        return -1
    }

    public func closeEmbeddedTerminal(terminalId: Int) {
        // isolated 模式不支持嵌入终端
    }

    // MARK: - AI 服务

    func aiChat(
        model: String,
        system: String?,
        user: String,
        extraBody: [String: Any]?
    ) async throws -> String {
        // isolated 模式暂不支持 AI 服务（需要 API Key 等敏感信息）
        throw NSError(domain: "ExtensionHostBridge", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "AI service not available in isolated mode"
        ])
    }

    func aiStreamChat(
        model: String,
        system: String?,
        user: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws {
        // isolated 模式暂不支持 AI 服务
        throw NSError(domain: "ExtensionHostBridge", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "AI service not available in isolated mode"
        ])
    }

    // MARK: - 选中操作注册

    func registerSelectionAction(_ action: SelectionAction) {
        // 通过 IPC 转发到主进程
        let actionData: [String: Any] = [
            "id": action.id,
            "title": action.title,
            "icon": action.icon,
            "priority": action.priority,
            "autoTriggerOnMode": action.autoTriggerOnMode as Any
        ]
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .registerSelectionAction,
                payload: actionData
            ))
        }
    }

    func unregisterSelectionAction(actionId: String) {
        let id = actionId
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .unregisterSelectionAction,
                payload: ["actionId": id]
            ))
        }
    }

    // MARK: - 命令注册

    func registerCommand(_ command: PluginCommand) {
        let cmd = command
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .registerCommand,
                payload: [
                    "id": cmd.id,
                    "title": cmd.title,
                    "icon": cmd.icon as Any
                ]
            ))
        }
    }

    func unregisterCommand(commandId: String) {
        let cmdId = commandId
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .unregisterCommand,
                payload: ["commandId": cmdId]
            ))
        }
    }

    // MARK: - 快捷键绑定

    func bindKeyboard(_ shortcut: KeyboardShortcut, to commandId: String) {
        let sc = shortcut
        let cmdId = commandId
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .bindKeyboard,
                payload: [
                    "key": sc.key,
                    "modifiers": sc.modifiers.rawValue,
                    "commandId": cmdId
                ]
            ))
        }
    }

    func unbindKeyboard(_ shortcut: KeyboardShortcut) {
        let sc = shortcut
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .unbindKeyboard,
                payload: [
                    "key": sc.key,
                    "modifiers": sc.modifiers.rawValue
                ]
            ))
        }
    }

    // MARK: - Composer 控制

    func showComposer() {
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .showComposer
            ))
        }
    }

    func hideComposer() {
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .hideComposer
            ))
        }
    }

    func toggleComposer() {
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .toggleComposer
            ))
        }
    }

    // MARK: - 终端操作扩展

    func getActiveTerminalId() -> Int? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Int?

        Task { @Sendable in
            do {
                let response = try await self.connection.request(IPCMessage(
                    type: .getActiveTerminalId
                ))
                if response.type == .response {
                    result = response.rawPayload["terminalId"] as? Int
                }
            } catch {
                // 超时或错误
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    // MARK: - Socket

    var socketDirectory: String {
        // 从环境变量获取，或使用默认路径
        if let dir = ProcessInfo.processInfo.environment["ETERM_SOCKET_DIR"] {
            return dir
        }
        // 支持 ETERM_HOME / VIMO_HOME 环境变量
        let etermHome: String
        if let customEtermHome = ProcessInfo.processInfo.environment["ETERM_HOME"] {
            etermHome = customEtermHome
        } else {
            let vimoRoot = ProcessInfo.processInfo.environment["VIMO_HOME"]
                ?? NSHomeDirectory() + "/.vimo"
            etermHome = vimoRoot + "/eterm"
        }
        return etermHome + "/run/sockets"
    }

    func socketPath(for namespace: String) -> String {
        return "\(socketDirectory)/\(namespace).sock"
    }

    var socketService: SocketServiceProtocol? {
        // isolated 模式不支持 SocketService（SocketIO 库只在主应用链接）
        nil
    }

    // MARK: - Internal

    func setHostInfo(_ info: HostInfo) {
        _hostInfo = info
    }

    /// 处理来自主进程的服务调用（用于 isolated 模式插件提供的服务）
    ///
    /// - Parameters:
    ///   - pluginId: 目标插件 ID
    ///   - name: 服务名称
    ///   - params: 调用参数
    /// - Returns: 服务返回结果
    func handleServiceCall(pluginId: String, name: String, params: [String: Any]) -> [String: Any]? {
        let key = "\(pluginId).\(name)"
        lock.lock()
        let handler = serviceHandlers[key]
        lock.unlock()
        return handler?(params)
    }

    // MARK: - Private Helpers

    /// 深复制字典（确保线程安全）
    private func copyDictionary(_ dict: [String: Any]) -> [String: Any] {
        var copy: [String: Any] = [:]
        for (key, value) in dict {
            if let nested = value as? [String: Any] {
                copy[key] = copyDictionary(nested)
            } else if let array = value as? [Any] {
                copy[key] = copyArray(array)
            } else {
                // 基本类型直接复制
                copy[key] = value
            }
        }
        return copy
    }

    private func copyArray(_ array: [Any]) -> [Any] {
        return array.map { element in
            if let nested = element as? [String: Any] {
                return copyDictionary(nested)
            } else if let nestedArray = element as? [Any] {
                return copyArray(nestedArray)
            } else {
                return element
            }
        }
    }

    private func encodeDecoration(_ decoration: TabDecoration) -> [String: Any] {
        var dict: [String: Any] = [:]

        // 编码优先级
        switch decoration.priority {
        case .system(let level):
            dict["priorityType"] = "system"
            dict["priorityValue"] = level.rawValue
        case .plugin(let id, let priority):
            dict["priorityType"] = "plugin"
            dict["priorityPluginId"] = id
            dict["priorityValue"] = priority
        }

        // 编码颜色（RGBA）
        dict["colorRed"] = decoration.color.redComponent
        dict["colorGreen"] = decoration.color.greenComponent
        dict["colorBlue"] = decoration.color.blueComponent
        dict["colorAlpha"] = decoration.color.alphaComponent

        // 编码样式
        switch decoration.style {
        case .solid:
            dict["style"] = "solid"
        case .pulse:
            dict["style"] = "pulse"
        case .breathing:
            dict["style"] = "breathing"
        }

        dict["persistent"] = decoration.persistent

        return dict
    }

    private func decodeTerminalInfo(_ dict: [String: Any]) -> TerminalInfo? {
        guard let terminalId = dict["terminalId"] as? Int,
              let tabId = dict["tabId"] as? String,
              let panelId = dict["panelId"] as? String,
              let cwd = dict["cwd"] as? String,
              let columns = dict["columns"] as? Int,
              let rows = dict["rows"] as? Int,
              let isActive = dict["isActive"] as? Bool else {
            return nil
        }

        return TerminalInfo(
            terminalId: terminalId,
            tabId: tabId,
            panelId: panelId,
            cwd: cwd,
            columns: columns,
            rows: rows,
            isActive: isActive,
            pid: dict["pid"] as? Int32
        )
    }
}
