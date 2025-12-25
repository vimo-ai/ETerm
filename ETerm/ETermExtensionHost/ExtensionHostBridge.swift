// ExtensionHostBridge.swift
// ETermExtensionHost
//
// HostBridge 协议实现 - 通过 IPC 调用主进程能力

import Foundation
import ETermKit

/// Extension Host 端的 HostBridge 实现
///
/// 将插件的调用通过 IPC 转发到主进程执行
final class ExtensionHostBridge: HostBridge, @unchecked Sendable {

    private let connection: IPCConnection
    private var _hostInfo: HostInfo?

    /// 已注册的服务处理器
    private var serviceHandlers: [String: @Sendable ([String: Any]) -> [String: Any]?] = [:]
    private let lock = NSLock()

    init(connection: IPCConnection) {
        self.connection = connection
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
        lock.lock()
        serviceHandlers[name] = handler
        lock.unlock()

        let n = name
        Task { @Sendable in
            try? await self.connection.send(IPCMessage(
                type: .registerService,
                payload: ["name": n]
            ))
        }
    }

    public func callService(
        pluginId: String,
        name: String,
        params: [String: Any]
    ) -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        let pid = pluginId
        let n = name
        let p = copyDictionary(params)

        Task { @Sendable in
            do {
                let response = try await self.connection.request(IPCMessage(
                    type: .callService,
                    pluginId: pid,
                    payload: [
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

    // MARK: - Internal

    func setHostInfo(_ info: HostInfo) {
        _hostInfo = info
    }

    func handleServiceCall(name: String, params: [String: Any]) -> [String: Any]? {
        lock.lock()
        let handler = serviceHandlers[name]
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
        if let icon = decoration.icon { dict["icon"] = icon }
        if let iconColor = decoration.iconColor { dict["iconColor"] = iconColor }
        if let badge = decoration.badge { dict["badge"] = badge }
        if let badgeColor = decoration.badgeColor { dict["badgeColor"] = badgeColor }
        if let backgroundColor = decoration.backgroundColor { dict["backgroundColor"] = backgroundColor }
        dict["showActivity"] = decoration.showActivity
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
