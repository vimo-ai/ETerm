//
//  PluginManager.swift
//  ETerm
//
//  插件层 - 插件管理器

import Foundation
import SwiftUI

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
        loadPlugin(EnglishLearningPlugin.self)  // 英语学习插件（统一了翻译、单词本、语法档案）
        loadPlugin(WritingAssistantPlugin.self)
        loadPlugin(OneLineCommandPlugin.self)
        loadPlugin(ClaudeMonitorPlugin.self)    // Claude 监控插件
        loadPlugin(ClaudePlugin.self)           // Claude 集成（Socket Server）
        loadPlugin(VlaudePlugin.self)           // Vlaude 远程（依赖 Claude）
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

    /// 命令绑定
    struct CommandBinding {
        let commandId: CommandID
        let when: String?
    }

    /// 快捷键到命令的绑定映射（支持多个绑定）
    private var bindings: [KeyStroke: [CommandBinding]] = [:]

    private init() {}

    // MARK: - KeyboardService 协议实现

    func bind(_ keyStroke: KeyStroke, to commandId: CommandID, when: String?) {
        // 检查冲突
        if let existing = bindings[keyStroke], !existing.isEmpty {
            print("⚠️ [KeyboardService] 快捷键冲突：\(keyStroke.displayString)")
            print("   已有绑定：\(existing.map { $0.commandId }.joined(separator: ", "))")
            print("   新绑定：\(commandId) 将被忽略")

            // 发送冲突通知
            NotificationCenter.default.post(
                name: NSNotification.Name("KeyBindingConflict"),
                object: KeyBindingConflict(
                    keyStroke: keyStroke,
                    existingCommands: existing.map { $0.commandId },
                    newCommand: commandId
                )
            )

            return  // 第一个绑定生效，后续被拒绝
        }

        // 添加绑定
        bindings[keyStroke] = [CommandBinding(commandId: commandId, when: when)]
        print("⌨️ [KeyboardService] 绑定快捷键: \(keyStroke.displayString) -> \(commandId)" + (when.map { " (when: \($0))" } ?? ""))
    }

    func unbind(_ keyStroke: KeyStroke) {
        bindings.removeValue(forKey: keyStroke)
        print("⌨️ [KeyboardService] 解绑快捷键: \(keyStroke.displayString)")
    }

    // MARK: - 内部方法

    /// 查找快捷键绑定的命令（支持 when 子句）
    /// - Parameters:
    ///   - keyStroke: 按键
    ///   - context: when 子句上下文
    /// - Returns: 命令 ID（如果有绑定且条件满足）
    func findCommand(for keyStroke: KeyStroke, context: WhenClauseContext) -> CommandID? {
        // 查找匹配的绑定
        for (boundKey, commandBindings) in bindings {
            if boundKey.matches(keyStroke) {
                // 找到第一个满足 when 条件的绑定
                for binding in commandBindings {
                    if WhenClauseEvaluator.evaluate(binding.when, context: context) {
                        return binding.commandId
                    }
                }
            }
        }
        return nil
    }

    /// 处理按键，如果有绑定的命令则执行
    /// - Parameters:
    ///   - keyStroke: 按键
    ///   - whenContext: when 子句上下文
    ///   - commandContext: 命令执行上下文
    /// - Returns: 是否处理了该按键
    func handleKeyStroke(
        _ keyStroke: KeyStroke,
        whenContext: WhenClauseContext,
        commandContext: CommandContext
    ) -> Bool {
        if let commandId = findCommand(for: keyStroke, context: whenContext) {
            CommandRegistry.shared.execute(commandId, context: commandContext)
            return true
        }
        return false
    }

    /// 获取所有快捷键绑定（用于 UI 显示）
    func getAllBindings() -> [(KeyStroke, [CommandBinding])] {
        return Array(bindings)
    }
}

// MARK: - UI 服务实现

/// UI 服务实现
final class UIServiceImpl: UIService {
    static let shared = UIServiceImpl()

    private init() {}

    func registerSidebarTab(for pluginId: String, pluginName: String, tab: SidebarTab) {
        SidebarRegistry.shared.registerTab(for: pluginId, pluginName: pluginName, tab: tab)
    }

    func unregisterSidebarTabs(for pluginId: String) {
        SidebarRegistry.shared.unregisterTabs(for: pluginId)
    }

    func registerInfoContent(for pluginId: String, id: String, title: String, viewProvider: @escaping () -> AnyView) {
        InfoWindowRegistry.shared.registerContent(id: id, title: title, viewProvider: viewProvider)
    }
}
