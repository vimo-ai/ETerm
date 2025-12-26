// PluginManifest.swift
// ETermKit
//
// 插件清单配置

import Foundation

/// 插件运行模式
public enum PluginRunMode: String, Sendable, Codable {
    /// 全部在主进程运行（简单，推荐内置插件用）
    case main
    /// Logic 在子进程运行（进程隔离，第三方插件可选）
    case isolated
}

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

    /// 运行模式
    ///
    /// - `main`: 全部在主进程运行（默认，推荐内置插件用）
    /// - `isolated`: Logic 在子进程运行（进程隔离）
    public let runMode: PluginRunMode

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
    /// 实现 PluginViewProvider 协议的 @objc 类名，用于从 Bundle 加载 SwiftUI View
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

    /// 底部停靠视图配置（可选）
    public let bottomDock: BottomDockConfig?

    /// 信息面板内容注册
    public let infoPanelContents: [InfoPanelContent]

    /// 选中气泡配置（可选）
    public let bubble: BubbleConfig?

    /// PageBar 组件注册
    ///
    /// 显示在 PageBar 右侧的组件（如用量监控）
    public let pageBarItems: [PageBarItem]

    /// Tab Slot 注册
    ///
    /// 在 Tab 标题旁边注入自定义视图（如状态图标、徽章）
    public let tabSlots: [TabSlot]

    /// Page Slot 注册
    ///
    /// 在 Page 标题旁边注入自定义视图（如统计信息）
    public let pageSlots: [PageSlot]

    /// 插件发出的事件列表
    public let emits: [String]

    /// Socket namespace 列表
    ///
    /// 声明插件需要的 socket namespace。主进程会：
    /// 1. 创建 `~/.eterm/run/sockets/{namespace}.sock` 路径
    /// 2. 设置环境变量 `ETERM_SOCKET_DIR=~/.eterm/run/sockets`
    ///
    /// 插件在 activate 时自己创建 socket server。
    ///
    /// 示例：`["claude"]` → `~/.eterm/run/sockets/claude.sock`
    public let sockets: [String]

    // MARK: - 初始化

    public init(
        id: String,
        name: String,
        version: String,
        minHostVersion: String,
        sdkVersion: String,
        runMode: PluginRunMode = .main,
        dependencies: [Dependency] = [],
        capabilities: [String] = [],
        principalClass: String,
        viewModelClass: String? = nil,
        viewProviderClass: String? = nil,
        sidebarTabs: [SidebarTab] = [],
        commands: [Command] = [],
        subscribes: [String] = [],
        menuBar: MenuBarConfig? = nil,
        bottomDock: BottomDockConfig? = nil,
        infoPanelContents: [InfoPanelContent] = [],
        bubble: BubbleConfig? = nil,
        pageBarItems: [PageBarItem] = [],
        tabSlots: [TabSlot] = [],
        pageSlots: [PageSlot] = [],
        emits: [String] = [],
        sockets: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.minHostVersion = minHostVersion
        self.sdkVersion = sdkVersion
        self.runMode = runMode
        self.dependencies = dependencies
        self.capabilities = capabilities
        self.principalClass = principalClass
        self.viewModelClass = viewModelClass
        self.viewProviderClass = viewProviderClass
        self.sidebarTabs = sidebarTabs
        self.commands = commands
        self.subscribes = subscribes
        self.menuBar = menuBar
        self.bottomDock = bottomDock
        self.infoPanelContents = infoPanelContents
        self.bubble = bubble
        self.pageBarItems = pageBarItems
        self.tabSlots = tabSlots
        self.pageSlots = pageSlots
        self.emits = emits
        self.sockets = sockets
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

        /// 渲染模式
        ///
        /// - "inline": 直接在 sidebar 里渲染 View（默认）
        /// - "tab": 点击后在 Tab 区域创建新的 View Tab
        public let renderMode: String?

        public init(id: String, title: String, icon: String, viewClass: String, renderMode: String? = nil) {
            self.id = id
            self.title = title
            self.icon = icon
            self.viewClass = viewClass
            self.renderMode = renderMode
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

    /// 底部停靠视图配置
    ///
    /// 底部停靠视图会挤压终端渲染区域，显示在终端底部
    public struct BottomDockConfig: Sendable, Codable, Equatable {
        /// 视图标识符
        public let id: String

        /// 视图类名
        public let viewClass: String

        /// 切换显示的命令 ID（关联 commands 中的命令）
        public let toggleCommand: String?

        /// 显示的命令 ID
        public let showCommand: String?

        /// 隐藏的命令 ID
        public let hideCommand: String?

        public init(
            id: String,
            viewClass: String,
            toggleCommand: String? = nil,
            showCommand: String? = nil,
            hideCommand: String? = nil
        ) {
            self.id = id
            self.viewClass = viewClass
            self.toggleCommand = toggleCommand
            self.showCommand = showCommand
            self.hideCommand = hideCommand
        }
    }

    /// 信息面板内容配置
    ///
    /// 注册到全局信息面板窗口的内容
    public struct InfoPanelContent: Sendable, Codable, Equatable {
        /// 内容标识符
        public let id: String

        /// 内容标题
        public let title: String

        /// 视图类名
        public let viewClass: String

        public init(id: String, title: String, viewClass: String) {
            self.id = id
            self.title = title
            self.viewClass = viewClass
        }
    }

    /// 选中气泡配置
    ///
    /// 在终端选中文本时显示的气泡
    public struct BubbleConfig: Sendable, Codable, Equatable {
        /// 气泡标识符
        public let id: String

        /// 提示图标（SF Symbol）
        public let hintIcon: String

        /// 气泡内容视图类名
        public let contentViewClass: String

        /// 展开后显示到信息面板的内容 ID（关联 infoPanelContents）
        public let expandToInfoPanel: String?

        /// 触发事件名
        public let trigger: String

        public init(
            id: String,
            hintIcon: String,
            contentViewClass: String,
            expandToInfoPanel: String? = nil,
            trigger: String = "terminal.didEndSelection"
        ) {
            self.id = id
            self.hintIcon = hintIcon
            self.contentViewClass = contentViewClass
            self.expandToInfoPanel = expandToInfoPanel
            self.trigger = trigger
        }
    }

    /// PageBar 组件配置
    ///
    /// 显示在 PageBar 右侧的组件
    public struct PageBarItem: Sendable, Codable, Equatable {
        /// 组件标识符
        public let id: String

        /// 视图类名
        public let viewClass: String

        public init(id: String, viewClass: String) {
            self.id = id
            self.viewClass = viewClass
        }
    }

    /// Tab Slot 配置
    ///
    /// 在 Tab 标题旁边注入自定义视图
    public struct TabSlot: Sendable, Codable, Equatable {
        /// Slot 标识符
        public let id: String

        /// 位置（leading 或 trailing）
        public let position: String

        public init(id: String, position: String = "trailing") {
            self.id = id
            self.position = position
        }
    }

    /// Page Slot 配置
    ///
    /// 在 Page 标题旁边注入自定义视图
    public struct PageSlot: Sendable, Codable, Equatable {
        /// Slot 标识符
        public let id: String

        /// 位置（leading 或 trailing）
        public let position: String

        public init(id: String, position: String = "trailing") {
            self.id = id
            self.position = position
        }
    }
}

// MARK: - Decodable（为新字段提供默认值）

extension PluginManifest {
    enum CodingKeys: String, CodingKey {
        case id, name, version, minHostVersion, sdkVersion, runMode
        case dependencies, capabilities, principalClass
        case viewModelClass, viewProviderClass
        case sidebarTabs, commands, subscribes
        case menuBar, bottomDock, infoPanelContents, bubble, pageBarItems
        case tabSlots, pageSlots, emits, sockets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 必填字段
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        minHostVersion = try container.decode(String.self, forKey: .minHostVersion)
        sdkVersion = try container.decode(String.self, forKey: .sdkVersion)
        principalClass = try container.decode(String.self, forKey: .principalClass)

        // 可选字段（有默认值）
        runMode = try container.decodeIfPresent(PluginRunMode.self, forKey: .runMode) ?? .main
        dependencies = try container.decodeIfPresent([Dependency].self, forKey: .dependencies) ?? []
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        viewModelClass = try container.decodeIfPresent(String.self, forKey: .viewModelClass)
        viewProviderClass = try container.decodeIfPresent(String.self, forKey: .viewProviderClass)
        sidebarTabs = try container.decodeIfPresent([SidebarTab].self, forKey: .sidebarTabs) ?? []
        commands = try container.decodeIfPresent([Command].self, forKey: .commands) ?? []
        subscribes = try container.decodeIfPresent([String].self, forKey: .subscribes) ?? []
        menuBar = try container.decodeIfPresent(MenuBarConfig.self, forKey: .menuBar)
        bottomDock = try container.decodeIfPresent(BottomDockConfig.self, forKey: .bottomDock)
        infoPanelContents = try container.decodeIfPresent([InfoPanelContent].self, forKey: .infoPanelContents) ?? []
        bubble = try container.decodeIfPresent(BubbleConfig.self, forKey: .bubble)
        pageBarItems = try container.decodeIfPresent([PageBarItem].self, forKey: .pageBarItems) ?? []
        tabSlots = try container.decodeIfPresent([TabSlot].self, forKey: .tabSlots) ?? []
        pageSlots = try container.decodeIfPresent([PageSlot].self, forKey: .pageSlots) ?? []
        emits = try container.decodeIfPresent([String].self, forKey: .emits) ?? []
        sockets = try container.decodeIfPresent([String].self, forKey: .sockets) ?? []
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
