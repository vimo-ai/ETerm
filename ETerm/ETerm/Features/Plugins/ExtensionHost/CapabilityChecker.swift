//
//  CapabilityChecker.swift
//  ETerm
//
//  插件能力检查器
//  运行时强制验证插件是否声明了对应的 capability

import Foundation
import ETermKit

/// 插件能力定义
///
/// 对应 Manifest 中的 capabilities 字段
enum PluginCapability: String, CaseIterable {
    // 终端能力
    case terminalWrite = "terminal.write"
    case terminalRead = "terminal.read"

    // UI 能力
    case uiSidebar = "ui.sidebar"
    case uiTabDecoration = "ui.tabDecoration"
    case uiTabTitle = "ui.tabTitle"
    case uiTabSlot = "ui.tabSlot"
    case uiPageSlot = "ui.pageSlot"
    case uiPluginPage = "ui.pluginPage"

    // 服务能力
    case serviceRegister = "service.register"
    case serviceCall = "service.call"
}

/// 能力检查器
///
/// 根据设计文档要求：
/// - 所有 Plugin → Host 的请求在执行前必须验证
/// - 插件是否声明了对应的 capability
/// - 未声明能力的请求返回 error(code: "PERMISSION_DENIED")
final class CapabilityChecker {

    // MARK: - Properties

    /// 插件 ID -> 能力集合
    private var pluginCapabilities: [String: Set<String>] = [:]

    /// 能力与 API 的映射关系
    private static let capabilityMapping: [String: [String]] = [
        "terminal.write": ["writeTerminal"],
        "terminal.read": ["terminalDidOutput"],
        "ui.sidebar": ["registerSidebarTab"],
        "ui.tabDecoration": ["setTabDecoration", "clearTabDecoration"],
        "ui.tabTitle": ["setTabTitle", "clearTabTitle"],
        "ui.tabSlot": ["registerTabSlot"],
        "ui.pageSlot": ["registerPageSlot"],
        "service.register": ["registerService"],
        "service.call": ["callService"]
    ]

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// 注册插件及其能力
    func registerPlugin(_ manifest: PluginManifest) {
        pluginCapabilities[manifest.id] = Set(manifest.capabilities)
        logDebug("[CapabilityChecker] Registered plugin '\(manifest.id)' with capabilities: \(manifest.capabilities)")
    }

    /// 注销插件
    func unregisterPlugin(_ pluginId: String) {
        pluginCapabilities.removeValue(forKey: pluginId)
    }

    /// 检查插件是否有指定能力
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - capability: 能力标识（如 "terminal.write"）
    /// - Returns: 是否具有该能力
    func hasCapability(pluginId: String, capability: String) -> Bool {
        guard let capabilities = pluginCapabilities[pluginId] else {
            logWarn("[CapabilityChecker] Unknown plugin: \(pluginId)")
            return false
        }

        let hasIt = capabilities.contains(capability)

        if !hasIt {
            logWarn("[CapabilityChecker] Plugin '\(pluginId)' missing capability: \(capability)")
        }

        return hasIt
    }

    /// 检查插件是否可以调用指定 API
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - api: API 名称（如 "writeTerminal"）
    /// - Returns: 是否允许调用
    func canCallAPI(pluginId: String, api: String) -> Bool {
        // 查找需要的能力
        for (capability, apis) in Self.capabilityMapping {
            if apis.contains(api) {
                return hasCapability(pluginId: pluginId, capability: capability)
            }
        }

        // 未在映射中的 API 默认允许
        return true
    }

    /// 获取插件的所有能力
    func getCapabilities(pluginId: String) -> Set<String> {
        return pluginCapabilities[pluginId] ?? []
    }

    /// 获取调用指定 API 所需的能力
    func requiredCapability(for api: String) -> String? {
        for (capability, apis) in Self.capabilityMapping {
            if apis.contains(api) {
                return capability
            }
        }
        return nil
    }

    /// 验证能力并返回错误信息（如果验证失败）
    ///
    /// - Parameters:
    ///   - pluginId: 插件 ID
    ///   - capability: 能力标识
    /// - Returns: 错误信息，如果验证通过则返回 nil
    func validate(pluginId: String, capability: String) -> CapabilityError? {
        guard pluginCapabilities[pluginId] != nil else {
            return .unknownPlugin(pluginId)
        }

        if !hasCapability(pluginId: pluginId, capability: capability) {
            return .missingCapability(pluginId: pluginId, capability: capability)
        }

        return nil
    }
}

// MARK: - Capability Error

/// 能力验证错误
enum CapabilityError: Error, CustomStringConvertible {
    case unknownPlugin(String)
    case missingCapability(pluginId: String, capability: String)

    var description: String {
        switch self {
        case .unknownPlugin(let id):
            return "Unknown plugin: \(id)"
        case .missingCapability(let pluginId, let capability):
            return "Plugin '\(pluginId)' missing capability: \(capability)"
        }
    }

    var errorCode: String {
        switch self {
        case .unknownPlugin:
            return "UNKNOWN_PLUGIN"
        case .missingCapability:
            return "PERMISSION_DENIED"
        }
    }
}
