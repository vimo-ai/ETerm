// ETermKit.swift
// ETermKit - ETerm Plugin SDK
//
// 统一导出所有公共 API

// MARK: - Protocols

// 插件协议（主进程模式，runMode: main）
public typealias _Plugin = Plugin

// 插件逻辑协议（隔离模式，runMode: isolated，Extension Host 进程）
public typealias _PluginLogic = PluginLogic

// 插件 ViewModel 协议（主进程）
public typealias _PluginViewModel = PluginViewModel

// 插件 View 提供者协议（隔离模式，主进程加载 Bundle 中的 View）
public typealias _PluginViewProvider = PluginViewProvider

// 主应用桥接协议
public typealias _HostBridge = HostBridge

// 插件运行模式
public typealias _PluginRunMode = PluginRunMode

// MARK: - Types

// 主应用信息
public typealias _HostInfo = HostInfo

// 插件清单
public typealias _PluginManifest = PluginManifest

// Tab 装饰
public typealias _TabDecoration = TabDecoration

// 装饰优先级
public typealias _DecorationPriority = DecorationPriority

// Tab Slot 上下文
public typealias _TabSlotContext = TabSlotContext

// Page Slot 上下文
public typealias _PageSlotContext = PageSlotContext

// 终端信息
public typealias _TerminalInfo = TerminalInfo

// 插件错误
public typealias _PluginError = PluginError

// 嵌入式终端占位视图
public typealias _TerminalPlaceholder = TerminalPlaceholder

// 选中操作
public typealias _SelectionAction = SelectionAction

// 插件命令
public typealias _PluginCommand = PluginCommand

// 快捷键配置
public typealias _KeyboardShortcut = KeyboardShortcut

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

// MARK: - Socket Service

// Socket 服务协议
public typealias _SocketServiceProtocol = SocketServiceProtocol

// Socket 客户端协议
public typealias _SocketClientProtocol = SocketClientProtocol

// Socket 客户端事件
public typealias _SocketClientEvent = SocketClientEvent

// Socket 客户端配置
public typealias _SocketClientConfig = SocketClientConfig

// MARK: - Logging

// 日志管理器
public typealias _LogManager = LogManager

// 日志级别
public typealias _LogLevel = LogLevel

// MARK: - SDK Version

/// ETermKit SDK 版本
public let ETermKitVersion = "0.0.1-beta.1"
