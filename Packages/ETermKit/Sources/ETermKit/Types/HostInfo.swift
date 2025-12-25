// HostInfo.swift
// ETermKit
//
// 主应用信息

import Foundation

/// 主应用信息
///
/// 提供 ETerm 主应用的版本和环境信息，插件可据此进行兼容性判断。
public struct HostInfo: Sendable, Codable, Equatable {

    /// ETerm 主应用版本
    ///
    /// 语义化版本格式，如 "2.0.0"
    public let version: String

    /// ETerm SDK 版本
    ///
    /// 当前 ETermKit 的版本，用于 API 兼容性检查
    public let sdkVersion: String

    /// IPC 协议版本
    ///
    /// 用于确保主进程和 Extension Host 的通信兼容
    public let protocolVersion: String

    /// 是否为调试构建
    public let isDebugBuild: Bool

    /// 插件安装目录
    public let pluginsDirectory: String

    /// 初始化主应用信息
    public init(
        version: String,
        sdkVersion: String,
        protocolVersion: String,
        isDebugBuild: Bool,
        pluginsDirectory: String
    ) {
        self.version = version
        self.sdkVersion = sdkVersion
        self.protocolVersion = protocolVersion
        self.isDebugBuild = isDebugBuild
        self.pluginsDirectory = pluginsDirectory
    }
}
