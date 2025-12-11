//
//  PluginManager.swift
//  ETerm
//
//  插件层 - 插件管理器

import Foundation
import SwiftUI
import Combine

/// 插件信息（给 UI 用）
struct PluginInfo: Identifiable {
    let id: String
    let name: String
    let version: String
    let dependencies: [String]
    let isLoaded: Bool
    let isEnabled: Bool
    /// 依赖此插件的其他插件
    let dependents: [String]
}

/// 插件管理器 - 负责插件的加载、激活和停用
///
/// 单例模式，管理应用中所有插件的生命周期
/// 支持 DAG 依赖结构，使用 Kahn 算法拓扑排序加载
/// 支持运行时热插拔（启用/禁用）
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    // MARK: - 持久化 Key

    private static let disabledPluginsKey = "com.eterm.disabledPlugins"

    // MARK: - 私有属性

    /// 待加载的插件类型：PluginID -> Plugin.Type
    private var pluginTypes: [String: Plugin.Type] = [:]

    /// 已加载的插件实例：PluginID -> Plugin
    private var plugins: [String: Plugin] = [:]

    /// 插件上下文实现
    private let context: PluginContextImpl

    /// 禁用的插件 ID 集合（持久化）
    private var disabledPluginIds: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Self.disabledPluginsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.disabledPluginsKey)
            objectWillChange.send()
        }
    }

    // MARK: - 初始化

    private init() {
        // 创建插件上下文
        self.context = PluginContextImpl(
            commands: CommandRegistry.shared,
            events: EventBus.shared,
            keyboard: KeyboardServiceImpl.shared,
            ui: UIServiceImpl.shared,
            services: ServiceRegistry.shared
        )
    }

    // MARK: - 公共方法

    /// 注册插件类型（不立即加载）
    func registerPluginType<T: Plugin>(_ pluginType: T.Type) {
        let pluginId = T.id

        guard pluginTypes[pluginId] == nil else {
            print("⚠️ 插件类型已注册: \(T.name)")
            return
        }

        pluginTypes[pluginId] = pluginType
        print("📝 插件类型已注册: \(T.name) (id: \(pluginId))")
    }

    /// 加载所有内置插件
    ///
    /// 使用 Kahn 算法按依赖关系拓扑排序后加载
    func loadBuiltinPlugins() {
        // 1. 注册所有插件类型
        registerPluginType(EnglishLearningPlugin.self)
        registerPluginType(WritingAssistantPlugin.self)
        registerPluginType(OneLineCommandPlugin.self)
        registerPluginType(ClaudeMonitorPlugin.self)
        registerPluginType(ClaudePlugin.self)
        registerPluginType(VlaudePlugin.self)
        registerPluginType(DevHelperPlugin.self)
        registerPluginType(WorkspacePlugin.self)

        // 2. 拓扑排序并加载
        loadAllRegisteredPlugins()

        print("🔌 插件管理器已初始化")
    }

    /// 使用 Kahn 算法加载所有已注册的插件
    private func loadAllRegisteredPlugins() {
        // 1. 构建入度表和邻接表
        var inDegree: [String: Int] = [:]        // 插件 -> 依赖数量
        var dependents: [String: [String]] = [:] // 插件 -> 依赖它的插件列表

        for (id, type) in pluginTypes {
            inDegree[id] = type.dependencies.count
            for dep in type.dependencies {
                dependents[dep, default: []].append(id)
            }
        }

        // 2. 入度为 0 的入队（无依赖的根插件）
        var queue = inDegree.filter { $0.value == 0 }.map { $0.key }
        var loadOrder: [String] = []

        // 3. BFS 拓扑排序
        while !queue.isEmpty {
            let pluginId = queue.removeFirst()
            loadOrder.append(pluginId)

            // 加载该插件后，依赖它的插件入度 -1
            for dependent in dependents[pluginId, default: []] {
                inDegree[dependent]! -= 1
                if inDegree[dependent] == 0 {
                    queue.append(dependent)
                }
            }
        }

        // 4. 循环依赖检测
        if loadOrder.count != pluginTypes.count {
            let stuck = pluginTypes.keys.filter { !loadOrder.contains($0) }
            print("🔴 [PluginManager] 检测到循环依赖: \(stuck)")
            // 不 fatal，继续加载可以加载的插件
        }

        // 5. 按顺序加载（跳过禁用的）
        for pluginId in loadOrder {
            if isPluginEnabled(pluginId) {
                loadPluginById(pluginId)
            } else {
                print("⏸️ 插件已禁用，跳过加载: \(pluginId)")
            }
        }
    }

    /// 按 ID 加载单个插件（内部方法）
    private func loadPluginById(_ pluginId: String) {
        guard let pluginType = pluginTypes[pluginId] else {
            print("⚠️ 插件类型不存在: \(pluginId)")
            return
        }

        guard plugins[pluginId] == nil else {
            print("⚠️ 插件已加载: \(pluginId)")
            return
        }

        // 检查依赖是否都已加载
        for depId in pluginType.dependencies {
            guard plugins[depId] != nil else {
                print("🔴 插件 \(pluginId) 的依赖 \(depId) 未加载")
                return
            }
        }

        // 创建并激活插件
        let plugin = pluginType.init()
        plugin.activate(context: context)
        plugins[pluginId] = plugin

        print("✅ 插件已加载: \(pluginType.name) v\(pluginType.version)")
    }

    /// 加载并激活插件（兼容旧 API）
    /// - Parameter pluginType: 插件类型
    func loadPlugin<T: Plugin>(_ pluginType: T.Type) {
        registerPluginType(pluginType)
        loadPluginById(T.id)
    }

    /// 停用并卸载插件（内部方法，不改变启用状态）
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否成功卸载
    @discardableResult
    private func unloadPluginInternal(_ pluginId: String) -> Bool {
        guard let plugin = plugins[pluginId] else {
            return true  // 本来就没加载
        }

        // 检查是否有其他已加载的插件依赖此插件
        let dependentPlugins = plugins.keys.filter { otherId in
            guard let otherType = pluginTypes[otherId] else { return false }
            return otherType.dependencies.contains(pluginId)
        }

        if !dependentPlugins.isEmpty {
            print("⚠️ 无法卸载插件 \(pluginId)，以下插件依赖它: \(dependentPlugins)")
            return false
        }

        // 停用插件
        plugin.deactivate()

        // 注销该插件的服务
        ServiceRegistry.shared.unregisterAll(for: pluginId)

        // 注销侧边栏 Tab
        SidebarRegistry.shared.unregisterTabs(for: pluginId)

        // 注销插件页面
        PluginPageRegistry.shared.unregister(pluginId: pluginId)

        // 移除插件实例（保留类型，以便重新启用）
        plugins.removeValue(forKey: pluginId)

        print("🔌 插件已卸载: \(pluginId)")
        objectWillChange.send()
        return true
    }

    /// 停用并卸载插件（公开方法，同时标记为禁用）
    /// - Parameter pluginId: 插件 ID
    func unloadPlugin(_ pluginId: String) {
        if unloadPluginInternal(pluginId) {
            var disabled = disabledPluginIds
            disabled.insert(pluginId)
            disabledPluginIds = disabled
        }
    }

    // MARK: - 热插拔 API

    /// 检查插件是否启用
    func isPluginEnabled(_ pluginId: String) -> Bool {
        !disabledPluginIds.contains(pluginId)
    }

    /// 检查插件是否已加载
    func isPluginLoaded(_ pluginId: String) -> Bool {
        plugins[pluginId] != nil
    }

    /// 启用插件（热加载）
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否成功
    @discardableResult
    func enablePlugin(_ pluginId: String) -> Bool {
        guard pluginTypes[pluginId] != nil else {
            print("⚠️ 插件类型不存在: \(pluginId)")
            return false
        }

        // 先启用依赖
        let deps = pluginTypes[pluginId]!.dependencies
        for depId in deps {
            if !isPluginEnabled(depId) {
                print("📦 启用依赖插件: \(depId)")
                if !enablePlugin(depId) {
                    print("🔴 无法启用依赖 \(depId)，取消启用 \(pluginId)")
                    return false
                }
            }
        }

        // 从禁用列表移除
        var disabled = disabledPluginIds
        disabled.remove(pluginId)
        disabledPluginIds = disabled

        // 加载插件
        loadPluginById(pluginId)

        return plugins[pluginId] != nil
    }

    /// 禁用插件（热卸载）
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 是否成功
    @discardableResult
    func disablePlugin(_ pluginId: String) -> Bool {
        // 先禁用依赖此插件的其他插件
        let dependents = getDependents(of: pluginId)
        for depId in dependents {
            if isPluginLoaded(depId) {
                print("📦 级联禁用插件: \(depId)")
                if !disablePlugin(depId) {
                    print("🔴 无法级联禁用 \(depId)")
                    return false
                }
            }
        }

        // 卸载插件
        if !unloadPluginInternal(pluginId) {
            return false
        }

        // 加入禁用列表
        var disabled = disabledPluginIds
        disabled.insert(pluginId)
        disabledPluginIds = disabled

        return true
    }

    /// 切换插件启用状态
    /// - Parameter pluginId: 插件 ID
    /// - Returns: 新的启用状态
    @discardableResult
    func togglePlugin(_ pluginId: String) -> Bool {
        if isPluginEnabled(pluginId) {
            disablePlugin(pluginId)
            return false
        } else {
            enablePlugin(pluginId)
            return true
        }
    }

    // MARK: - 查询 API

    /// 获取依赖指定插件的所有插件 ID
    func getDependents(of pluginId: String) -> [String] {
        pluginTypes.compactMap { (otherId, otherType) in
            otherType.dependencies.contains(pluginId) ? otherId : nil
        }
    }

    /// 获取已加载的插件
    func loadedPlugins() -> [Plugin] {
        Array(plugins.values)
    }

    /// 获取插件实例
    func getPlugin(_ pluginId: String) -> Plugin? {
        plugins[pluginId]
    }

    /// 获取所有插件信息（给 UI 用）
    func allPluginInfos() -> [PluginInfo] {
        pluginTypes.map { (id, type) in
            PluginInfo(
                id: id,
                name: type.name,
                version: type.version,
                dependencies: type.dependencies,
                isLoaded: plugins[id] != nil,
                isEnabled: isPluginEnabled(id),
                dependents: getDependents(of: id)
            )
        }.sorted { $0.name < $1.name }
    }
}

