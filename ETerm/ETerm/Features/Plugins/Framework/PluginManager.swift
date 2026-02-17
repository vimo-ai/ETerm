//
//  PluginManager.swift
//  ETerm
//
//  插件层 - 服务实现

import Foundation
import SwiftUI
import Combine
import ETermKit

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
        persistable: Bool = true,
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
            pluginId: pluginId,
            isPersistable: persistable
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
            return createViewTabInCurrentPanel(tab: tab)

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
            let page = coordinator.terminalWindow.pages.openOrSwitchToPlugin(
                pluginId: pluginId,
                title: title,
                viewProvider: viewProvider
            )

            // 切换到该页面
            _ = coordinator.terminalWindow.pages.switchTo(page.pageId)

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

        // 保存 Session（分栏创建 View Tab，需要备份）
        WindowManager.shared.saveSessionWithBackup()

        return tab
    }

    /// 在当前 Panel 新增 View Tab（.tab placement）
    ///
    /// 如果当前在 Plugin Page（无 Panel），自动切到最近的 Terminal Page。
    private func createViewTabInCurrentPanel(tab: Tab) -> Tab? {
        var resultTab: Tab? = nil

        if Thread.isMainThread {
            resultTab = executeCreateViewTabInCurrentPanel(tab: tab)
        } else {
            DispatchQueue.main.sync {
                resultTab = executeCreateViewTabInCurrentPanel(tab: tab)
            }
        }

        return resultTab
    }

    /// 执行在当前 Panel 新增 View Tab（内部方法，需在主线程调用）
    private func executeCreateViewTabInCurrentPanel(tab: Tab) -> Tab? {
        guard let activeWindow = NSApp.keyWindow,
              let coordinator = WindowManager.shared.getCoordinator(for: activeWindow.windowNumber) else {
            logWarn("[UIServiceImpl] createViewTabInCurrentPanel: no key window or coordinator")
            return nil
        }

        // 尝试获取当前 Panel
        var targetPanelId = coordinator.activePanelId
        logInfo("[UIServiceImpl] createViewTabInCurrentPanel: activePanelId=\(targetPanelId?.uuidString ?? "nil")")

        // 如果当前无 Panel（Plugin Page），切到最近的 Terminal Page
        if targetPanelId == nil {
            // 找最近的 Terminal Page（从当前 page 往前找，再往后找）
            let pages = coordinator.terminalWindow.pages.all
            let currentPageId = coordinator.terminalWindow.active.pageId

            // 找到当前 page 的 index
            let currentIndex = pages.firstIndex(where: { $0.pageId == currentPageId }) ?? 0

            // 先往前找，再往后找
            var terminalPage: Page? = nil
            for i in stride(from: currentIndex - 1, through: 0, by: -1) {
                if case .terminal = pages[i].content {
                    terminalPage = pages[i]
                    break
                }
            }
            if terminalPage == nil {
                for i in (currentIndex + 1)..<pages.count {
                    if case .terminal = pages[i].content {
                        terminalPage = pages[i]
                        break
                    }
                }
            }

            guard let page = terminalPage else {
                logWarn("[UIServiceImpl] createViewTabInCurrentPanel: no terminal page found")
                return nil
            }

            // 切换到该 Terminal Page
            _ = coordinator.terminalWindow.pages.switchTo(page.pageId)

            // 获取该 page 的 panel
            targetPanelId = coordinator.terminalWindow.active.panelId(for: page.pageId)
                ?? page.allPanels.first?.panelId
        }

        guard let panelId = targetPanelId,
              let panel = coordinator.terminalWindow.allPanels.first(where: { $0.panelId == panelId }) else {
            logWarn("[UIServiceImpl] createViewTabInCurrentPanel: no panel found")
            return nil
        }

        // 在 Panel 中添加 Tab 并激活
        logInfo("[UIServiceImpl] createViewTabInCurrentPanel: adding tab to panel \(panelId)")
        panel.addTab(tab)
        panel.setActiveTab(tab.tabId)

        // 触发 UI 更新
        coordinator.objectWillChange.send()
        coordinator.updateTrigger = UUID()

        // 保存 Session
        WindowManager.shared.saveSessionWithBackup()

        return tab
    }

    // MARK: - Tab 装饰 API 实现

    func setTabDecoration(terminalId: Int, decoration: TabDecoration?, skipIfActive: Bool = false) {
        // 1. 找到对应的 Tab 并更新模型
        var foundTab: Tab?
        var foundPage: Page?
        var foundCoordinator: TerminalWindowCoordinator?

        for coordinator in WindowManager.shared.getAllCoordinators() {
            for page in coordinator.terminalWindow.pages.all {
                for panel in page.allPanels {
                    if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                        foundTab = tab
                        foundPage = page
                        foundCoordinator = coordinator
                        break
                    }
                }
                if foundTab != nil { break }
            }
            if foundTab != nil { break }
        }

        guard let tab = foundTab else {
            return
        }

        // 2. 如果 skipIfActive，检查该 terminal 是否是当前 active 的
        if skipIfActive, let coordinator = foundCoordinator {
            if coordinator.getActiveTerminalId() == terminalId {
                // 用户正在看这个 terminal，不需要提醒
                return
            }
        }

        // 3. 更新 Tab 模型的装饰
        tab.decoration = decoration

        // 4. 发送通知让视图刷新（视图会从模型读取 effectiveDecoration）
        NotificationCenter.default.post(
            name: .tabDecorationChanged,
            object: nil,
            userInfo: [
                "terminal_id": terminalId,
                "tab_id": tab.tabId
            ]
        )

        // 5. 如果 Tab 所属 Page 不是当前 Page，发送 Page 刷新通知
        // Page.effectiveDecoration 是计算属性，会自动从 Tab 读取
        if let page = foundPage, let coordinator = foundCoordinator {
            let isCurrentPage = (page.pageId == coordinator.terminalWindow.active.pageId)
            if !isCurrentPage {
                NotificationCenter.default.post(
                    name: NSNotification.Name("PageNeedsAttention"),
                    object: nil,
                    userInfo: [
                        "pageId": page.pageId
                    ]
                )
            }
        }
    }

    func clearTabDecoration(terminalId: Int) {
        setTabDecoration(terminalId: terminalId, decoration: nil, skipIfActive: false)
    }

    func isTerminalActive(terminalId: Int) -> Bool {
        for coordinator in WindowManager.shared.getAllCoordinators() {
            if coordinator.getActiveTerminalId() == terminalId {
                return true
            }
        }
        return false
    }

    // MARK: - Tab Slot

    func registerTabSlot(
        for pluginId: String,
        slotId: String,
        priority: Int,
        viewProvider: @escaping (Tab) -> AnyView?
    ) {
        tabSlotRegistry.register(
            pluginId: pluginId,
            slotId: slotId,
            priority: priority,
            viewProvider: viewProvider
        )
    }

    func unregisterTabSlots(for pluginId: String) {
        tabSlotRegistry.unregister(pluginId: pluginId)
    }

    // MARK: - Page Slot

    func registerPageSlot(
        for pluginId: String,
        slotId: String,
        priority: Int,
        viewProvider: @escaping (Page) -> AnyView?
    ) {
        pageSlotRegistry.register(
            pluginId: pluginId,
            slotId: slotId,
            priority: priority,
            viewProvider: viewProvider
        )
    }

    func unregisterPageSlots(for pluginId: String) {
        pageSlotRegistry.unregister(pluginId: pluginId)
    }

    // MARK: - Tab 标题 API 实现

    func setTabTitle(terminalId: Int, title: String) {
        // 找到对应的 Tab 并设置插件标题
        for coordinator in WindowManager.shared.getAllCoordinators() {
            for page in coordinator.terminalWindow.pages.all {
                for panel in page.allPanels {
                    if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                        // 如果用户已设置标题，不允许插件覆盖
                        guard tab.userTitle == nil else { return }

                        tab.setPluginTitle(title)

                        // 通知视图刷新（同时设置 updateTrigger 确保 AppKit 视图刷新）
                        DispatchQueue.main.async {
                            coordinator.objectWillChange.send()
                            coordinator.updateTrigger = UUID()
                        }
                        return
                    }
                }
            }
        }
    }

    func clearTabTitle(terminalId: Int) {
        // 找到对应的 Tab 并清除插件标题
        for coordinator in WindowManager.shared.getAllCoordinators() {
            for page in coordinator.terminalWindow.pages.all {
                for panel in page.allPanels {
                    if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                        tab.clearPluginTitle()

                        // 通知视图刷新
                        DispatchQueue.main.async {
                            coordinator.objectWillChange.send()
                        }
                        return
                    }
                }
            }
        }
    }
}

