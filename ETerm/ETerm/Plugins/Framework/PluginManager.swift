//
//  PluginManager.swift
//  ETerm
//
//  插件层 - 插件管理器

import Foundation

/// 插件管理器 - 负责插件的加载、激活和停用
///
/// 单例模式，管理应用中所有插件的生命周期
final class PluginManager {
    static let shared = PluginManager()

    // MARK: - 私有属性

    /// 已加载的插件：PluginID -> Plugin
    private var plugins: [String: Plugin] = [:]

    /// 插件上下文实现
    private let context: PluginContextImpl

    // MARK: - 初始化

    private init() {
        // 创建插件上下文
        self.context = PluginContextImpl(
            commands: CommandRegistry.shared,
            events: EventBus.shared,
            keyboard: KeyboardServiceImpl.shared,
            ui: UIServiceImpl.shared
        )
    }

    // MARK: - 公共方法

    /// 加载所有内置插件
    func loadBuiltinPlugins() {
        loadPlugin(TranslationPlugin.self)
        loadPlugin(WritingAssistantPlugin.self)
        loadPlugin(OneLineCommandPlugin.self)
        loadPlugin(LearningPlugin.self)  // 学习插件
        // loadPlugin(ExampleSidebarPlugin.self)  // 示例侧边栏插件（已禁用）
        print("🔌 插件管理器已初始化")
    }

    /// 加载并激活插件
    /// - Parameter pluginType: 插件类型
    func loadPlugin<T: Plugin>(_ pluginType: T.Type) {
        let pluginId = T.id

        // 检查是否已加载
        guard plugins[pluginId] == nil else {
            print("⚠️ 插件已加载: \(T.name)")
            return
        }

        // 创建插件实例
        let plugin = pluginType.init()

        // 激活插件
        plugin.activate(context: context)

        // 存储插件
        plugins[pluginId] = plugin

        print("✅ 插件已加载: \(T.name) v\(T.version)")
    }

    /// 停用并卸载插件
    /// - Parameter pluginId: 插件 ID
    func unloadPlugin(_ pluginId: String) {
        guard let plugin = plugins[pluginId] else {
            print("⚠️ 插件不存在: \(pluginId)")
            return
        }

        // 停用插件
        plugin.deactivate()

        // 移除插件
        plugins.removeValue(forKey: pluginId)

        print("🔌 插件已卸载: \(pluginId)")
    }

    /// 获取已加载的插件
    func loadedPlugins() -> [Plugin] {
        Array(plugins.values)
    }
}

// MARK: - 插件上下文实现

/// 插件上下文的具体实现
private final class PluginContextImpl: PluginContext {
    let commands: CommandService
    let events: EventService
    let keyboard: KeyboardService
    let ui: UIService

    init(
        commands: CommandService,
        events: EventService,
        keyboard: KeyboardService,
        ui: UIService
    ) {
        self.commands = commands
        self.events = events
        self.keyboard = keyboard
        self.ui = ui
    }
}

// MARK: - 键盘服务实现

/// 键盘服务实现
///
/// 管理快捷键到命令的绑定，提供命令系统的键盘集成
final class KeyboardServiceImpl: KeyboardService {
    static let shared = KeyboardServiceImpl()

    /// 快捷键到命令的绑定映射
    private var bindings: [KeyStroke: (commandId: CommandID, when: String?)] = [:]

    private init() {}

    // MARK: - KeyboardService 协议实现

    func bind(_ keyStroke: KeyStroke, to commandId: CommandID, when: String?) {
        bindings[keyStroke] = (commandId, when)
        print("⌨️ 绑定快捷键: \(keyStroke) -> \(commandId)")
    }

    func unbind(_ keyStroke: KeyStroke) {
        bindings.removeValue(forKey: keyStroke)
        print("⌨️ 解绑快捷键: \(keyStroke)")
    }

    // MARK: - 内部方法

    /// 查找快捷键绑定的命令
    /// - Parameter keyStroke: 按键
    /// - Returns: 命令 ID（如果有绑定）
    func findCommand(for keyStroke: KeyStroke) -> CommandID? {
        // 查找匹配的绑定
        for (boundKey, binding) in bindings {
            if boundKey.matches(keyStroke) {
                // 当前忽略 when 条件的检查
                // 后续可以扩展为检查上下文状态
                return binding.commandId
            }
        }
        return nil
    }

    /// 处理按键，如果有绑定的命令则执行
    /// - Parameters:
    ///   - keyStroke: 按键
    ///   - context: 命令上下文
    /// - Returns: 是否处理了该按键
    func handleKeyStroke(_ keyStroke: KeyStroke, context: CommandContext) -> Bool {
        // 调试日志：打印所有 Cmd 组合键
        if keyStroke.modifiers.contains(.command) {
            print("🔍 [KeyboardService] Received keystroke: \(keyStroke)")
        }

        if let commandId = findCommand(for: keyStroke) {
            print("✅ [KeyboardService] Found command: \(commandId)")
            CommandRegistry.shared.execute(commandId, context: context)
            return true
        }
        return false
    }

    /// 获取所有快捷键绑定（用于 UI 显示）
    func getAllBindings() -> [(KeyStroke, (commandId: CommandID, when: String?))] {
        return Array(bindings)
    }
}

// MARK: - UI 服务实现

/// UI 服务实现
final class UIServiceImpl: UIService {
    static let shared = UIServiceImpl()

    private init() {}

    func registerSidebarTab(for pluginId: String, tab: SidebarTab) {
        SidebarRegistry.shared.registerTab(for: pluginId, tab: tab)
    }

    func unregisterSidebarTabs(for pluginId: String) {
        SidebarRegistry.shared.unregisterTabs(for: pluginId)
    }
}
