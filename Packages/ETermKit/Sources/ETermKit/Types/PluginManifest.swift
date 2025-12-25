// PluginManifest.swift
// ETermKit
//
// 插件清单配置

import Foundation

/// 插件清单
///
/// 对应 manifest.json 的结构，声明插件的元信息、依赖、能力和注册项。
public struct PluginManifest: Sendable, Codable, Equatable {

    // MARK: - 基本信息

    /// 插件唯一标识符
    ///
    /// 反向域名格式，如 "com.example.mcp-router"
    public let id: String

    /// 插件显示名称
    public let name: String

    /// 插件版本
    ///
    /// 语义化版本格式，如 "1.0.0"
    public let version: String

    /// 最低主应用版本要求
    public let minHostVersion: String

    /// 使用的 SDK 版本
    public let sdkVersion: String

    // MARK: - 依赖

    /// 插件依赖列表
    public let dependencies: [Dependency]

    // MARK: - 能力声明

    /// 需要的能力列表
    ///
    /// 在运行时强制检查，未声明的能力调用会返回权限错误
    public let capabilities: [String]

    // MARK: - 入口类

    /// 插件逻辑入口类名
    ///
    /// 实现 PluginLogic 协议的类名
    public let principalClass: String

    /// ViewModel 类名（可选）
    ///
    /// 实现 PluginViewModel 协议的类名
    public let viewModelClass: String?

    /// ViewProvider 类名（可选）
    ///
    /// 实现 PluginViewProvider 协议的类名，用于提供插件的 UI 视图
    public let viewProviderClass: String?

    // MARK: - UI 注册

    /// 侧边栏 Tab 注册
    public let sidebarTabs: [SidebarTab]

    /// 命令注册
    public let commands: [Command]

    /// 订阅的事件列表
    public let subscribes: [String]

    /// MenuBar 配置（可选）
    public let menuBar: MenuBarConfig?

    // MARK: - 初始化

    public init(
        id: String,
        name: String,
        version: String,
        minHostVersion: String,
        sdkVersion: String,
        dependencies: [Dependency] = [],
        capabilities: [String] = [],
        principalClass: String,
        viewModelClass: String? = nil,
        viewProviderClass: String? = nil,
        sidebarTabs: [SidebarTab] = [],
        commands: [Command] = [],
        subscribes: [String] = [],
        menuBar: MenuBarConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.minHostVersion = minHostVersion
        self.sdkVersion = sdkVersion
        self.dependencies = dependencies
        self.capabilities = capabilities
        self.principalClass = principalClass
        self.viewModelClass = viewModelClass
        self.viewProviderClass = viewProviderClass
        self.sidebarTabs = sidebarTabs
        self.commands = commands
        self.subscribes = subscribes
        self.menuBar = menuBar
    }
}

// MARK: - 嵌套类型

extension PluginManifest {

    /// 插件依赖
    public struct Dependency: Sendable, Codable, Equatable {
        /// 依赖的插件 ID
        public let id: String

        /// 最低版本要求
        public let minVersion: String

        public init(id: String, minVersion: String) {
            self.id = id
            self.minVersion = minVersion
        }
    }

    /// 侧边栏 Tab 配置
    public struct SidebarTab: Sendable, Codable, Equatable {
        /// Tab ID
        public let id: String

        /// Tab 标题
        public let title: String

        /// Tab 图标（SF Symbol）
        public let icon: String

        /// 视图类名
        public let viewClass: String

        public init(id: String, title: String, icon: String, viewClass: String) {
            self.id = id
            self.title = title
            self.icon = icon
            self.viewClass = viewClass
        }
    }

    /// 命令配置
    public struct Command: Sendable, Codable, Equatable {
        /// 命令 ID
        public let id: String

        /// 命令标题
        public let title: String

        /// 处理方法名
        public let handler: String

        /// 快捷键绑定（可选）
        public let keyBinding: String?

        public init(id: String, title: String, handler: String, keyBinding: String? = nil) {
            self.id = id
            self.title = title
            self.handler = handler
            self.keyBinding = keyBinding
        }
    }

    /// MenuBar 状态栏配置
    public struct MenuBarConfig: Sendable, Codable, Equatable {
        /// MenuBar 标识符
        public let id: String

        /// NSStatusItem 宽度，默认 90
        public let width: Int

        public init(id: String, width: Int = 90) {
            self.id = id
            self.width = width
        }
    }
}

// MARK: - 加载

extension PluginManifest {

    /// 从 Bundle 路径加载 manifest
    ///
    /// - Parameter bundlePath: Bundle 目录路径
    /// - Returns: 解析后的 manifest
    /// - Throws: 文件不存在或格式错误时抛出异常
    public static func load(from bundlePath: String) throws -> PluginManifest {
        let manifestPath = (bundlePath as NSString)
            .appendingPathComponent("Contents")
            .appending("/Resources/manifest.json")

        let url = URL(fileURLWithPath: manifestPath)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(PluginManifest.self, from: data)
    }
}
