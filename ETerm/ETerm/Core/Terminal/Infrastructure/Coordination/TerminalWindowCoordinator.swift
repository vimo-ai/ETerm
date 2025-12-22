//
//  TerminalWindowCoordinator.swift
//  ETerm
//
//  基础设施层 - 终端窗口协调器（DDD 架构）
//
//  职责：
//  - 连接 Domain AR 和基础设施层
//  - 管理终端生命周期
//  - 协调渲染流程
//
//  架构原则：
//  - Domain AR 是唯一的状态来源
//  - UI 层不持有状态，只负责显示和捕获输入
//  - 数据流单向：AR → UI → 用户事件 → AR
//
//  Extension 文件：
//  - +Page.swift       Page 管理（生命周期/跨窗口/拖拽）
//  - +Terminal.swift   终端生命周期（创建/关闭/事件）
//  - +Query.swift      所有查询方法（统一入口）
//  - +Drop.swift       Tab 拖拽处理
//  - +Input.swift      输入处理（键盘/鼠标/滚动）
//  - +Layout.swift     布局同步
//  - +Search.swift     搜索相关
//  - +Selection.swift  文本选中
//

import Foundation
import AppKit
import CoreGraphics
import Combine
import PanelLayoutKit

// MARK: - Notification Names

extension Notification.Name {
    /// Active 终端变化通知（Tab 切换或 Panel 切换）
    static let activeTerminalDidChange = Notification.Name("activeTerminalDidChange")
    /// 终端关闭通知
    static let terminalDidClose = Notification.Name("terminalDidClose")
}

/// 渲染视图协议 - 统一不同的 RenderView 实现
protocol RenderViewProtocol: AnyObject {
    func requestRender()

    /// 调整字体大小
    func changeFontSize(operation: FontSizeOperation)

    /// 设置指定 Page 的提醒状态
    func setPageNeedsAttention(_ pageId: UUID, attention: Bool)
}

/// 智能关闭结果
///
/// 用于 Cmd+W 智能关闭逻辑的返回值
enum SmartCloseResult {
    /// 关闭了一个 Tab
    case closedTab
    /// 关闭了一个 Panel
    case closedPanel
    /// 关闭了一个 Page
    case closedPage
    /// 需要关闭当前窗口（只剩最后一个 Tab/Panel/Page）
    case shouldCloseWindow
    /// 无可关闭的内容
    case nothingToClose
}

/// UI 事件（Coordinator → View 层通信）
///
/// 用于通知 View 层更新 UI 状态（如显示/隐藏 Composer、Search 等）
enum UIEvent {
    /// 显示 Composer
    case showComposer(position: CGPoint)
    /// 隐藏 Composer
    case hideComposer
    /// 切换 Composer 显示状态
    case toggleComposer(position: CGPoint)
    /// 显示搜索框
    case showSearch(panelId: UUID)
    /// 隐藏搜索框
    case hideSearch
    /// 切换搜索框显示状态
    case toggleSearch(panelId: UUID)
    /// 如果指定 Panel 正在搜索，清除搜索状态
    case clearSearchIfPanel(panelId: UUID)
}

/// 终端窗口协调器（DDD 架构）
class TerminalWindowCoordinator: ObservableObject {

    // MARK: - Domain Aggregates

    /// 终端窗口聚合根（唯一的状态来源）
    @Published private(set) var terminalWindow: TerminalWindow

    /// 更新触发器 - 用于触发 SwiftUI 的 updateNSView
    @Published var updateTrigger = UUID()

    /// 当前激活的焦点（订阅自领域层，单一数据源）
    @Published private(set) var activeFocus: ActiveFocus?

    /// 当前激活的 Panel ID（计算属性，从 activeFocus 派生）
    var activePanelId: UUID? { activeFocus?.panelId }

    /// 订阅存储
    private var cancellables = Set<AnyCancellable>()

    // MARK: - UI Event Publisher