// MARK: - 插件上下文实现

/// 插件上下文的具体实现
private final class PluginContextImpl: PluginContext {
    let commands: CommandService
    let events: EventService
    let keyboard: KeyboardService
    let ui: UIService
    let services: ServiceRegistry

    init(
        commands: CommandService,
        events: EventService,
        keyboard: KeyboardService,
        ui: UIService,
        services: ServiceRegistry
    ) {
        self.commands = commands
        self.events = events
        self.keyboard = keyboard
        self.ui = ui
        self.services = services
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

    func registerPage(for pluginId: String, title: String, icon: String, viewProvider: @escaping () -> AnyView) {
        // 在当前激活的窗口中添加插件 Page
        DispatchQueue.main.async {
            // 获取当前激活的窗口
            guard let activeWindow = NSApp.keyWindow,
                  let coordinator = WindowManager.shared.getCoordinator(for: activeWindow.windowNumber) else {
                print("⚠️ [UIService] No active window or coordinator found")
                return
            }

            // 添加插件 Page
            let newPage = coordinator.terminalWindow.addPluginPage(
                pluginId: pluginId,
                title: title,
                viewProvider: viewProvider
            )

            // 切换到新创建的插件 Page
            _ = coordinator.terminalWindow.switchToPage(newPage.pageId)

            // 触发 UI 更新
            coordinator.objectWillChange.send()
            coordinator.updateTrigger = UUID()

            print("✅ [UIService] Registered plugin page: \(title) for plugin \(pluginId)")
        }
    }

    func registerPluginPageEntry(
        for pluginId: String,
        pluginName: String,
        icon: String,
        viewProvider: @escaping () -> AnyView
    ) {
        // 1. 在 PluginPageRegistry 注册页面定义
        let definition = PluginPageRegistry.PageDefinition(
            pluginId: pluginId,
            title: pluginName,
            icon: icon,
            viewProvider: viewProvider
        )
        PluginPageRegistry.shared.register(definition)

        // 2. 在侧边栏注册入口按钮（点击直接打开 PluginPage）
        let entryTab = SidebarTab(
            id: "\(pluginId)-page-entry",
            title: pluginName,
            icon: icon,
            viewProvider: {
                // 占位视图（不会显示，因为 onSelect 会直接打开页面）
                AnyView(EmptyView())
            },
            onSelect: {
                // 点击时直接打开 PluginPage
                PluginPageRegistry.shared.openPage(pluginId: pluginId)
            }
        )

        SidebarRegistry.shared.registerTab(
            for: pluginId,
            pluginName: pluginName,
            tab: entryTab
        )

        print("✅ [UIService] Registered plugin page entry: \(pluginName) (id: \(pluginId))")
    }
}


