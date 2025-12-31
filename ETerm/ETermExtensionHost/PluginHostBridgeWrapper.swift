// PluginHostBridgeWrapper.swift
// ETermExtensionHost
//
// 为每个插件提供独立的 HostBridge，自动携带调用方 pluginId

import Foundation
import AppKit
import ETermKit

/// 插件专属的 HostBridge 包装器
///
/// 每个插件获得一个独立的 wrapper 实例，用于：
/// - 自动在 IPC 消息中携带调用方 pluginId
/// - 实现权限检查和服务路由
final class PluginHostBridgeWrapper: HostBridge, @unchecked Sendable {

    /// 调用方插件 ID
    let pluginId: String

    /// 底层的共享桥接
    private let bridge: ExtensionHostBridge

    init(pluginId: String, bridge: ExtensionHostBridge) {
        self.pluginId = pluginId
        self.bridge = bridge
    }

    // MARK: - HostBridge 协议转发

    var hostInfo: HostInfo {
        bridge.hostInfo
    }

    func updateViewModel(_ viewModelId: String, data: [String: Any]) {
        bridge.updateViewModel(viewModelId, data: data)
    }

    func setTabDecoration(terminalId: Int, decoration: TabDecoration?) {
        bridge.setTabDecoration(terminalId: terminalId, decoration: decoration)
    }

    func clearTabDecoration(terminalId: Int) {
        bridge.clearTabDecoration(terminalId: terminalId)
    }

    func setTabTitle(terminalId: Int, title: String) {
        bridge.setTabTitle(terminalId: terminalId, title: title)
    }

    func clearTabTitle(terminalId: Int) {
        bridge.clearTabTitle(terminalId: terminalId)
    }

    func writeToTerminal(terminalId: Int, data: String) {
        bridge.writeToTerminal(terminalId: terminalId, data: data)
    }

    func createTerminalTab(cwd: String?) -> Int? {
        bridge.createTerminalTab(cwd: cwd)
    }

    func getTerminalInfo(terminalId: Int) -> TerminalInfo? {
        bridge.getTerminalInfo(terminalId: terminalId)
    }

    func getAllTerminals() -> [TerminalInfo] {
        bridge.getAllTerminals()
    }

    // MARK: - 服务注册与调用（需要携带 callerPluginId）

    func registerService(
        name: String,
        handler: @escaping @Sendable ([String: Any]) -> [String: Any]?
    ) {
        // 使用带 callerPluginId 的方法
        bridge.registerServiceWithCaller(
            callerPluginId: pluginId,
            name: name,
            handler: handler
        )
    }

    func callService(
        pluginId targetPluginId: String,
        name: String,
        params: [String: Any]
    ) -> [String: Any]? {
        // 使用带 callerPluginId 的方法
        bridge.callServiceWithCaller(
            callerPluginId: pluginId,
            targetPluginId: targetPluginId,
            name: name,
            params: params
        )
    }

    func emit(eventName: String, payload: [String: Any]) {
        bridge.emit(eventName: eventName, payload: payload)
    }

    // MARK: - 底部停靠视图

    func showBottomDock(_ id: String) {
        bridge.showBottomDock(id)
    }

    func hideBottomDock(_ id: String) {
        bridge.hideBottomDock(id)
    }

    func toggleBottomDock(_ id: String) {
        bridge.toggleBottomDock(id)
    }

    // MARK: - 底部 Overlay

    func showBottomOverlay(_ id: String) {
        bridge.showBottomOverlay(id)
    }

    func hideBottomOverlay(_ id: String) {
        bridge.hideBottomOverlay(id)
    }

    func toggleBottomOverlay(_ id: String) {
        bridge.toggleBottomOverlay(id)
    }

    // MARK: - 信息面板

    func showInfoPanel(_ id: String) {
        bridge.showInfoPanel(id)
    }

    func hideInfoPanel(_ id: String) {
        bridge.hideInfoPanel(id)
    }

    // MARK: - 选中气泡

    func showBubble(text: String, position: [String: Double]) {
        bridge.showBubble(text: text, position: position)
    }

    func expandBubble() {
        bridge.expandBubble()
    }

    func hideBubble() {
        bridge.hideBubble()
    }

    // MARK: - 窗口与终端查询

    func getActiveTabCwd() -> String? {
        bridge.getActiveTabCwd()
    }

    func getKeyWindowFrame() -> CGRect? {
        bridge.getKeyWindowFrame()
    }

    // MARK: - 嵌入终端

    func createEmbeddedTerminal(cwd: String) -> Int {
        bridge.createEmbeddedTerminal(cwd: cwd)
    }

    func closeEmbeddedTerminal(terminalId: Int) {
        bridge.closeEmbeddedTerminal(terminalId: terminalId)
    }

    // MARK: - AI 服务

    func aiChat(
        model: String,
        system: String?,
        user: String,
        extraBody: [String: Any]?
    ) async throws -> String {
        try await bridge.aiChat(model: model, system: system, user: user, extraBody: extraBody)
    }

    func aiStreamChat(
        model: String,
        system: String?,
        user: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws {
        try await bridge.aiStreamChat(model: model, system: system, user: user, onChunk: onChunk)
    }

    // MARK: - 选中操作

    func registerSelectionAction(_ action: SelectionAction) {
        bridge.registerSelectionAction(action)
    }

    func unregisterSelectionAction(actionId: String) {
        bridge.unregisterSelectionAction(actionId: actionId)
    }

    // MARK: - 命令注册

    func registerCommand(_ command: PluginCommand) {
        bridge.registerCommand(command)
    }

    func unregisterCommand(commandId: String) {
        bridge.unregisterCommand(commandId: commandId)
    }

    // MARK: - 快捷键

    func bindKeyboard(_ shortcut: KeyboardShortcut, to commandId: String) {
        bridge.bindKeyboard(shortcut, to: commandId)
    }

    func unbindKeyboard(_ shortcut: KeyboardShortcut) {
        bridge.unbindKeyboard(shortcut)
    }

    // MARK: - Composer

    func showComposer() {
        bridge.showComposer()
    }

    func hideComposer() {
        bridge.hideComposer()
    }

    func toggleComposer() {
        bridge.toggleComposer()
    }

    // MARK: - 终端操作扩展

    func getActiveTerminalId() -> Int? {
        bridge.getActiveTerminalId()
    }

    // MARK: - Socket

    var socketDirectory: String {
        bridge.socketDirectory
    }

    func socketPath(for namespace: String) -> String {
        bridge.socketPath(for: namespace)
    }

    var socketService: SocketServiceProtocol? {
        bridge.socketService
    }
}