// MARK: - 终端服务实现

/// 终端服务实现
final class TerminalServiceImpl: TerminalService {
    static let shared = TerminalServiceImpl()

    private init() {}

    @discardableResult
    func write(terminalId: Int, data: String) -> Bool {
        // 确保在主线程执行（访问 UI 状态）
        if !Thread.isMainThread {
            var result = false
            DispatchQueue.main.sync {
                result = self.writeOnMainThread(terminalId: terminalId, data: data)
            }
            return result
        }
        return writeOnMainThread(terminalId: terminalId, data: data)
    }

    private func writeOnMainThread(terminalId: Int, data: String) -> Bool {
        // 遍历所有 Coordinator 找到对应的 TerminalPool
        for coordinator in WindowManager.shared.getAllCoordinators() {
            // 检查该 coordinator 是否拥有这个 terminalId
            if coordinator.terminalWindow.allPanels.contains(where: { panel in
                panel.tabs.contains { $0.rustTerminalId == terminalId }
            }) {
                coordinator.terminalPool.writeInput(terminalId: terminalId, data: data)
                return true
            }
        }
        return false
    }

    func getTabId(for terminalId: Int) -> String? {
        // 确保在主线程执行（访问 UI 状态）
        if !Thread.isMainThread {
            var result: String?
            DispatchQueue.main.sync {
                result = self.getTabIdOnMainThread(for: terminalId)
            }
            return result
        }
        return getTabIdOnMainThread(for: terminalId)
    }

    private func getTabIdOnMainThread(for terminalId: Int) -> String? {
        for coordinator in WindowManager.shared.getAllCoordinators() {
            for page in coordinator.terminalWindow.pages.all {
                for panel in page.allPanels {
                    if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                        return tab.tabId.uuidString
                    }
                }
            }
        }
        return nil
    }
}