    /// UI 事件发布者（用于通知 View 层更新状态）
    private let uiEventSubject = PassthroughSubject<UIEvent, Never>()

    /// UI 事件发布者（供 View 层订阅）
    var uiEventPublisher: AnyPublisher<UIEvent, Never> {
        uiEventSubject.eraseToAnyPublisher()
    }

    /// 发送 UI 事件
    func sendUIEvent(_ event: UIEvent) {
        uiEventSubject.send(event)
    }

    // MARK: - Composer State (for KeyableWindow check)

    /// Composer 是否显示（供 KeyableWindow 检查，由 View 层同步回来）
    /// 注意：这是一个镜像属性，真正的状态在 View 层
    @Published var isComposerShowing: Bool = false

    // MARK: - Search Helper

    /// 获取指定 Panel 的当前 Tab 搜索信息
    /// - Parameter searchPanelId: 搜索绑定的 Panel ID
    /// - Returns: Tab 的搜索信息（如果存在）
    func getTabSearchInfo(for searchPanelId: UUID?) -> TabSearchInfo? {
        guard let searchPanelId = searchPanelId,
              let panel = terminalWindow.getPanel(searchPanelId),
              let activeTab = panel.activeTab else {
            return nil
        }
        return activeTab.searchInfo
    }

    // MARK: - Infrastructure (internal for extensions)

    /// 终端池（用于渲染）
    var terminalPool: TerminalPoolProtocol

    /// 工作目录注册表（CWD 状态管理 - Single Source of Truth）
    /// 通过依赖注入，由 WindowManager 创建并传入
    let workingDirectoryRegistry: TerminalWorkingDirectoryRegistry

    /// 坐标映射器
    var coordinateMapper: CoordinateMapper?

    /// 字体度量
    var fontMetrics: SugarloafFontMetrics?

    /// 渲染视图引用
    weak var renderView: RenderViewProtocol?

    /// 键盘系统
    var keyboardSystem: KeyboardSystem?

    /// 命令录制代理
    private let recordingProxy = CommandRecordingProxy()

    // MARK: - Constants

    let headerHeight: CGFloat = 30.0

    // MARK: - CWD Inheritance

    /// 初始工作目录（继承自父窗口，可选）
    var initialCwd: String?

    // MARK: - Terminal Migration

    /// 待附加的分离终端（跨窗口迁移时使用）
    /// 当新窗口创建时，终端先分离存储在这里，等 TerminalPool 就绪后附加
    var pendingDetachedTerminals: [UUID: DetachedTerminalHandle] = [:]

    // MARK: - Render Debounce

    /// 防抖延迟任务
    var pendingRenderWorkItem: DispatchWorkItem?

    /// 防抖时间窗口（16ms，约一帧）
    let renderDebounceInterval: TimeInterval = 0.016

    // MARK: - Initialization

    /// 初始化终端窗口协调器
    ///
    /// - Parameters:
    ///   - initialWindow: 初始的 TerminalWindow
    ///   - workingDirectoryRegistry: CWD 注册表（依赖注入）
    ///   - terminalPool: 终端池（可选，默认使用 MockTerminalPool）
    init(
        initialWindow: TerminalWindow,
        workingDirectoryRegistry: TerminalWorkingDirectoryRegistry,
        terminalPool: TerminalPoolProtocol? = nil
    ) {
        // 获取继承的 CWD（如果有）
        self.initialCwd = WindowCwdManager.shared.takePendingCwd()

        self.terminalWindow = initialWindow
        self.workingDirectoryRegistry = workingDirectoryRegistry
        self.terminalPool = terminalPool ?? MockTerminalPool()

        // 不在这里创建终端，等 setTerminalPool 时再创建
        // （因为初始化时可能还在用 MockTerminalPool）

        // 订阅领域层的焦点变化（单一数据源，同步更新）
        // 注意：不使用 receive(on:) 确保状态同步是即时的
        // 所有 setPanel/setFocus 调用都在主线程，无需异步调度
        initialWindow.active.focusPublisher
            .sink { [weak self] focus in
                self?.activeFocus = focus
            }
            .store(in: &cancellables)

        // 初始化 activeFocus
        activeFocus = initialWindow.active.focus

        // 监听 Drop 意图执行通知
        setupDropIntentHandler()
    }

