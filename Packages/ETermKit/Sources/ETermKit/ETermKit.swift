// ETermKit.swift
// ETermKit - ETerm Plugin SDK
//
// 统一导出所有公共 API

// MARK: - Protocols

// 插件逻辑协议（Extension Host 进程）
public typealias _PluginLogic = PluginLogic

// 插件 ViewModel 协议（主进程）
public typealias _PluginViewModel = PluginViewModel

// 主应用桥接协议
public typealias _HostBridge = HostBridge

// MARK: - Types

// 主应用信息
public typealias _HostInfo = HostInfo

// 插件清单
public typealias _PluginManifest = PluginManifest

// Tab 装饰
public typealias _TabDecoration = TabDecoration

// 终端信息
public typealias _TerminalInfo = TerminalInfo

// 插件错误
public typealias _PluginError = PluginError

// MARK: - Events

// 核心事件名称
public typealias _CoreEventNames = CoreEventNames

// MARK: - IPC

// IPC 消息
public typealias _IPCMessage = IPCMessage

// IPC 连接
public typealias _IPCConnection = IPCConnection

// IPC 配置
public typealias _IPCConnectionConfig = IPCConnectionConfig

// IPC 协议版本
public let ETermKitIPCProtocolVersion = IPCProtocolVersion

// MARK: - SDK Version

/// ETermKit SDK 版本
public let ETermKitVersion = "1.0.0"
