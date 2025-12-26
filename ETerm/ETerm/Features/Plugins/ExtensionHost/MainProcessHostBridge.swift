//
//  MainProcessHostBridge.swift
//  ETerm
//
//  主进程模式的 HostBridge 实现
//  直接调用主进程服务，无需 IPC

import Foundation
import ETermKit

/// 主进程模式 HostBridge
///
/// 当插件以 `runMode: main` 运行时使用。
/// 直接调用主进程的服务，无需 IPC 通信。
final class MainProcessHostBridge: HostBridge, @unchecked Sendable {

    private let pluginId: String
    private let manifest: PluginManifest

    /// 全局服务处理器存储 (pluginId.serviceName -> handler)
    private static var globalServiceHandlers: [String: @Sendable ([String: Any]) -> [String: Any]?] = [:]
    private static let lock = NSLock()

    init(pluginId: String, manifest: PluginManifest) {
        self.pluginId = pluginId
        self.manifest = manifest
    }

    // MARK: - HostBridge

    var hostInfo: HostInfo {
        HostInfo(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            sdkVersion: ETermKitVersion,
            protocolVersion: IPCProtocolVersion,
            isDebugBuild: {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }(),
            pluginsDirectory: ETermPaths.plugins
        )
    }

    func updateViewModel(_ viewModelId: String, data: [String: Any]) {
        let vmId = viewModelId
        let d = copyDictionary(data)

        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.UpdateViewModel"),
                    object: nil,
                    userInfo: ["pluginId": vmId, "data": d]
                )
            }
        }
    }

    func setTabDecoration(terminalId: Int, decoration: ETermKit.TabDecoration?) {
        let termId = terminalId
        let deco = decoration

        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.SetTabDecoration"),
                    object: nil,
                    userInfo: ["terminalId": termId, "decoration": deco as Any]
                )
            }
        }
    }

    func clearTabDecoration(terminalId: Int) {
        setTabDecoration(terminalId: terminalId, decoration: nil)
    }

    func setTabTitle(terminalId: Int, title: String) {
        let termId = terminalId
        let t = title

        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.SetTabTitle"),
                    object: nil,
                    userInfo: ["terminalId": termId, "title": t]
                )
            }
        }
    }

    func clearTabTitle(terminalId: Int) {
        let termId = terminalId

        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.ClearTabTitle"),
                    object: nil,
                    userInfo: ["terminalId": termId]
                )
            }
        }
    }

    func writeToTerminal(terminalId: Int, data: String) {
        let termId = terminalId
        let d = data

        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.WriteToTerminal"),
                    object: nil,
                    userInfo: ["terminalId": termId, "data": d]
                )
            }
        }
    }

    func getTerminalInfo(terminalId: Int) -> TerminalInfo? {
        // 暂时返回 nil，后续实现
        return nil
    }

    func getAllTerminals() -> [TerminalInfo] {
        // 暂时返回空，后续实现
        return []
    }

    func registerService(
        name: String,
        handler: @escaping @Sendable ([String: Any]) -> [String: Any]?
    ) {
        let key = "\(pluginId).\(name)"
        Self.lock.lock()
        Self.globalServiceHandlers[key] = handler
        Self.lock.unlock()
        print("[MainProcessHostBridge] Registered service: \(key)")
    }

    func callService(
        pluginId: String,
        name: String,
        params: [String: Any]
    ) -> [String: Any]? {
        let key = "\(pluginId).\(name)"
        Self.lock.lock()
        let handler = Self.globalServiceHandlers[key]
        Self.lock.unlock()
        return handler?(params)
    }

    func emit(eventName: String, payload: [String: Any]) {
        let name = eventName
        let p = copyDictionary(payload)

        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.PluginEvent"),
                    object: nil,
                    userInfo: ["eventName": name, "payload": p]
                )
            }
        }
    }

    // MARK: - 底部停靠视图控制

    func showBottomDock(_ id: String) {
        let pid = pluginId
        Task { @Sendable in
            await MainActor.run {
                SDKPluginLoader.shared.showBottomDock(pluginId: pid)
            }
        }
    }

    func hideBottomDock(_ id: String) {
        let pid = pluginId
        Task { @Sendable in
            await MainActor.run {
                SDKPluginLoader.shared.hideBottomDock(pluginId: pid)
            }
        }
    }

    func toggleBottomDock(_ id: String) {
        let pid = pluginId
        Task { @Sendable in
            await MainActor.run {
                SDKPluginLoader.shared.toggleBottomDock(pluginId: pid)
            }
        }
    }

    // MARK: - 信息面板控制

    func showInfoPanel(_ id: String) {
        let panelId = id
        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.ShowInfoPanel"),
                    object: nil,
                    userInfo: ["id": panelId]
                )
            }
        }
    }

    func hideInfoPanel(_ id: String) {
        let panelId = id
        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.HideInfoPanel"),
                    object: nil,
                    userInfo: ["id": panelId]
                )
            }
        }
    }

    // MARK: - 选中气泡控制

    func showBubble(text: String, position: [String: Double]) {
        let t = text
        let pos = position

        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.ShowBubble"),
                    object: nil,
                    userInfo: ["text": t, "position": pos]
                )
            }
        }
    }

    func expandBubble() {
        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.ExpandBubble"),
                    object: nil,
                    userInfo: [:]
                )
            }
        }
    }

    func hideBubble() {
        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.HideBubble"),
                    object: nil,
                    userInfo: [:]
                )
            }
        }
    }

    // MARK: - Private Helpers

    private func copyDictionary(_ dict: [String: Any]) -> [String: Any] {
        var copy: [String: Any] = [:]
        for (key, value) in dict {
            if let nested = value as? [String: Any] {
                copy[key] = copyDictionary(nested)
            } else if let array = value as? [Any] {
                copy[key] = copyArray(array)
            } else {
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
}
