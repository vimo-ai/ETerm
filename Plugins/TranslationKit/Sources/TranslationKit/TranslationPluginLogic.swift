//
//  TranslationPluginLogic.swift
//  TranslationKit
//
//  Translation Plugin Logic - Extension Host 进程入口

import Foundation
import ETermKit

/// 翻译插件逻辑层
///
/// 在 Extension Host 进程中运行，负责：
/// - 处理翻译相关命令
/// - 管理翻译配置
/// - 向 ViewModel 发送状态更新
@objc public final class TranslationPluginLogic: NSObject, PluginLogic {

    // MARK: - PluginLogic

    public static let id = "com.eterm.translation"

    private var host: HostBridge?
    private var configManager: TranslationConfigManager?

    public override init() {
        super.init()
    }

    public func activate(host: HostBridge) {
        self.host = host
        self.configManager = TranslationConfigManager()

        // 发送初始配置到 ViewModel
        sendConfigUpdate()

        // 注册配置服务供其他插件调用
        registerServices()
    }

    public func deactivate() {
        host = nil
        configManager = nil
    }

    public func handleEvent(_ eventName: String, payload: [String: Any]) {
        // 暂无需要处理的事件
    }

    public func handleCommand(_ commandId: String) {
        switch commandId {
        case "translation.show":
            host?.emit(eventName: "plugin.translation.show", payload: [:])

        case "translation.hide":
            host?.emit(eventName: "plugin.translation.hide", payload: [:])

        case "translation.toggle":
            host?.emit(eventName: "plugin.translation.toggle", payload: [:])

        case "translation.resetConfig":
            configManager?.resetToDefault()
            sendConfigUpdate()

        default:
            break
        }
    }

    // MARK: - Private

    private func sendConfigUpdate() {
        guard let config = configManager?.config else { return }

        let data: [String: Any] = [
            "dispatcherModel": config.dispatcherModel,
            "analysisModel": config.analysisModel,
            "translationModel": config.translationModel
        ]

        host?.updateViewModel(Self.id, data: data)
    }

    private func registerServices() {
        // 获取配置服务
        host?.registerService(name: "getConfig") { [weak self] _ in
            guard let config = self?.configManager?.config else { return nil }
            return [
                "dispatcherModel": config.dispatcherModel,
                "analysisModel": config.analysisModel,
                "translationModel": config.translationModel
            ]
        }

        // 更新配置服务
        host?.registerService(name: "updateConfig") { [weak self] params in
            guard let dispatcherModel = params["dispatcherModel"] as? String,
                  let analysisModel = params["analysisModel"] as? String,
                  let translationModel = params["translationModel"] as? String else {
                return ["success": false, "error": "Invalid parameters"]
            }

            self?.configManager?.updateConfig(
                dispatcherModel: dispatcherModel,
                analysisModel: analysisModel,
                translationModel: translationModel
            )
            self?.sendConfigUpdate()

            return ["success": true]
        }
    }
}
