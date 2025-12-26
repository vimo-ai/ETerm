//
//  PluginIPCBridge.swift
//  ETerm
//
//  主进程 IPC 桥接层
//  负责与 Extension Host 的通信和消息路由

import Foundation
import AppKit
import ETermKit

/// 插件 IPC 桥接
///
/// 职责：
/// - 运行 IPC 服务端，接受 Extension Host 连接
/// - 路由消息到对应的处理器
/// - 转发核心事件到 Extension Host
/// - 处理 Plugin → Host 的请求
actor PluginIPCBridge {

    // MARK: - Properties

    private let socketPath: String
    private var server: IPCServer?
    private var connection: IPCConnection?
    private var isRunning = false

    /// 握手完成信号
    private var handshakeCompletion: CheckedContinuation<Void, Error>?
    private var handshakeReceived = false

    /// 已加载的插件 Manifest（用于权限检查）
    private var pluginManifests: [String: PluginManifest] = [:]

    /// 能力检查器
    private let capabilityChecker = CapabilityChecker()

    /// ViewModel 状态缓存（解决时序问题：view 出现时能获取到最新状态）
    private var viewModelCache: [String: [String: Any]] = [:]

    /// 获取缓存的 ViewModel 数据
    func getCachedViewModel(for pluginId: String) -> [String: Any]? {
        return viewModelCache[pluginId]
    }

    // MARK: - Init

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - Public API

    /// 启动 IPC 服务端
    func start() async throws {
        guard !isRunning else { return }

        let config = IPCConnectionConfig(socketPath: socketPath)
        server = IPCServer(config: config)

        try await server?.start()
        isRunning = true

        // 启动接受连接循环
        Task {
            await acceptConnectionLoop()
        }

        print("[PluginIPCBridge] IPC server started on \(socketPath)")
    }

    /// 停止 IPC 服务端
    func stop() async {
        isRunning = false

        await connection?.disconnect()
        connection = nil

        await server?.stop()
        server = nil

        print("[PluginIPCBridge] IPC server stopped")
    }

    /// 等待握手完成
    func waitForHandshake(timeout: TimeInterval) async throws {
        if handshakeReceived { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.handshakeCompletion = continuation

            // 设置超时
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !self.handshakeReceived {
                    self.handshakeCompletion?.resume(throwing: IPCConnectionError.timeout)
                    self.handshakeCompletion = nil
                }
            }
        }
    }

    /// 注册插件 Manifest（用于权限检查）
    func registerManifest(_ manifest: PluginManifest) {
        pluginManifests[manifest.id] = manifest
        capabilityChecker.registerPlugin(manifest)
    }

    /// 发送事件到 Extension Host
    func sendEvent(name: String, payload: [String: Any], targetPluginId: String? = nil) async {
        guard let conn = connection else { return }

        let message = IPCMessage.event(
            name: name,
            payload: payload,
            targetPluginId: targetPluginId
        )

        do {
            try await conn.send(message)
        } catch {
            print("[PluginIPCBridge] Failed to send event: \(error)")
        }
    }

    /// 激活插件
    func activatePlugin(pluginId: String, bundlePath: String, manifest: PluginManifest) async throws {
        guard let conn = connection else {
            throw IPCConnectionError.notConnected
        }

        let message = IPCMessage(
            type: .activate,
            pluginId: pluginId,
            payload: [
                "bundlePath": bundlePath,  // Extension Host 需要知道从哪里加载 Bundle
                "hostVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
            ]
        )

        let response = try await conn.request(message)

        if response.type == .error {
            let errorMessage = response.rawPayload["errorMessage"] as? String ?? "Unknown error"
            throw PluginError.activationFailed(reason: errorMessage)
        }
    }

    /// 停用插件
    func deactivatePlugin(pluginId: String) async throws {
        guard let conn = connection else { return }

        let message = IPCMessage(
            type: .deactivate,
            pluginId: pluginId
        )

        _ = try await conn.request(message)
    }

    /// 发送命令给插件
    func sendCommand(pluginId: String, commandId: String) async throws {
        guard let conn = connection else {
            throw IPCConnectionError.notConnected
        }

        let message = IPCMessage(
            type: .commandInvoke,
            pluginId: pluginId,
            payload: ["commandId": commandId]
        )

        _ = try await conn.request(message)
    }

    /// 发送请求给插件（需要响应）
    func sendRequest(pluginId: String, requestId: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let conn = connection else {
            throw IPCConnectionError.notConnected
        }

        let message = IPCMessage(
            type: .pluginRequest,
            pluginId: pluginId,
            payload: [
                "requestId": requestId,
                "params": params
            ]
        )

        let response = try await conn.request(message)

        if response.type == .error {
            let errorMessage = response.rawPayload["errorMessage"] as? String ?? "Unknown error"
            throw PluginError.activationFailed(reason: errorMessage)
        }

        return response.rawPayload
    }

    // MARK: - Private

    /// 接受连接循环
    private func acceptConnectionLoop() async {
        while isRunning {
            do {
                guard let srv = server else { break }

                let conn = try await srv.acceptConnection()
                self.connection = conn

                print("[PluginIPCBridge] Extension Host connected")

                // 设置消息处理器
                await conn.setMessageHandler { [weak self] message in
                    await self?.handleMessage(message)
                }

                // 启动接收循环（必须在设置 handler 之后）
                await conn.startReceiving()

            } catch {
                if isRunning {
                    print("[PluginIPCBridge] Accept failed: \(error)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s 后重试
                }
            }
        }
    }

    /// 处理收到的消息
    private func handleMessage(_ message: IPCMessage) async {
        switch message.type {
        case .handshake:
            handleHandshake(message)

        case .updateViewModel:
            await handleUpdateViewModel(message)

        case .setTabDecoration:
            await handleSetTabDecoration(message)

        case .clearTabDecoration:
            await handleClearTabDecoration(message)

        case .setTabTitle:
            await handleSetTabTitle(message)

        case .clearTabTitle:
            await handleClearTabTitle(message)

        case .writeTerminal:
            await handleWriteTerminal(message)

        case .getTerminalInfo:
            await handleGetTerminalInfo(message)

        case .getAllTerminals:
            await handleGetAllTerminals(message)

        case .registerService:
            await handleRegisterService(message)

        case .callService:
            await handleCallService(message)

        case .emit:
            await handleEmit(message)

        // MARK: UI 控制消息

        case .showBottomDock:
            await handleShowBottomDock(message)

        case .hideBottomDock:
            await handleHideBottomDock(message)

        case .toggleBottomDock:
            await handleToggleBottomDock(message)

        case .showInfoPanel:
            await handleShowInfoPanel(message)

        case .hideInfoPanel:
            await handleHideInfoPanel(message)

        case .showBubble:
            await handleShowBubble(message)

        case .expandBubble:
            await handleExpandBubble(message)

        case .hideBubble:
            await handleHideBubble(message)

        default:
            print("[PluginIPCBridge] Unhandled message type: \(message.type)")
        }
    }

    // MARK: - Message Handlers

    private func handleHandshake(_ message: IPCMessage) {
        handshakeReceived = true
        handshakeCompletion?.resume()
        handshakeCompletion = nil

        print("[PluginIPCBridge] Handshake received from Extension Host")
    }

    private func handleUpdateViewModel(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        // 权限检查（updateViewModel 不需要特殊权限）

        let data = message.rawPayload
        print("[PluginIPCBridge] updateViewModel for \(pluginId): \(data)")

        // 缓存状态（解决时序问题）
        viewModelCache[pluginId] = data

        // 通知主线程更新 ViewModel
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("ETerm.UpdateViewModel"),
                object: nil,
                userInfo: [
                    "pluginId": pluginId,
                    "data": data
                ]
            )
        }

        await sendResponse(to: message)
    }

    private func handleSetTabDecoration(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        // 权限检查
        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.tabDecoration") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.tabDecoration")
            return
        }

        guard let terminalId = message.rawPayload["terminalId"] as? Int else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing terminalId")
            return
        }

        let decoration: TabDecoration?
        if let decorationData = message.rawPayload["decoration"] as? [String: Any] {
            decoration = Self.parseTabDecoration(from: decorationData, pluginId: pluginId)
        } else {
            decoration = nil
        }

        await MainActor.run {
            UIServiceImpl.shared.setTabDecoration(terminalId: terminalId, decoration: decoration)
        }

        await sendResponse(to: message)
    }

    private func handleClearTabDecoration(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.tabDecoration") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.tabDecoration")
            return
        }

        guard let terminalId = message.rawPayload["terminalId"] as? Int else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing terminalId")
            return
        }

        await MainActor.run {
            UIServiceImpl.shared.clearTabDecoration(terminalId: terminalId)
        }

        await sendResponse(to: message)
    }

    private func handleSetTabTitle(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.tabTitle") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.tabTitle")
            return
        }

        guard let terminalId = message.rawPayload["terminalId"] as? Int,
              let title = message.rawPayload["title"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing terminalId or title")
            return
        }

        await MainActor.run {
            UIServiceImpl.shared.setTabTitle(terminalId: terminalId, title: title)
        }

        await sendResponse(to: message)
    }

    private func handleClearTabTitle(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.tabTitle") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.tabTitle")
            return
        }

        guard let terminalId = message.rawPayload["terminalId"] as? Int else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing terminalId")
            return
        }

        await MainActor.run {
            UIServiceImpl.shared.clearTabTitle(terminalId: terminalId)
        }

        await sendResponse(to: message)
    }

    private func handleWriteTerminal(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "terminal.write") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: terminal.write")
            return
        }

        guard let terminalId = message.rawPayload["terminalId"] as? Int,
              let data = message.rawPayload["data"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing terminalId or data")
            return
        }

        let success = await MainActor.run {
            TerminalServiceImpl.shared.write(terminalId: terminalId, data: data)
        }

        await sendResponse(to: message, payload: ["success": success])
    }

    private func handleGetTerminalInfo(_ message: IPCMessage) async {
        guard let terminalId = message.rawPayload["terminalId"] as? Int else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing terminalId")
            return
        }

        // 在主线程查询终端信息
        let info: [String: Any]? = await MainActor.run {
            for window in WindowManager.shared.windows {
                guard let coordinator = WindowManager.shared.getCoordinator(for: window.windowNumber) else { continue }
                for panel in coordinator.terminalWindow.allPanels {
                    for tab in panel.tabs {
                        if tab.rustTerminalId == terminalId {
                            let cwd = coordinator.getCwd(terminalId: terminalId) ?? NSHomeDirectory()
                            let activeTerminalId = coordinator.getActiveTerminalId()
                            return [
                                "terminalId": terminalId,
                                "tabId": tab.tabId.uuidString,
                                "panelId": panel.panelId.uuidString,
                                "cwd": cwd,
                                "columns": 80,
                                "rows": 24,
                                "isActive": activeTerminalId == terminalId
                            ]
                        }
                    }
                }
            }
            return nil
        }

        if let info = info {
            await sendResponse(to: message, payload: info)
        } else {
            await sendError(to: message, code: "NOT_FOUND", message: "Terminal not found: \(terminalId)")
        }
    }

    private func handleGetAllTerminals(_ message: IPCMessage) async {
        // 在主线程查询所有终端信息
        let terminals: [[String: Any]] = await MainActor.run {
            var result: [[String: Any]] = []
            for window in WindowManager.shared.windows {
                guard let coordinator = WindowManager.shared.getCoordinator(for: window.windowNumber) else { continue }
                let activeTerminalId = coordinator.getActiveTerminalId()

                for panel in coordinator.terminalWindow.allPanels {
                    for tab in panel.tabs {
                        guard let terminalId = tab.rustTerminalId else { continue }
                        let cwd = coordinator.getCwd(terminalId: terminalId) ?? NSHomeDirectory()
                        result.append([
                            "terminalId": terminalId,
                            "tabId": tab.tabId.uuidString,
                            "panelId": panel.panelId.uuidString,
                            "cwd": cwd,
                            "columns": 80,
                            "rows": 24,
                            "isActive": activeTerminalId == terminalId
                        ])
                    }
                }
            }
            return result
        }

        await sendResponse(to: message, payload: ["terminals": terminals])
    }

    private func handleRegisterService(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "service.register") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: service.register")
            return
        }

        // TODO: 实现跨进程服务注册
        // 当前 ServiceRegistry 基于静态实例，不支持函数式服务
        // 需要设计新的跨进程服务代理机制
        await sendError(to: message, code: "NOT_IMPLEMENTED", message: "Cross-process service registration not yet implemented")
    }

    private func handleCallService(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "service.call") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: service.call")
            return
        }

        guard let targetPluginId = message.rawPayload["targetPluginId"] as? String,
              let serviceName = message.rawPayload["name"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing targetPluginId or name")
            return
        }

        let params = message.rawPayload["params"] as? [String: Any] ?? [:]

        // 核心服务特殊处理（eterm.* 命名空间）
        if targetPluginId == "eterm" {
            let result = await handleCoreService(name: serviceName, params: params)
            await sendResponse(to: message, payload: result)
            return
        }

        // 其他插件服务
        let hasService = await MainActor.run {
            ServiceRegistry.shared.hasService(pluginId: targetPluginId, name: serviceName)
        }

        if !hasService {
            await sendError(to: message, code: "SERVICE_NOT_FOUND", message: "Service \(targetPluginId).\(serviceName) not found")
            return
        }

        // TODO: 实现其他插件的跨进程服务调用
        await sendError(to: message, code: "NOT_IMPLEMENTED", message: "Cross-process service call for plugins not yet implemented")
    }

    // MARK: - Core Services

    /// 处理核心服务调用（eterm.* 命名空间）
    private func handleCoreService(name: String, params: [String: Any]) async -> [String: Any] {
        switch name {
        case "ai.translate":
            return await handleAITranslate(params: params)

        case "ai.analyzeSentence":
            return await handleAIAnalyzeSentence(params: params)

        case "dictionary.lookup":
            return await handleDictionaryLookup(params: params)

        default:
            return ["success": false, "error": "Unknown core service: \(name)"]
        }
    }

    /// AI 翻译服务
    private func handleAITranslate(params: [String: Any]) async -> [String: Any] {
        guard let text = params["text"] as? String else {
            return ["success": false, "error": "Missing parameter: text"]
        }

        let model = params["model"] as? String ?? "qwen-mt-flash"

        do {
            let result = try await AIService.shared.translate(text, model: model)
            return ["success": true, "result": result]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    /// AI 句子分析服务（非流式，等待完成后返回）
    private func handleAIAnalyzeSentence(params: [String: Any]) async -> [String: Any] {
        guard let text = params["text"] as? String else {
            return ["success": false, "error": "Missing parameter: text"]
        }

        let model = params["model"] as? String ?? "qwen3-max"

        do {
            var finalTranslation = ""
            var finalGrammar = ""

            try await AIService.shared.analyzeSentence(text, model: model) { translation, grammar in
                finalTranslation = translation
                finalGrammar = grammar
            }

            return [
                "success": true,
                "translation": finalTranslation,
                "grammar": finalGrammar
            ]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    /// 词典查询服务
    private func handleDictionaryLookup(params: [String: Any]) async -> [String: Any] {
        guard let word = params["word"] as? String else {
            return ["success": false, "error": "Missing parameter: word"]
        }

        do {
            let result = try await DictionaryService.shared.lookup(word)

            // 转换为可序列化的字典
            let phonetics: [[String: Any]] = result.phonetics?.map { phonetic in
                var dict: [String: Any] = [:]
                if let text = phonetic.text { dict["text"] = text }
                if let audio = phonetic.audio { dict["audio"] = audio }
                return dict
            } ?? []

            let meanings: [[String: Any]] = result.meanings.map { meaning in
                let definitions: [[String: Any]] = meaning.definitions.map { def in
                    var dict: [String: Any] = ["definition": def.definition]
                    if let example = def.example { dict["example"] = example }
                    if let synonyms = def.synonyms { dict["synonyms"] = synonyms }
                    return dict
                }
                return [
                    "partOfSpeech": meaning.partOfSpeech,
                    "definitions": definitions
                ]
            }

            var resultDict: [String: Any] = [
                "success": true,
                "word": result.word,
                "meanings": meanings,
                "phonetics": phonetics
            ]
            if let phonetic = result.phonetic {
                resultDict["phonetic"] = phonetic
            }

            return resultDict
        } catch let error as DictionaryError {
            return [
                "success": false,
                "error": error.localizedDescription,
                "errorType": String(describing: error)
            ]
        } catch {
            return ["success": false, "error": error.localizedDescription]
        }
    }

    private func handleEmit(_ message: IPCMessage) async {
        guard let eventName = message.rawPayload["eventName"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing eventName")
            return
        }

        // TODO: 实现动态事件发射
        // 当前 EventBus 使用泛型和 DomainEvent 协议
        // 需要设计动态事件类型或专门的插件事件通道
        print("[PluginIPCBridge] Plugin event emitted: \(eventName)")

        await sendResponse(to: message)
    }

    // MARK: - UI 控制处理

    private func handleShowBottomDock(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.bottomDock") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.bottomDock")
            return
        }

        guard let dockId = message.rawPayload["id"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing id")
            return
        }

        // TODO: 实现 BottomDockRegistry
        print("[PluginIPCBridge] showBottomDock: \(dockId) (not implemented)")
        await sendResponse(to: message)
    }

    private func handleHideBottomDock(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.bottomDock") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.bottomDock")
            return
        }

        guard let dockId = message.rawPayload["id"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing id")
            return
        }

        // TODO: 实现 BottomDockRegistry
        print("[PluginIPCBridge] hideBottomDock: \(dockId) (not implemented)")
        await sendResponse(to: message)
    }

    private func handleToggleBottomDock(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.bottomDock") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.bottomDock")
            return
        }

        guard let dockId = message.rawPayload["id"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing id")
            return
        }

        // TODO: 实现 BottomDockRegistry
        print("[PluginIPCBridge] toggleBottomDock: \(dockId) (not implemented)")
        await sendResponse(to: message)
    }

    private func handleShowInfoPanel(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.infoPanel") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.infoPanel")
            return
        }

        guard let panelId = message.rawPayload["id"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing id")
            return
        }

        await MainActor.run {
            InfoWindowRegistry.shared.showContent(id: panelId)
        }
        await sendResponse(to: message)
    }

    private func handleHideInfoPanel(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.infoPanel") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.infoPanel")
            return
        }

        guard let panelId = message.rawPayload["id"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing id")
            return
        }

        await MainActor.run {
            InfoWindowRegistry.shared.hideContent(id: panelId)
        }
        await sendResponse(to: message)
    }

    private func handleShowBubble(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.bubble") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.bubble")
            return
        }

        guard let text = message.rawPayload["text"] as? String else {
            await sendError(to: message, code: "INVALID_PARAMS", message: "Missing text")
            return
        }

        // 位置参数可选
        let position = message.rawPayload["position"] as? [String: Double]

        await MainActor.run {
            // 使用 TranslationController 显示 bubble（保持与内置逻辑一致）
            // 由于没有 view 上下文，这里记录日志即可
            // 实际 bubble 显示由 SDKEventBridge 处理
            print("[PluginIPCBridge] showBubble: text=\(text), position=\(String(describing: position))")
        }
        await sendResponse(to: message)
    }

    private func handleExpandBubble(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.bubble") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.bubble")
            return
        }

        await MainActor.run {
            TranslationController.shared.state.expand()
        }
        await sendResponse(to: message)
    }

    private func handleHideBubble(_ message: IPCMessage) async {
        guard let pluginId = message.pluginId else { return }

        guard capabilityChecker.hasCapability(pluginId: pluginId, capability: "ui.bubble") else {
            await sendError(to: message, code: "PERMISSION_DENIED", message: "Missing capability: ui.bubble")
            return
        }

        await MainActor.run {
            TranslationController.shared.hide()
        }
        await sendResponse(to: message)
    }

    // MARK: - Response Helpers

    private func sendResponse(to request: IPCMessage, payload: [String: Any] = [:]) async {
        guard let conn = connection else { return }

        let response = IPCMessage.response(to: request, payload: payload)
        try? await conn.send(response)
    }

    private func sendError(to request: IPCMessage, code: String, message: String) async {
        guard let conn = connection else { return }

        let response = IPCMessage.error(to: request, code: code, message: message)
        try? await conn.send(response)
    }
}

// MARK: - TabDecoration Parsing

extension PluginIPCBridge {
    /// 从 IPC payload 解析 TabDecoration
    static func parseTabDecoration(from dict: [String: Any], pluginId: String = "unknown") -> TabDecoration? {
        // 解析颜色（支持 hex 格式）
        guard let colorHex = dict["color"] as? String else {
            return nil
        }

        let color = NSColor(hex: colorHex) ?? .gray

        // 解析优先级
        let priorityValue = dict["priority"] as? Int ?? 50
        let priority = DecorationPriority.plugin(id: pluginId, priority: priorityValue)

        // 解析样式
        let styleString = dict["style"] as? String ?? "solid"
        let style: TabDecoration.Style
        switch styleString {
        case "pulse": style = .pulse
        case "breathing": style = .breathing
        default: style = .solid
        }

        // 解析是否持久化
        let persistent = dict["persistent"] as? Bool ?? false

        return TabDecoration(
            priority: priority,
            color: color,
            style: style,
            persistent: persistent
        )
    }
}

// MARK: - NSColor Hex Extension

private extension NSColor {
    convenience init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