    /// 显式清理所有终端（在窗口关闭时调用）
    ///
    /// 这个方法应该在 windowWillClose 中调用，而不是依赖 deinit。
    /// 因为在 deinit 中访问对象可能导致野指针问题。
    func cleanup() {
        // 移除通知监听
        NotificationCenter.default.removeObserver(self)

        // 取消所有待处理的渲染任务
        pendingRenderWorkItem?.cancel()
        pendingRenderWorkItem = nil

        // 清除渲染视图引用
        renderView = nil

        // 收集所有终端 ID
        var terminalIds: [Int] = []
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    terminalIds.append(Int(terminalId))
                    tab.setRustTerminalId(nil)  // 清除引用，防止重复关闭
                }
            }
        }

        // 关闭终端
        for terminalId in terminalIds {
            _ = terminalPool.closeTerminal(terminalId)
        }
    }

    deinit {
        // 注意：不在 deinit 中访问 terminalWindow.allPanels
        // 清理工作应该在 cleanup() 中完成
        // 这里只做最小清理，防止任何野指针访问
        pendingRenderWorkItem?.cancel()
        pendingRenderWorkItem = nil
    }

    // MARK: - Tab with Command

    /// 创建新 Tab 并执行初始命令
    ///
    /// - Parameters:
    ///   - panelId: 目标 Panel ID（可选，默认为当前激活的 Panel）
    ///   - cwd: 工作目录
    ///   - command: 要执行的命令（可选）
    ///   - commandDelay: 命令执行延迟（默认 0.3 秒）
    /// - Returns: 创建的 Tab 和终端 ID，失败返回 nil
    func createNewTabWithCommand(
        in panelId: UUID? = nil,
        cwd: String,
        command: String? = nil,
        commandDelay: TimeInterval = 0.3
    ) -> (tab: Tab, terminalId: Int)? {
        let targetPanelId = panelId ?? activePanelId
        guard let targetPanelId = targetPanelId else {
            return nil
        }

        // 通过 Command 管道创建 Tab
        let config = TabConfig(cwd: cwd, command: command, commandDelay: commandDelay)
        let result = perform(.tab(.addWithConfig(panelId: targetPanelId, config: config)))

        guard result.success,
              let createdTabId = result.createdTabId,
              let panel = terminalWindow.getPanel(targetPanelId),
              let newTab = panel.tabs.first(where: { $0.tabId == createdTabId }),
              let terminalId = newTab.rustTerminalId else {
            return nil
        }

        // 如果有命令，延迟执行（命令执行保留在 Coordinator，属于 FFI 层）
        if let cmd = command, !cmd.isEmpty {
            let tid = terminalId
            DispatchQueue.main.asyncAfter(deadline: .now() + commandDelay) { [weak self] in
                self?.writeInput(terminalId: tid, data: cmd)
            }
        }

        return (newTab, terminalId)
    }

    // MARK: - User Interactions (从 UI 层调用)

    /// 用户点击 Tab
    func handleTabClick(panelId: UUID, tabId: UUID) {
        // 设置为激活的 Panel（用于键盘输入）
        setActivePanel(panelId)

        // 检查是否已经是激活的 Tab
        if let panel = terminalWindow.getPanel(panelId), panel.activeTabId == tabId {
            return
        }

        let result = perform(.tab(.switch(panelId: panelId, tabId: tabId)))

        // Coordinator 特有：通知 Active 终端变化（用于发光效果）
        if result.success {
            NotificationCenter.default.post(name: .activeTerminalDidChange, object: nil)
            // 🔥 Tab 切换时触发渲染，否则画面会卡住直到有 PTY 输出
            scheduleRender()
        }
    }

    /// 设置激活的 Panel（用于键盘输入）
    func setActivePanel(_ panelId: UUID) {
        guard activePanelId != panelId else { return }
        perform(.panel(.setActive(panelId: panelId)))
        // 🔥 Panel 切换时触发渲染，否则画面会卡住直到有 PTY 输出
        scheduleRender()
    }

    /// 用户关闭 Tab
    func handleTabClose(panelId: UUID, tabId: UUID) {
        perform(.tab(.close(panelId: panelId, scope: .single(tabId))))
    }

    /// 用户重命名 Tab
    func handleTabRename(panelId: UUID, tabId: UUID, newTitle: String) {
        guard let panel = terminalWindow.getPanel(panelId),
              panel.renameTab(tabId, to: newTitle) else {
            return
        }
        objectWillChange.send()
        updateTrigger = UUID()
    }

    /// 用户重新排序 Tabs
    func handleTabReorder(panelId: UUID, tabIds: [UUID]) {
        perform(.tab(.reorder(panelId: panelId, order: tabIds)))
    }

    /// 关闭其他 Tab（保留指定的 Tab）
    func handleTabCloseOthers(panelId: UUID, keepTabId: UUID) {
        perform(.tab(.close(panelId: panelId, scope: .others(keep: keepTabId))))
    }

    /// 关闭左侧 Tab
    func handleTabCloseLeft(panelId: UUID, fromTabId: UUID) {
        perform(.tab(.close(panelId: panelId, scope: .left(of: fromTabId))))
    }

    /// 关闭右侧 Tab
    func handleTabCloseRight(panelId: UUID, fromTabId: UUID) {
        perform(.tab(.close(panelId: panelId, scope: .right(of: fromTabId))))
    }

    /// 智能关闭（Cmd+W）
    ///
    /// 关闭逻辑：
    /// 1. 如果当前 Panel 有多个 Tab → 关闭当前 Tab
    /// 2. 如果当前 Page 有多个 Panel → 关闭当前 Panel
    /// 3. 如果当前 Window 有多个 Page → 关闭当前 Page
    /// 4. 如果只剩最后一个 Page 的最后一个 Panel 的最后一个 Tab → 返回 .shouldCloseWindow
    ///
    /// - Returns: 关闭结果
    func handleSmartClose() -> SmartCloseResult {
        guard let panelId = activePanelId,
              let panel = terminalWindow.getPanel(panelId),
              let activeTabId = panel.activeTabId else {
            return .nothingToClose
        }

        // 1. 如果当前 Panel 有多个 Tab → 关闭当前 Tab
        if panel.tabCount > 1 {
            perform(.tab(.close(panelId: panelId, scope: .single(activeTabId))))
            return .closedTab
        }

        // 2. 如果当前 Page 有多个 Panel → 关闭当前 Panel
        if terminalWindow.panelCount > 1 {
            handleClosePanel(panelId: panelId)
            return .closedPanel
        }

        // 3. 如果当前 Window 有多个 Page → 关闭当前 Page
        if terminalWindow.pages.count > 1 {
            if let pageId = terminalWindow.active.pageId {
                let result = perform(.page(.close(scope: .single(pageId))))
                // activePanelId 通过 focusPublisher 自动同步
                return result.success ? .closedPage : .nothingToClose
            }
            return .nothingToClose
        }

        // 4. 只剩最后一个了，需要关闭当前窗口
        return .shouldCloseWindow
    }

    /// 关闭 Panel
    func handleClosePanel(panelId: UUID) {
        let result = perform(.panel(.close(panelId: panelId)))

        if result.success {
            // activePanelId 通过 focusPublisher 自动同步

            // 通知 View 层清除搜索绑定（如果是被关闭的 Panel）
            sendUIEvent(.clearSearchIfPanel(panelId: panelId))
        }
    }

    /// 用户添加 Tab
    func handleAddTab(panelId: UUID) {
        let result = perform(.tab(.add(panelId: panelId)))

        // Coordinator 特有状态：同步 activePanelId
        if result.success {
            setActivePanel(panelId)
        }
    }

    /// 用户分割 Panel
    func handleSplitPanel(panelId: UUID, direction: SplitDirection) {
        // 获取当前激活终端的 CWD（用于继承）
        var inheritedCwd: String? = nil
        if let panel = terminalWindow.getPanel(panelId),
           let activeTab = panel.activeTab,
           let terminalId = activeTab.rustTerminalId {
            inheritedCwd = getCwd(terminalId: Int(terminalId))
        }

        let result = perform(.panel(.split(panelId: panelId, direction: direction, cwd: inheritedCwd)))

        // Coordinator 特有状态：同步 activePanelId
        if result.success {
            // 从领域层获取新激活的 Panel ID
            if let newPanelId = terminalWindow.active.panelId {
                setActivePanel(newPanelId)
            }
        }
    }

    // MARK: - Tab Cross-Window Operations

    /// 移除 Tab（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - tabId: 要移除的 Tab ID
    ///   - panelId: 源 Panel ID
    ///   - closeTerminal: 是否关闭终端（跨窗口移动时为 false）
    /// - Returns: 是否成功
    @discardableResult
    func removeTab(_ tabId: UUID, from panelId: UUID, closeTerminal: Bool) -> Bool {
        let result = perform(.tab(.remove(tabId: tabId, panelId: panelId, closeTerminal: closeTerminal)))
        return result.success
    }

    /// 添加已有的 Tab 到指定 Panel（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - tab: 要添加的 Tab
    ///   - panelId: 目标 Panel ID
    func addTab(_ tab: Tab, to panelId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            return
        }

        panel.addTab(tab)
        _ = panel.setActiveTab(tab.tabId)

        // 设置为激活的 Panel
        setActivePanel(panelId)

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }

    // MARK: - Panel Navigation

    /// 向上导航到相邻 Panel
    func navigatePanelUp() {
        navigatePanel(direction: .up)
    }

    /// 向下导航到相邻 Panel
    func navigatePanelDown() {
        navigatePanel(direction: .down)
    }

    /// 向左导航到相邻 Panel
    func navigatePanelLeft() {
        navigatePanel(direction: .left)
    }

    /// 向右导航到相邻 Panel
    func navigatePanelRight() {
        navigatePanel(direction: .right)
    }

    /// Panel 导航统一入口
    ///
    /// - Parameter direction: 导航方向
    private func navigatePanel(direction: NavigationDirection) {
        guard let currentPanelId = activePanelId,
              let currentPage = terminalWindow.active.page else {
            return
        }

        // 获取容器尺寸（从 renderView 转换为 NSView）
        guard let renderViewAsNSView = renderView as? NSView else {
            return
        }

        let containerBounds = renderViewAsNSView.bounds

        // 使用导航服务查找目标 Panel
        guard let targetPanelId = PanelNavigationService.findNearestPanel(
            from: currentPanelId,
            direction: direction,
            in: currentPage,
            containerBounds: containerBounds
        ) else {
            // 没有找到目标 Panel，不执行任何操作
            return
        }

        // 切换到目标 Panel
        setActivePanel(targetPanelId)

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
    }

    // MARK: - Command Execution

    /// 执行窗口命令（统一入口）
    ///
    /// 所有 UI 操作的统一入口，负责：
    /// 1. 调用领域层执行命令
    /// 2. 处理终端生命周期（创建/关闭）
    /// 3. 处理终端激活/停用
    /// 4. 执行副作用（渲染、保存等）
    ///
    /// - Parameter command: 要执行的命令
    /// - Returns: 命令执行结果（用于 smartClose 判断是否需要关闭窗口）
    @discardableResult
    func perform(_ command: WindowCommand) -> CommandResult {
        // 1. 通过录制代理执行命令（自动录制事件）
        let result = recordingProxy.execute(command, on: terminalWindow)

        // 2. 处理错误
        guard result.success else {
            if let error = result.error {
                handleCommandError(error)
            }
            return result
        }

        // 3. 终端生命周期管理 - 关闭
        for terminalId in result.terminalsToClose {
            closeTerminalInternal(terminalId)
        }

        // 4. 终端生命周期管理 - 创建
        for spec in result.terminalsToCreate {
            createTerminalForSpec(spec)
        }

        // 5. 终端激活管理
        // 修复：在 split view 中，所有可见 Panel 的 active tab 都应该是 Active
        // 收集所有当前可见（active Page 中的所有 Panel）的 active tab
        let visibleTerminalIds = Set(terminalWindow.allPanels.compactMap { panel in
            panel.activeTab?.rustTerminalId
        })

        // 获取所有已创建的终端 ID（包括所有 Panel 的所有 Tab）
        let allTerminalIds = Set(terminalWindow.allPanels.flatMap { panel in
            panel.tabs.compactMap { $0.rustTerminalId }
        })

        // 可见的设为 Active，其他设为 Background
        for terminalId in visibleTerminalIds {
            terminalPool.setMode(terminalId: terminalId, mode: .active)
        }
        for terminalId in allTerminalIds.subtracting(visibleTerminalIds) {
            terminalPool.setMode(terminalId: terminalId, mode: .background)
        }

        // 5.1. 通知用户 focus 的终端
        if let focusedTerminalId = result.focusedTerminalId {
            NotificationCenter.default.post(
                name: .tabDidFocus,
                object: nil,
                userInfo: ["terminal_id": focusedTerminalId]
            )
        }

        // 5.5. Panel 移除后的 Coordinator 级别清理
        if let removedPanelId = result.removedPanelId {
            // 通知 View 层清除搜索绑定（如果是被关闭的 Panel）
            sendUIEvent(.clearSearchIfPanel(panelId: removedPanelId))
        }

        // 5.6. Page 移除后的冒泡处理（Page 变空 → 移除 Page）
        // 注：Window 变空的关闭由 WindowManager 层面处理（参考 movePage）
        if let removedPageId = result.removedPageId {
            // 从 TerminalWindow 移除空 Page
            _ = terminalWindow.pages.forceRemove(removedPageId)
        }

        // 6. 副作用处理
        applyEffects(result.effects)

        return result
    }

    /// 处理命令错误
    private func handleCommandError(_ error: CommandError) {
        switch error {
        case .cannotCloseLastTab, .cannotCloseLastPanel, .cannotCloseLastPage:
            // 这些是正常的边界情况，不需要特殊处理
            break
        case .tabNotFound(let id):
            print("[Coordinator] Tab not found: \(id)")
        case .panelNotFound(let id):
            print("[Coordinator] Panel not found: \(id)")
        case .pageNotFound(let id):
            print("[Coordinator] Page not found: \(id)")
        case .noActivePage:
            print("[Coordinator] No active page")
        case .noActivePanel:
            print("[Coordinator] No active panel")
        }
    }

    /// 应用副作用
    private func applyEffects(_ effects: CommandEffects) {
        if effects.syncLayout {
            syncLayoutToRust()
        }
        if effects.updateTrigger {
            objectWillChange.send()
            updateTrigger = UUID()
        }
        if effects.render {
            scheduleRender()
        }
        if effects.saveSession {
            WindowManager.shared.saveSession()
        }
    }
}

// MARK: - Recording Events

extension TerminalWindowCoordinator {

    /// 录制 Panel 事件
    func recordPanelEvent(_ event: SessionEvent) {
        recordingProxy.recordEvent(event)
    }

    /// 录制 Page 事件
    func recordPageEvent(_ event: SessionEvent) {
        recordingProxy.recordEvent(event)
    }
}
