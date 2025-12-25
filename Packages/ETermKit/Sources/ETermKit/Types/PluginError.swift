// PluginError.swift
// ETermKit
//
// 插件错误类型

import Foundation

/// 插件错误
///
/// 定义插件加载、运行过程中可能出现的所有错误类型。
/// 每个错误都有对应的 errorCode 用于 IPC 传递。
public enum PluginError: Error, Sendable, Equatable {

    // MARK: - 加载错误

    /// Manifest 文件不存在
    case manifestNotFound(path: String)

    /// Manifest 格式无效
    case invalidManifest(reason: String)

    /// 主应用版本不兼容
    case incompatibleVersion(required: String, current: String)

    /// SDK 版本不兼容
    case incompatibleSDK(required: String, current: String)

    /// 依赖缺失
    case missingDependency(pluginId: String)

    /// 依赖版本不满足
    case dependencyVersionMismatch(pluginId: String, required: String, available: String)

    /// 循环依赖
    case circularDependency(pluginIds: [String])

    /// Bundle 加载失败
    case bundleLoadFailed(reason: String)

    /// 入口类不存在
    case principalClassNotFound(className: String)

    /// Manifest 解析失败
    case manifestParseError(reason: String)

    /// 插件激活失败
    case activationFailed(reason: String)

    // MARK: - 运行时错误

    /// 权限被拒绝
    case permissionDenied(capability: String)

    /// IPC 通信超时
    case ipcTimeout(messageId: String)

    /// IPC 通信错误
    case ipcError(code: String, message: String)

    /// 服务未找到
    case serviceNotFound(pluginId: String, serviceName: String)

    /// 终端不存在
    case terminalNotFound(terminalId: Int)

    /// 插件未激活
    case pluginNotActive(pluginId: String)

    // MARK: - Error Code

    /// 错误代码
    ///
    /// 用于 IPC 传递，格式为 "CATEGORY_NAME"
    public var errorCode: String {
        switch self {
        case .manifestNotFound:
            return "MANIFEST_NOT_FOUND"
        case .invalidManifest:
            return "INVALID_MANIFEST"
        case .incompatibleVersion:
            return "INCOMPATIBLE_VERSION"
        case .incompatibleSDK:
            return "INCOMPATIBLE_SDK"
        case .missingDependency:
            return "MISSING_DEPENDENCY"
        case .dependencyVersionMismatch:
            return "DEPENDENCY_VERSION_MISMATCH"
        case .circularDependency:
            return "CIRCULAR_DEPENDENCY"
        case .bundleLoadFailed:
            return "BUNDLE_LOAD_FAILED"
        case .principalClassNotFound:
            return "PRINCIPAL_CLASS_NOT_FOUND"
        case .manifestParseError:
            return "MANIFEST_PARSE_ERROR"
        case .activationFailed:
            return "ACTIVATION_FAILED"
        case .permissionDenied:
            return "PERMISSION_DENIED"
        case .ipcTimeout:
            return "IPC_TIMEOUT"
        case .ipcError:
            return "IPC_ERROR"
        case .serviceNotFound:
            return "SERVICE_NOT_FOUND"
        case .terminalNotFound:
            return "TERMINAL_NOT_FOUND"
        case .pluginNotActive:
            return "PLUGIN_NOT_ACTIVE"
        }
    }

    /// 错误消息
    public var errorMessage: String {
        switch self {
        case .manifestNotFound(let path):
            return "Manifest not found at: \(path)"
        case .invalidManifest(let reason):
            return "Invalid manifest: \(reason)"
        case .incompatibleVersion(let required, let current):
            return "Requires ETerm \(required), current: \(current)"
        case .incompatibleSDK(let required, let current):
            return "Requires SDK \(required), current: \(current)"
        case .missingDependency(let pluginId):
            return "Missing dependency: \(pluginId)"
        case .dependencyVersionMismatch(let pluginId, let required, let available):
            return "Dependency \(pluginId) requires \(required), available: \(available)"
        case .circularDependency(let pluginIds):
            return "Circular dependency detected: \(pluginIds.joined(separator: " -> "))"
        case .bundleLoadFailed(let reason):
            return "Failed to load bundle: \(reason)"
        case .principalClassNotFound(let className):
            return "Principal class not found: \(className)"
        case .manifestParseError(let reason):
            return "Failed to parse manifest: \(reason)"
        case .activationFailed(let reason):
            return "Failed to activate plugin: \(reason)"
        case .permissionDenied(let capability):
            return "Permission denied for capability: \(capability)"
        case .ipcTimeout(let messageId):
            return "IPC request timed out: \(messageId)"
        case .ipcError(let code, let message):
            return "IPC error [\(code)]: \(message)"
        case .serviceNotFound(let pluginId, let serviceName):
            return "Service not found: \(pluginId)/\(serviceName)"
        case .terminalNotFound(let terminalId):
            return "Terminal not found: \(terminalId)"
        case .pluginNotActive(let pluginId):
            return "Plugin not active: \(pluginId)"
        }
    }
}

// MARK: - LocalizedError

extension PluginError: LocalizedError {
    public var errorDescription: String? {
        return errorMessage
    }
}
