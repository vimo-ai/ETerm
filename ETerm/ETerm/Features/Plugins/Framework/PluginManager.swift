//
//  PluginManager.swift
//  ETerm
//
//  插件层 - 插件管理器（JSON 文件存储）

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

    // MARK: - 持久化配置

    private let configFilePath = ETermPaths.pluginsConfig

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
            loadDisabledPlugins()
        }
        set {
            saveDisabledPlugins(newValue)
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

        // MARK: - Migration (TODO: Remove after v1.1)
        // 从 UserDefaults 迁移数据
        migrateFromUserDefaults()
    }

    // MARK: - 公共方法

    /// 注册插件类型（不立即加载）
    func registerPluginType<T: Plugin>(_ pluginType: T.Type) {
        let pluginId = T.id

        guard pluginTypes[pluginId] == nil else {
            return
        }

        pluginTypes[pluginId] = pluginType
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
            // 不 fatal，继续加载可以加载的插件
        }

        // 5. 按顺序加载（跳过禁用的）
        for pluginId in loadOrder {
            if isPluginEnabled(pluginId) {
                loadPluginById(pluginId)
            } else {
            }
        }
    }

    /// 按 ID 加载单个插件（内部方法）
    private func loadPluginById(_ pluginId: String) {
        guard let pluginType = pluginTypes[pluginId] else {
            return
        }

        guard plugins[pluginId] == nil else {
            return
        }

        // 检查依赖是否都已加载
        for depId in pluginType.dependencies {
            guard plugins[depId] != nil else {
                return
            }
        }

        // 创建并激活插件
        let plugin = pluginType.init()
        plugin.activate(context: context)
        plugins[pluginId] = plugin

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
            return false
        }

        // 停用插件
        plugin.deactivate()

        // 注销该插件的服务
        ServiceRegistry.shared.unregisterAll(for: pluginId)

        // 注销侧边栏 Tab
        SidebarRegistry.shared.unregisterTabs(for: pluginId)

        // 注销 View Tab 视图定义
        ViewTabRegistry.shared.unregisterAll(for: pluginId)

        // 注销 PageBar 组件
        PageBarItemRegistry.shared.unregisterItems(for: pluginId)

        // 移除插件实例（保留类型，以便重新启用）
        plugins.removeValue(forKey: pluginId)

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
            return false
        }

        // 先启用依赖
        let deps = pluginTypes[pluginId]!.dependencies
        for depId in deps {
            if !isPluginEnabled(depId) {
                if !enablePlugin(depId) {
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
                if !disablePlugin(depId) {
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

    // MARK: - 持久化

    /// 插件配置数据模型
    private struct PluginsConfig: Codable {
        var disabledPlugins: [String]
    }

    /// 从 JSON 文件加载禁用的插件列表
    private func loadDisabledPlugins() -> Set<String> {
        guard FileManager.default.fileExists(atPath: configFilePath) else {
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configFilePath))
            let config = try JSONDecoder().decode(PluginsConfig.self, from: data)
            return Set(config.disabledPlugins)
        } catch {
            logError("加载插件配置失败: \(error)")
            return []
        }
    }

    /// 保存禁用的插件列表到 JSON 文件
    private func saveDisabledPlugins(_ disabledPlugins: Set<String>) {
        do {
            // 确保父目录存在
            try ETermPaths.ensureParentDirectory(for: configFilePath)

            let config = PluginsConfig(disabledPlugins: Array(disabledPlugins))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)

            try data.write(to: URL(fileURLWithPath: configFilePath))
        } catch {
            logError("保存插件配置失败: \(error)")
        }
    }

    // MARK: - Migration (TODO: Remove after v1.1)

    /// 从旧的 UserDefaults 迁移数据
    private func migrateFromUserDefaults() {
        let disabledPluginsKey = "com.eterm.disabledPlugins"
        let userDefaults = UserDefaults.standard

        guard let disabledPlugins = userDefaults.stringArray(forKey: disabledPluginsKey) else {
            return
        }

        // 保存到新位置
        saveDisabledPlugins(Set(disabledPlugins))

        // 清除旧数据
        userDefaults.removeObject(forKey: disabledPluginsKey)
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
    }

    func unbind(_ keyStroke: KeyStroke) {
        bindings.removeValue(forKey: keyStroke)
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

    func registerPageBarItem(for pluginId: String, id: String, viewProvider: @escaping () -> AnyView) {
        PageBarItemRegistry.shared.registerItem(for: pluginId, id: id, viewProvider: viewProvider)
    }

    @discardableResult
    func createViewTab(
        for pluginId: String,
        viewId: String,
        title: String,
        placement: ViewTabPlacement,
        viewProvider: @escaping () -> AnyView
    ) -> Tab? {
        // 1. 注册视图到 ViewTabRegistry
        let definition = ViewTabRegistry.ViewDefinition(
            viewId: viewId,
            pluginId: pluginId,
            title: title,
            viewProvider: viewProvider
        )
        ViewTabRegistry.shared.register(definition)

        // 2. 检查是否已有相同 viewId 的 Tab，如果有就切换到它
        if let existingTab = findAndActivateExistingViewTab(viewId: viewId) {
            return existingTab
        }

        // 3. 创建 ViewTabContent 和 Tab
        let viewTabContent = ViewTabContent(
            viewId: viewId,
            pluginId: pluginId
        )
        let tab = Tab(
            tabId: UUID(),
            title: title,
            content: .view(viewTabContent)
        )

        // 4. 根据 placement 执行不同逻辑
        switch placement {
        case .split(let direction):
            return createViewTabWithSplit(tab: tab, direction: direction)

        case .tab:
            // 暂时 fallback 到 split（水平方向）
            return createViewTabWithSplit(tab: tab, direction: .horizontal)

        case .page:
            // 创建独立 Page
            createViewTabAsPage(pluginId: pluginId, title: title, viewProvider: viewProvider)
            return nil  // Page 模式不返回 Tab
        }
    }

    /// 查找并激活已有的 View Tab
    private func findAndActivateExistingViewTab(viewId: String) -> Tab? {
        guard Thread.isMainThread else {
            var result: Tab? = nil
            DispatchQueue.main.sync {
                result = findAndActivateExistingViewTab(viewId: viewId)
            }
            return result
        }

        guard let activeWindow = NSApp.keyWindow,
              let coordinator = WindowManager.shared.getCoordinator(for: activeWindow.windowNumber) else {
            return nil
        }

        // 遍历所有 Panel 查找已有的 View Tab
        for panel in coordinator.terminalWindow.allPanels {
            for tab in panel.tabs {
                if case .view(let content) = tab.content, content.viewId == viewId {
                    // 找到了，激活这个 Tab
                    panel.setActiveTab(tab.tabId)
                    coordinator.setActivePanel(panel.panelId)
                    coordinator.objectWillChange.send()
                    coordinator.updateTrigger = UUID()
                    return tab
                }
            }
        }

        return nil
    }

    func registerViewProvider(
        for pluginId: String,
        viewId: String,
        title: String,
        viewProvider: @escaping () -> AnyView
    ) {
        // 只注册视图到 Registry，不创建 Tab
        let definition = ViewTabRegistry.ViewDefinition(
            viewId: viewId,
            pluginId: pluginId,
            title: title,
            viewProvider: viewProvider
        )
        ViewTabRegistry.shared.register(definition)
    }

    /// 创建 View Tab 作为独立 Page
    private func createViewTabAsPage(pluginId: String, title: String, viewProvider: @escaping () -> AnyView) {
        DispatchQueue.main.async {
            guard let activeWindow = NSApp.keyWindow,
                  let coordinator = WindowManager.shared.getCoordinator(for: activeWindow.windowNumber) else {
                return
            }

            // 尝试打开或切换到已有的插件页面
            let page = coordinator.terminalWindow.openOrSwitchToPluginPage(
                pluginId: pluginId,
                title: title,
                viewProvider: viewProvider
            )

            // 切换到该页面
            _ = coordinator.terminalWindow.switchToPage(page.pageId)

            // 触发 UI 更新
            coordinator.objectWillChange.send()
            coordinator.updateTrigger = UUID()
        }
    }

    /// 使用分栏方式创建 View Tab
    private func createViewTabWithSplit(tab: Tab, direction: SplitDirection) -> Tab? {
        var resultTab: Tab? = nil

        // 必须在主线程执行 UI 操作
        if Thread.isMainThread {
            resultTab = executeCreateViewTabWithSplit(tab: tab, direction: direction)
        } else {
            DispatchQueue.main.sync {
                resultTab = executeCreateViewTabWithSplit(tab: tab, direction: direction)
            }
        }

        return resultTab
    }

    /// 执行分栏创建 View Tab（内部方法，需在主线程调用）
    private func executeCreateViewTabWithSplit(tab: Tab, direction: SplitDirection) -> Tab? {
        // 获取当前激活的窗口和 Coordinator
        guard let activeWindow = NSApp.keyWindow,
              let coordinator = WindowManager.shared.getCoordinator(for: activeWindow.windowNumber) else {
            return nil
        }

        // 获取当前激活的 Panel
        guard let activePanelId = coordinator.activePanelId else {
            return nil
        }

        // 将 SplitDirection 转换为 EdgeDirection
        let edge: EdgeDirection = direction == .horizontal ? .right : .bottom

        // 使用 splitPanelWithExistingTab 分栏
        let layoutCalculator = BinaryTreeLayoutCalculator()
        guard let newPanelId = coordinator.terminalWindow.splitPanelWithExistingTab(
            panelId: activePanelId,
            existingTab: tab,
            edge: edge,
            layoutCalculator: layoutCalculator
        ) else {
            return nil
        }

        // 设置新 Panel 为激活状态
        coordinator.setActivePanel(newPanelId)

        // 同步布局到 Rust
        coordinator.syncLayoutToRust()

        // 触发 UI 更新
        coordinator.objectWillChange.send()
        coordinator.updateTrigger = UUID()

        // 保存 Session
        WindowManager.shared.saveSession()

        return tab
    }

    // MARK: - Tab 装饰 API 实现

    func setTabDecoration(terminalId: Int, decoration: TabDecoration?) {
        print("[UIService] 📤 发送装饰通知: terminalId=\(terminalId), decoration=\(String(describing: decoration))")
        // 发送通用通知，核心层的 TabItemView 会监听并渲染
        NotificationCenter.default.post(
            name: .tabDecorationChanged,
            object: nil,
            userInfo: [
                "terminal_id": terminalId,
                "decoration": decoration as Any
            ]
        )

        // 自动冒泡到 Page 级别：如果 Tab 所属 Page 不是当前 Page，也设置 Page 装饰
        bubbleDecorationToPage(terminalId: terminalId, decoration: decoration)
    }

    func clearTabDecoration(terminalId: Int) {
        setTabDecoration(terminalId: terminalId, decoration: nil)
    }

    /// 将 Tab 装饰冒泡到 Page 级别
    /// 如果 Tab 所属 Page 不是当前激活的 Page，则给 Page 也设置相同装饰
    private func bubbleDecorationToPage(terminalId: Int, decoration: TabDecoration?) {
        // 遍历所有窗口的 Coordinator 查找 terminalId 对应的 Tab
        for coordinator in WindowManager.shared.getAllCoordinators() {
            // 找到 terminalId 对应的 Tab 和 Page
            for page in coordinator.terminalWindow.pages {
                for panel in page.allPanels {
                    if panel.tabs.first(where: { $0.rustTerminalId == terminalId }) != nil {
                        // 检查是否是当前激活的 Page
                        let isCurrentPage = (page.pageId == coordinator.terminalWindow.activePageId)

                        if !isCurrentPage {
                            // 不是当前 Page，发送 Page 装饰通知（传递完整的 decoration）
                            NotificationCenter.default.post(
                                name: NSNotification.Name("PageNeedsAttention"),
                                object: nil,
                                userInfo: [
                                    "pageId": page.pageId,
                                    "decoration": decoration as Any
                                ]
                            )
                        }
                        return
                    }
                }
            }
        }
    }
}
