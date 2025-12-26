//
//  MainProcessHostBridge.swift
//  ETerm
//
//  主进程模式的 HostBridge 实现
//  直接调用主进程服务，无需 IPC

import Foundation
import AppKit
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
                print("[MainProcessHostBridge] showInfoPanel: \(panelId)")
                InfoWindowRegistry.shared.showContent(id: panelId)
            }
        }
    }

    func hideInfoPanel(_ id: String) {
        let panelId = id
        Task { @Sendable in
            await MainActor.run {
                print("[MainProcessHostBridge] hideInfoPanel: \(panelId)")
                InfoWindowRegistry.shared.hideContent(id: panelId)
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

    // MARK: - 窗口与终端查询

    func getActiveTabCwd() -> String? {
        guard let keyWindow = WindowManager.shared.keyWindow,
              let coordinator = WindowManager.shared.getCoordinator(for: keyWindow.windowNumber) else {
            return nil
        }
        return coordinator.getActiveTabCwd()
    }

    func getKeyWindowFrame() -> CGRect? {
        return WindowManager.shared.keyWindow?.frame
    }

    // MARK: - 嵌入终端

    /// 已创建的嵌入终端 (terminalId -> TerminalPoolWrapper)
    private static var embeddedTerminals: [Int: TerminalPoolWrapper] = [:]
    private static var embeddedTerminalLock = NSLock()
    private static var nextEmbeddedTerminalId: Int = 10000  // 从 10000 开始，避免与主终端冲突

    func createEmbeddedTerminal(cwd: String) -> Int {
        // 同步执行，在主线程创建终端
        var resultId: Int = -1

        if Thread.isMainThread {
            resultId = Self.doCreateEmbeddedTerminal(cwd: cwd)
        } else {
            DispatchQueue.main.sync {
                resultId = Self.doCreateEmbeddedTerminal(cwd: cwd)
            }
        }

        return resultId
    }

    private static func doCreateEmbeddedTerminal(cwd: String) -> Int {
        // 分配 ID
        embeddedTerminalLock.lock()
        let terminalId = nextEmbeddedTerminalId
        nextEmbeddedTerminalId += 1
        embeddedTerminalLock.unlock()

        // 通知创建嵌入终端
        NotificationCenter.default.post(
            name: NSNotification.Name("ETerm.CreateEmbeddedTerminal"),
            object: nil,
            userInfo: ["terminalId": terminalId, "cwd": cwd]
        )

        return terminalId
    }

    func closeEmbeddedTerminal(terminalId: Int) {
        let termId = terminalId

        Task { @Sendable in
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ETerm.CloseEmbeddedTerminal"),
                    object: nil,
                    userInfo: ["terminalId": termId]
                )
            }
        }
    }

    // MARK: - AI 服务

    func aiChat(
        model: String,
        system: String?,
        user: String,
        extraBody: [String: Any]?
    ) async throws -> String {
        // 直接调用主程序的 AIService
        return try await AIService.shared.chatText(
            model: model,
            system: system,
            user: user,
            extraBody: extraBody
        )
    }

    func aiStreamChat(
        model: String,
        system: String?,
        user: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws {
        // 直接调用主程序的 AIService
        try await AIService.shared.streamText(
            model: model,
            system: system,
            user: user,
            onChunk: onChunk
        )
    }

    // MARK: - 选中操作注册

    func registerSelectionAction(_ action: SelectionAction) {
        let a = action
        Task { @Sendable in
            await MainActor.run {
                SelectionActionRegistry.shared.register(a)
            }
        }
    }

    func unregisterSelectionAction(actionId: String) {
        let id = actionId
        Task { @Sendable in
            await MainActor.run {
                SelectionActionRegistry.shared.unregister(actionId: id)
            }
        }
    }

    // MARK: - 命令注册

    func registerCommand(_ command: PluginCommand) {
        let pid = pluginId
        let cmd = command

        Task { @Sendable in
            await MainActor.run {
                // 创建内部 Command，handler 发送通知给插件
                let internalCommand = Command(
                    id: cmd.id,
                    title: cmd.title,
                    icon: cmd.icon
                ) { context in
                    // 通知插件命令被调用
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ETerm.CommandInvoked"),
                        object: nil,
                        userInfo: [
                            "pluginId": pid,
                            "commandId": cmd.id,
                            "terminalId": context.coordinator?.getActiveTerminalId() as Any
                        ]
                    )
                }
                CommandRegistry.shared.register(internalCommand)
                print("[MainProcessHostBridge] Registered command: \(cmd.id)")
            }
        }
    }

    func unregisterCommand(commandId: String) {
        let cmdId = commandId
        Task { @Sendable in
            await MainActor.run {
                CommandRegistry.shared.unregister(cmdId)
                print("[MainProcessHostBridge] Unregistered command: \(cmdId)")
            }
        }
    }

    // MARK: - 快捷键绑定

    func bindKeyboard(_ shortcut: KeyboardShortcut, to commandId: String) {
        let sc = shortcut
        let cmdId = commandId

        Task { @Sendable in
            await MainActor.run {
                // 将 SDK KeyboardShortcut 转换为内部 KeyStroke
                let keyStroke = Self.toKeyStroke(sc)
                KeyboardServiceImpl.shared.bind(keyStroke, to: cmdId, when: nil)
                print("[MainProcessHostBridge] Bound shortcut \(keyStroke.displayString) to \(cmdId)")
            }
        }
    }

    func unbindKeyboard(_ shortcut: KeyboardShortcut) {
        let sc = shortcut

        Task { @Sendable in
            await MainActor.run {
                let keyStroke = Self.toKeyStroke(sc)
                KeyboardServiceImpl.shared.unbind(keyStroke)
                print("[MainProcessHostBridge] Unbound shortcut \(keyStroke.displayString)")
            }
        }
    }

    /// 将 SDK KeyboardShortcut 转换为内部 KeyStroke
    private static func toKeyStroke(_ shortcut: KeyboardShortcut) -> KeyStroke {
        var modifiers: KeyModifiers = []
        if shortcut.modifiers.contains(.command) {
            modifiers.insert(.command)
        }
        if shortcut.modifiers.contains(.option) {
            modifiers.insert(.option)
        }
        if shortcut.modifiers.contains(.control) {
            modifiers.insert(.control)
        }
        if shortcut.modifiers.contains(.shift) {
            modifiers.insert(.shift)
        }

        return KeyStroke(
            keyCode: 0,
            character: shortcut.key.lowercased(),
            actualCharacter: nil,
            modifiers: modifiers
        )
    }

    // MARK: - Composer 控制

    func showComposer() {
        Task { @Sendable in
            await MainActor.run {
                if let keyWindow = WindowManager.shared.keyWindow,
                   let coordinator = WindowManager.shared.getCoordinator(for: keyWindow.windowNumber) {
                    coordinator.sendUIEvent(.showComposer(position: .zero))
                }
            }
        }
    }

    func hideComposer() {
        Task { @Sendable in
            await MainActor.run {
                if let keyWindow = WindowManager.shared.keyWindow,
                   let coordinator = WindowManager.shared.getCoordinator(for: keyWindow.windowNumber) {
                    coordinator.sendUIEvent(.hideComposer)
                }
            }
        }
    }

    func toggleComposer() {
        Task { @Sendable in
            await MainActor.run {
                if let keyWindow = WindowManager.shared.keyWindow,
                   let coordinator = WindowManager.shared.getCoordinator(for: keyWindow.windowNumber) {
                    coordinator.sendUIEvent(.toggleComposer(position: .zero))
                }
            }
        }
    }

    // MARK: - 终端操作扩展

    func getActiveTerminalId() -> Int? {
        if Thread.isMainThread {
            return Self.doGetActiveTerminalId()
        } else {
            var result: Int?
            DispatchQueue.main.sync {
                result = Self.doGetActiveTerminalId()
            }
            return result
        }
    }

    private static func doGetActiveTerminalId() -> Int? {
        guard let keyWindow = WindowManager.shared.keyWindow,
              let coordinator = WindowManager.shared.getCoordinator(for: keyWindow.windowNumber) else {
            return nil
        }
        return coordinator.getActiveTerminalId()
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
