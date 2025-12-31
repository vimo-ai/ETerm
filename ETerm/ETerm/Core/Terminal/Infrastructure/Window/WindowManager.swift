//
//  WindowManager.swift
//  ETerm
//
//  窗口管理器 - 管理多窗口生命周期
//
//  职责：
//  - 创建和销毁窗口
//  - 维护窗口列表
//  - 处理窗口间的协调
//  - 支持跨窗口 Page/Tab 拖动
//

import AppKit
import SwiftUI
import ETermKit

/// 窗口管理器（单例）
final class WindowManager: NSObject {
    static let shared = WindowManager()

    /// 所有打开的窗口
    private(set) var windows: [KeyableWindow] = []

    /// 窗口与 Coordinator 的映射（用于跨窗口操作）
    private var coordinators: [Int: TerminalWindowCoordinator] = [:]

    /// 默认窗口尺寸
    private let defaultSize = NSSize(width: 900, height: 650)

    /// Session 保存节流定时器
    private var saveDebounceTimer: Timer?
    /// Session 保存节流延迟（毫秒）
    private let saveDebounceDelay: TimeInterval = 0.5

    private override init() {
        super.init()
    }

    // MARK: - Coordinator 注册

    /// 注册窗口的 Coordinator
    ///
    /// - Parameters:
    ///   - coordinator: 窗口的 Coordinator
    ///   - window: 对应的窗口
    func registerCoordinator(_ coordinator: TerminalWindowCoordinator, for window: NSWindow) {
        coordinators[window.windowNumber] = coordinator
    }

    /// 注销窗口的 Coordinator
    func unregisterCoordinator(for window: NSWindow) {
        coordinators.removeValue(forKey: window.windowNumber)
    }

    /// 获取窗口的 Coordinator
    func getCoordinator(for windowNumber: Int) -> TerminalWindowCoordinator? {
        return coordinators[windowNumber]
    }

    /// 获取所有窗口的 windowNumber
    func getAllWindowNumbers() -> [Int] {
        return windows.map { $0.windowNumber }
    }

    /// 获取所有 Coordinator（用于跨窗口操作）
    func getAllCoordinators() -> [TerminalWindowCoordinator] {
        return Array(coordinators.values)
    }

    /// 根据屏幕位置查找窗口
    func findWindow(at screenPoint: NSPoint) -> KeyableWindow? {
        for window in windows {
            if window.frame.contains(screenPoint) {
                return window
            }
        }
        return nil
    }

    // MARK: - 窗口创建

    /// 创建新窗口（用于恢复 Session）
    ///
    /// - Parameters:
    ///   - windowState: 窗口状态（包含完整的 Pages/Panels/Tabs 布局）
    ///   - frame: 窗口位置和尺寸
    /// - Returns: 创建的窗口
    @discardableResult
    func createWindowWithState(windowState: WindowState, frame: NSRect) -> KeyableWindow {
        // 确定窗口的 frame
        let windowFrame: NSRect
        if let screenId = windowState.screenIdentifier {
            // 恢复模式：使用保存的位置和尺寸
            // 使用新的查找方法，同时传入保存的屏幕 frame 来验证（NSScreenNumber 可能变化）
            let targetScreen = SessionManager.findScreen(withIdentifier: screenId, savedFrame: windowState.screenFrame)
            logInfo("[WindowRestore] targetScreen: \(SessionManager.screenIdentifier(for: targetScreen)) frame=\(targetScreen.frame)")
            windowFrame = repositionFrameToScreen(frame, savedScreenFrame: windowState.screenFrame, targetScreen: targetScreen)
            logInfo("[WindowRestore] calculated windowFrame: \(windowFrame)")
        } else {
            windowFrame = frame
            logInfo("[WindowRestore] no screenId, using raw frame: \(windowFrame)")
        }

        let window = KeyableWindow.create(contentRect: windowFrame)
        logInfo("[WindowRestore] after create: window.frame=\(window.frame)")
        // macOS 可能会把窗口移到主屏幕，需要显式设置 frame
        window.setFrame(windowFrame, display: false)
        logInfo("[WindowRestore] after setFrame: window.frame=\(window.frame)")

        // 创建 Registry 和 TerminalWindow（从 WindowState 恢复完整结构）
        let registry = TerminalWorkingDirectoryRegistry()
        let terminalWindow = restoreTerminalWindow(from: windowState, registry: registry)
        let coordinator = TerminalWindowCoordinator(
            initialWindow: terminalWindow,
            workingDirectoryRegistry: registry
        )

        // 设置内容视图，传入 Coordinator
        let contentView = ContentView(coordinator: coordinator)
        let hostingView = NSHostingViewIgnoringSafeArea(rootView: contentView)
        window.contentView = hostingView

        // 重新配置圆角（因为替换了 contentView）
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true

        // 设置最小尺寸
        window.minSize = NSSize(width: 400, height: 300)

        // 监听窗口关闭
        window.delegate = self

        // 注册 Coordinator（在窗口有 windowNumber 之后）
        coordinators[window.windowNumber] = coordinator

        // 添加到列表
        windows.append(window)

        // 显示窗口
        window.makeKeyAndOrderFront(nil)
        logInfo("[WindowRestore] after makeKeyAndOrderFront: window.frame=\(window.frame) screen=\(window.screen.map { SessionManager.screenIdentifier(for: $0) } ?? "nil")")

        // macOS 可能在 makeKeyAndOrderFront 时把窗口移到当前 Space/屏幕，需要再次设置 frame
        if window.frame != windowFrame {
            logInfo("[WindowRestore] frame changed by system, restoring to: \(windowFrame)")
            window.setFrame(windowFrame, display: true)
        }

        return window
    }

    /// 从 WindowState 恢复 TerminalWindow
    ///
    /// - Parameters:
    ///   - windowState: 窗口状态
    ///   - registry: CWD 注册表，用于注册恢复的 CWD
    private func restoreTerminalWindow(from windowState: WindowState, registry: TerminalWorkingDirectoryRegistry) -> TerminalWindow {
        // 创建所有 Pages，并记录每个 Page 的 activePanelId
        var pages: [Page] = []
        var activePanelIdByPage: [UUID: UUID] = [:]

        for pageState in windowState.pages {
            // 创建空 Page（用于恢复）
            let page = Page.createEmptyForRestore(title: pageState.title)

            // 递归恢复 Panel 布局（传入 registry 以注册 CWD）
            if let restoredLayout = restorePanelLayout(pageState.layout, to: page, registry: registry) {
                // 设置恢复的布局到 Page
                page.setRootLayout(restoredLayout)

                // 记录 activePanelId（稍后设置到 TerminalWindow）
                if let activePanelId = UUID(uuidString: pageState.activePanelId),
                   page.getPanel(activePanelId) != nil {
                    activePanelIdByPage[page.pageId] = activePanelId
                }

                pages.append(page)
            }
        }

        // 创建 TerminalWindow
        guard let firstPage = pages.first else {
            // 如果恢复失败，创建一个默认的 TerminalWindow
            let initialTab = TerminalWindow.makeDefaultTab()
            let initialPanel = EditorPanel(initialTab: initialTab)
            return TerminalWindow(initialPanel: initialPanel)
        }

        let terminalWindow = TerminalWindow(initialPage: firstPage)

        // 添加其他 Pages
        for page in pages.dropFirst() {
            terminalWindow.pages.addExisting(page)
        }

        // 恢复每个 Page 的 activePanelId 到 TerminalWindow
        for (pageId, panelId) in activePanelIdByPage {
            // 临时切换到该 Page 来设置 activePanelId
            if terminalWindow.pages.switchTo(pageId) {
                terminalWindow.active.setPanel(panelId)
            }
        }

        // 切换到最终激活的 Page
        let activePageIndex = max(0, min(windowState.activePageIndex, pages.count - 1))
        let activePageId = pages[activePageIndex].pageId
        _ = terminalWindow.pages.switchTo(activePageId)

        // 恢复激活 Page 的 activePanelId
        if let activePanelId = activePanelIdByPage[activePageId] {
            terminalWindow.active.setPanel(activePanelId)
        }

        return terminalWindow
    }

    /// 递归恢复 Panel 布局
    ///
    /// - Parameters:
    ///   - layoutState: 布局状态
    ///   - page: 目标 Page
    ///   - registry: CWD 注册表，用于注册恢复的 CWD
    /// - Returns: 恢复后的 PanelLayout
    @discardableResult
    private func restorePanelLayout(_ layoutState: PanelLayoutState, to page: Page, registry: TerminalWorkingDirectoryRegistry) -> PanelLayout? {
        switch layoutState {
        case .leaf(_, let tabStates, let activeTabIndex):
            // 恢复叶子节点（Panel）
            // 创建所有 Tabs（此时还不创建终端，等 Coordinator 初始化后再创建）
            var tabs: [Tab] = []
            for tabState in tabStates {
                // 检查 Tab 内容类型
                switch tabState.resolvedContentType {
                case .terminal:
                    // 终端 Tab：创建 TerminalTab，包装为 Tab
                    let tabId = UUID(uuidString: tabState.tabId) ?? UUID()
                    let terminalTab = TerminalTab(tabId: tabId, title: tabState.title)
                    // 将 CWD 注册到 Registry（作为 Single Source of Truth）
                    registry.registerPendingTerminal(
                        tabId: tabId,
                        workingDirectory: .restored(path: tabState.cwd)
                    )
                    let tab = Tab(
                        tabId: tabId,
                        title: tabState.title,
                        content: .terminal(terminalTab),
                        userTitle: tabState.userTitle,
                        pluginTitle: tabState.pluginTitle  // 恢复插件设置的标题
                    )
                    tabs.append(tab)

                case .view:
                    // View Tab：恢复为 View Tab
                    guard let viewId = tabState.viewId else {
                        logWarn("View Tab 缺少 viewId，跳过: \(tabState.title)")
                        continue
                    }
                    let tabId = UUID(uuidString: tabState.tabId) ?? UUID()
                    let viewContent = ViewTabContent(
                        viewId: viewId,
                        pluginId: tabState.pluginId
                    )
                    let tab = Tab(
                        tabId: tabId,
                        title: tabState.title,
                        content: .view(viewContent),
                        userTitle: tabState.userTitle,
                        pluginTitle: tabState.pluginTitle  // 恢复插件设置的标题
                    )
                    tabs.append(tab)
                }
            }

            // 创建 Panel
            guard let firstTab = tabs.first else {
                return nil
            }

            let panel = EditorPanel(initialTab: firstTab)

            // 添加其他 Tabs
            for tab in tabs.dropFirst() {
                panel.addTab(tab)
            }

            // 设置激活的 Tab
            if activeTabIndex >= 0 && activeTabIndex < tabs.count {
                _ = panel.setActiveTab(tabs[activeTabIndex].tabId)
            }

            // 将 Panel 添加到 Page
            page.addExistingPanel(panel)

            return .leaf(panelId: panel.panelId)

        case .horizontal(let ratio, let first, let second):
            // 恢复水平分割（递归）
            guard let firstLayout = restorePanelLayout(first, to: page, registry: registry),
                  let secondLayout = restorePanelLayout(second, to: page, registry: registry) else {
                return nil
            }

            return .split(direction: .horizontal, first: firstLayout, second: secondLayout, ratio: ratio)

        case .vertical(let ratio, let first, let second):
            // 恢复垂直分割（递归）
            guard let firstLayout = restorePanelLayout(first, to: page, registry: registry),
                  let secondLayout = restorePanelLayout(second, to: page, registry: registry) else {
                return nil
            }

            return .split(direction: .vertical, first: firstLayout, second: secondLayout, ratio: ratio)
        }
    }

    /// 创建新窗口
    ///
    /// - Parameters:
    ///   - inheritCwd: 继承的工作目录（可选）
    ///   - frame: 窗口位置和尺寸（可选，用于恢复 session）
    ///   - screenIdentifier: 窗口所在屏幕标识符（可选，用于恢复 session）
    /// - Returns: 创建的窗口
    @discardableResult
    func createWindow(inheritCwd: String? = nil, frame: NSRect? = nil, screenIdentifier: String? = nil) -> KeyableWindow {
        // 确定窗口的 frame
        let windowFrame: NSRect
        if let savedFrame = frame, let screenId = screenIdentifier {
            // 恢复模式：使用保存的位置和尺寸
            let targetScreen = SessionManager.findScreen(withIdentifier: screenId)
            windowFrame = adjustFrameToScreen(savedFrame, screen: targetScreen)
        } else if let savedFrame = frame {
            // 只有 frame 没有屏幕信息，尝试使用 frame 所在的屏幕
            windowFrame = savedFrame
        } else {
            // 默认模式：计算新窗口位置
            windowFrame = calculateNewWindowFrame()
        }

        // 将 CWD 存入全局管理器（在创建 ContentView 之前）
        WindowCwdManager.shared.setPendingCwd(inheritCwd)

        let window = KeyableWindow.create(contentRect: windowFrame)

        // 🔑 关键：在 WindowManager 中创建 Coordinator，而不是在 SwiftUI 中
        let registry = TerminalWorkingDirectoryRegistry()
        let initialTab = TerminalWindow.makeDefaultTab()
        let initialPanel = EditorPanel(initialTab: initialTab)
        let terminalWindow = TerminalWindow(initialPanel: initialPanel)

        // 注册初始 Tab 的 CWD（继承自当前活动终端，如果有的话）
        if let cwd = inheritCwd {
            registry.registerPendingTerminal(
                tabId: initialTab.tabId,
                workingDirectory: .inherited(path: cwd)
            )
        } else {
            registry.registerPendingTerminal(
                tabId: initialTab.tabId,
                workingDirectory: .userHome()
            )
        }

        let coordinator = TerminalWindowCoordinator(
            initialWindow: terminalWindow,
            workingDirectoryRegistry: registry
        )

        // 设置内容视图，传入 Coordinator
        let contentView = ContentView(coordinator: coordinator)
        let hostingView = NSHostingViewIgnoringSafeArea(rootView: contentView)
        window.contentView = hostingView

        // 重新配置圆角（因为替换了 contentView）
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true

        // 设置最小尺寸
        window.minSize = NSSize(width: 400, height: 300)

        // 监听窗口关闭
        window.delegate = self

        // 🔑 注册 Coordinator（在窗口有 windowNumber 之后）
        // 注意：此时窗口还没显示，但 windowNumber 已经分配
        coordinators[window.windowNumber] = coordinator

        // 添加到列表
        windows.append(window)

        // 显示窗口
        window.makeKeyAndOrderFront(nil)

        return window
    }

    /// 重新定位窗口到目标屏幕
    ///
    /// 根据窗口在保存时屏幕上的相对位置，将窗口移动到目标屏幕的对应位置
    /// - Parameters:
    ///   - frame: 保存的窗口 frame（全局坐标）
    ///   - savedScreenFrame: 保存时屏幕的 frame
    ///   - targetScreen: 目标屏幕
    /// - Returns: 重新定位后的 frame
    private func repositionFrameToScreen(_ frame: NSRect, savedScreenFrame: CodableRect?, targetScreen: NSScreen) -> NSRect {
        let targetVisibleFrame = targetScreen.visibleFrame

        // 如果没有保存的屏幕信息，直接调整到目标屏幕
        guard let savedScreen = savedScreenFrame else {
            return adjustFrameToScreen(frame, screen: targetScreen)
        }

        let savedScreenRect = savedScreen.cgRect

        // 计算窗口在保存时屏幕上的相对位置（0-1）
        let relativeX = (frame.origin.x - savedScreenRect.origin.x) / savedScreenRect.width
        let relativeY = (frame.origin.y - savedScreenRect.origin.y) / savedScreenRect.height

        // 将相对位置应用到目标屏幕
        var newFrame = frame
        newFrame.origin.x = targetVisibleFrame.origin.x + relativeX * targetVisibleFrame.width
        newFrame.origin.y = targetVisibleFrame.origin.y + relativeY * targetVisibleFrame.height

        // 确保窗口在目标屏幕可见区域内
        return adjustFrameToScreen(newFrame, screen: targetScreen)
    }

    /// 调整窗口 frame 到指定屏幕
    ///
    /// 确保窗口完全在屏幕可见区域内
    /// - Parameters:
    ///   - frame: 原始窗口 frame
    ///   - screen: 目标屏幕
    /// - Returns: 调整后的 frame
    private func adjustFrameToScreen(_ frame: NSRect, screen: NSScreen) -> NSRect {
        let visibleFrame = screen.visibleFrame
        var adjustedFrame = frame

        // 确保窗口不超出屏幕右边界
        if adjustedFrame.maxX > visibleFrame.maxX {
            adjustedFrame.origin.x = visibleFrame.maxX - adjustedFrame.width
        }

        // 确保窗口不超出屏幕左边界
        if adjustedFrame.origin.x < visibleFrame.origin.x {
            adjustedFrame.origin.x = visibleFrame.origin.x
        }

        // 确保窗口不超出屏幕顶部
        if adjustedFrame.maxY > visibleFrame.maxY {
            adjustedFrame.origin.y = visibleFrame.maxY - adjustedFrame.height
        }

        // 确保窗口不超出屏幕底部
        if adjustedFrame.origin.y < visibleFrame.origin.y {
            adjustedFrame.origin.y = visibleFrame.origin.y
        }

        // 如果窗口太大，调整尺寸
        if adjustedFrame.width > visibleFrame.width {
            adjustedFrame.size.width = visibleFrame.width
        }
        if adjustedFrame.height > visibleFrame.height {
            adjustedFrame.size.height = visibleFrame.height
        }

        return adjustedFrame
    }

    /// 计算新窗口位置（级联效果）
    private func calculateNewWindowFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: defaultSize)
        }

        let screenFrame = screen.visibleFrame

        // 如果没有窗口，居中显示
        if windows.isEmpty {
            let x = screenFrame.midX - defaultSize.width / 2
            let y = screenFrame.midY - defaultSize.height / 2
            return NSRect(x: x, y: y, width: defaultSize.width, height: defaultSize.height)
        }

        // 有窗口时，级联偏移
        if let lastWindow = windows.last {
            let lastFrame = lastWindow.frame
            let offset: CGFloat = 30

            var newX = lastFrame.origin.x + offset
            var newY = lastFrame.origin.y - offset

            // 确保不超出屏幕
            if newX + defaultSize.width > screenFrame.maxX {
                newX = screenFrame.origin.x + 50
            }
            if newY < screenFrame.origin.y {
                newY = screenFrame.maxY - defaultSize.height - 50
            }

            return NSRect(x: newX, y: newY, width: defaultSize.width, height: defaultSize.height)
        }

        return NSRect(origin: .zero, size: defaultSize)
    }

    // MARK: - 窗口关闭

    /// 关闭指定窗口
    func closeWindow(_ window: KeyableWindow) {
        window.close()
        removeWindow(window)
    }

    /// 从列表中移除窗口
    private func removeWindow(_ window: KeyableWindow) {
        windows.removeAll { $0 === window }

        // 如果所有窗口都关闭了，退出应用（可选行为）
        if windows.isEmpty {
            // NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - 窗口查询

    /// 获取当前 key window
    var keyWindow: KeyableWindow? {
        windows.first { $0.isKeyWindow }
    }

    /// 窗口数量
    var windowCount: Int {
        windows.count
    }

    // MARK: - 跨窗口迁移（统一抽象）

    /// 创建新窗口的内部核心方法
    ///
    /// 所有跨窗口迁移（Tab/Panel/Page）最终都调用此方法。
    /// 调用方负责：分离终端、从源窗口移除实体、归一化为 Page。
    ///
    /// - Parameters:
    ///   - page: 已归一化的 Page（包含要迁移的内容）
    ///   - detachedTerminals: 已分离的终端映射 [tabId: handle]
    ///   - sourceCoordinator: 源窗口的 Coordinator（用于复制 CWD 状态）
    ///   - screenPoint: 新窗口的位置（屏幕坐标）
    /// - Returns: 新创建的窗口，失败返回 nil
    private func createWindowWithPageInternal(
        _ page: Page,
        detachedTerminals: [UUID: DetachedTerminalHandle],
        sourceCoordinator: TerminalWindowCoordinator,
        at screenPoint: NSPoint
    ) -> KeyableWindow? {
        // 1. 创建新窗口（使用指定位置，调整到合适的位置）
        let adjustedPoint = NSPoint(
            x: screenPoint.x - defaultSize.width / 2,
            y: screenPoint.y - defaultSize.height / 2
        )
        let frame = NSRect(origin: adjustedPoint, size: defaultSize)
        let window = KeyableWindow.create(contentRect: frame)

        // 2. 创建新 Coordinator，使用 Page 作为初始内容
        let registry = TerminalWorkingDirectoryRegistry()
        let terminalWindow = TerminalWindow(initialPage: page)

        // 从源 Coordinator 复制 CWD 状态到新 Registry
        for panel in page.allPanels {
            for tab in panel.tabs {
                let cwd = sourceCoordinator.getWorkingDirectory(
                    tabId: tab.tabId,
                    terminalId: tab.rustTerminalId.map { Int($0) }
                )
                // 注册为 detached 状态，等待 reattach
                registry.registerActiveTerminal(
                    tabId: tab.tabId,
                    terminalId: tab.rustTerminalId.map { Int($0) } ?? -1,
                    workingDirectory: cwd
                )
                if let terminalId = tab.rustTerminalId {
                    registry.detachTerminal(tabId: tab.tabId, terminalId: Int(terminalId))
                }
            }
        }

        let coordinator = TerminalWindowCoordinator(
            initialWindow: terminalWindow,
            workingDirectoryRegistry: registry
        )

        // 3. 设置待附加的终端（会在 setTerminalPool 时自动附加）
        coordinator.setPendingDetachedTerminals(detachedTerminals)

        // 4. 设置内容视图
        let contentView = ContentView(coordinator: coordinator)
        let hostingView = NSHostingViewIgnoringSafeArea(rootView: contentView)
        window.contentView = hostingView

        // 重新配置圆角
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true

        // 设置最小尺寸
        window.minSize = NSSize(width: 400, height: 300)

        // 监听窗口关闭
        window.delegate = self

        // 注册 Coordinator
        coordinators[window.windowNumber] = coordinator

        // 添加到列表
        windows.append(window)

        // 显示窗口
        window.makeKeyAndOrderFront(nil)

        // 保存 Session（新建窗口，需要备份）
        saveSessionWithBackup()

        return window
    }

    // MARK: - 跨窗口 Page 操作

    /// 创建新窗口（Page 拖出时使用）
    ///
    /// 跨窗口终端迁移：使用 detach/attach 保留 PTY 连接和终端历史
    ///
    /// - Parameters:
    ///   - page: 要移动的 Page
    ///   - sourceCoordinator: 源窗口的 Coordinator
    ///   - screenPoint: 新窗口的位置（屏幕坐标）
    /// - Returns: 新创建的窗口，失败返回 nil
    @discardableResult
    func createWindowWithPage(_ page: Page, from sourceCoordinator: TerminalWindowCoordinator, at screenPoint: NSPoint) -> KeyableWindow? {
        // 1. 分离所有终端（保持 PTY 连接活跃）
        var detachedTerminals: [UUID: DetachedTerminalHandle] = [:]
        for panel in page.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId,
                   let detached = sourceCoordinator.detachTerminal(Int(terminalId)) {
                    detachedTerminals[tab.tabId] = detached
                }
            }
        }

        // 2. 从源窗口移除 Page（不关闭终端，已经分离）
        guard let removedPage = sourceCoordinator.removePage(page.pageId, closeTerminals: false) else {
            // 如果失败，销毁已分离的终端
            for (_, detached) in detachedTerminals {
                TerminalPoolWrapper.destroyDetachedTerminal(detached)
            }
            return nil
        }

        // 3. 调用内部核心方法创建窗口
        return createWindowWithPageInternal(
            removedPage,
            detachedTerminals: detachedTerminals,
            sourceCoordinator: sourceCoordinator,
            at: screenPoint
        )
    }

    /// 移动 Page 到另一个窗口
    ///
    /// 跨窗口终端迁移：使用 detach/attach 保留 PTY 连接和终端历史
    ///
    /// - Parameters:
    ///   - pageId: 要移动的 Page ID
    ///   - sourceWindowNumber: 源窗口编号
    ///   - targetWindowNumber: 目标窗口编号
    ///   - insertBefore: 插入到指定 Page 之前（nil 表示插入到末尾）
    /// - Returns: 是否成功
    @discardableResult
    func movePage(_ pageId: UUID, from sourceWindowNumber: Int, to targetWindowNumber: Int, insertBefore targetPageId: UUID? = nil) -> Bool {
        guard let sourceCoordinator = coordinators[sourceWindowNumber],
              let targetCoordinator = coordinators[targetWindowNumber] else {
            return false
        }

        // 检查 Page 是否存在于源窗口
        guard let page = sourceCoordinator.terminalWindow.pages.all.first(where: { $0.pageId == pageId }) else {
            return false
        }

        // 1. 分离所有终端（保持 PTY 连接活跃）
        var detachedTerminals: [UUID: DetachedTerminalHandle] = [:]
        for panel in page.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId,
                   let detached = sourceCoordinator.detachTerminal(Int(terminalId)) {
                    detachedTerminals[tab.tabId] = detached
                }
            }
        }

        // 2. 从源窗口移除 Page（不关闭终端，已经分离）
        guard let removedPage = sourceCoordinator.removePage(pageId, closeTerminals: false) else {
            // 如果失败，销毁已分离的终端
            for (_, detached) in detachedTerminals {
                TerminalPoolWrapper.destroyDetachedTerminal(detached)
            }
            return false
        }

        // 3. 添加到目标窗口，传入分离的终端以重新附加
        targetCoordinator.addPage(removedPage, insertBefore: targetPageId, detachedTerminals: detachedTerminals)

        // 4. 如果源窗口没有 Page 了，关闭源窗口
        if sourceCoordinator.terminalWindow.pages.all.isEmpty {
            if let sourceWindow = windows.first(where: { $0.windowNumber == sourceWindowNumber }) {
                sourceWindow.close()
            }
        }

        // 5. 激活目标窗口
        if let targetWindow = windows.first(where: { $0.windowNumber == targetWindowNumber }) {
            targetWindow.makeKeyAndOrderFront(nil)
        }

        // 6. 保存 Session（跨窗口移动，需要备份）
        saveSessionWithBackup()

        return true
    }

    // MARK: - 跨窗口 Tab 操作

    /// 创建新窗口（Tab 拖出时使用）
    ///
    /// 跨窗口终端迁移：使用 detach/attach 保留 PTY 连接和终端历史。
    /// 内部归一化为 Page，复用统一的迁移逻辑。
    ///
    /// - Parameters:
    ///   - tab: 要移动的 Tab
    ///   - sourcePanelId: 源 Panel ID
    ///   - sourceCoordinator: 源窗口的 Coordinator
    ///   - screenPoint: 新窗口的位置（屏幕坐标）
    /// - Returns: 新创建的窗口，失败返回 nil
    @discardableResult
    func createWindowWithTab(_ tab: Tab, from sourcePanelId: UUID, sourceCoordinator: TerminalWindowCoordinator, at screenPoint: NSPoint) -> KeyableWindow? {
        // 1. 分离终端（保持 PTY 连接活跃）
        var detachedTerminals: [UUID: DetachedTerminalHandle] = [:]
        if let terminalId = tab.rustTerminalId,
           let detached = sourceCoordinator.detachTerminal(Int(terminalId)) {
            detachedTerminals[tab.tabId] = detached
        }

        // 2. 从源 Panel 移除 Tab（不关闭终端，已经分离）
        guard sourceCoordinator.removeTab(tab.tabId, from: sourcePanelId, closeTerminal: false) else {
            // 如果失败，销毁已分离的终端
            for (_, detached) in detachedTerminals {
                TerminalPoolWrapper.destroyDetachedTerminal(detached)
            }
            return nil
        }

        // 3. 归一化为 Page
        let page = Page.createFromTab(tab)

        // 4. 调用内部核心方法创建窗口
        return createWindowWithPageInternal(
            page,
            detachedTerminals: detachedTerminals,
            sourceCoordinator: sourceCoordinator,
            at: screenPoint
        )
    }

    /// 移动 Tab 到另一个窗口的指定 Panel
    ///
    /// 支持跨窗口终端迁移：终端会话保留，只更新路由表
    ///
    /// - Parameters:
    ///   - tabId: 要移动的 Tab ID
    ///   - sourcePanelId: 源 Panel ID
    ///   - sourceWindowNumber: 源窗口编号
    ///   - targetPanelId: 目标 Panel ID
    ///   - targetWindowNumber: 目标窗口编号
    /// - Returns: 是否成功
    @discardableResult
    func moveTab(_ tabId: UUID, from sourcePanelId: UUID, sourceWindowNumber: Int, to targetPanelId: UUID, targetWindowNumber: Int) -> Bool {
        guard let sourceCoordinator = coordinators[sourceWindowNumber],
              let targetCoordinator = coordinators[targetWindowNumber] else {
            return false
        }

        // 1. 获取 Tab 对象
        guard let sourcePanel = sourceCoordinator.terminalWindow.getPanel(sourcePanelId),
              let tab = sourcePanel.tabs.first(where: { $0.tabId == tabId }) else {
            return false
        }

        // 2. 验证目标 Panel 存在（防止 Tab 丢失）
        guard targetCoordinator.terminalWindow.getPanel(targetPanelId) != nil else {
            return false
        }

        // 3. 从源 Panel 移除（不关闭终端）
        guard sourceCoordinator.removeTab(tabId, from: sourcePanelId, closeTerminal: false) else {
            return false
        }

        // 4. 添加到目标 Panel
        targetCoordinator.addTab(tab, to: targetPanelId)

        // 5. 如果源窗口没有 Page 了，关闭源窗口
        if sourceCoordinator.terminalWindow.pages.all.isEmpty {
            if let sourceWindow = windows.first(where: { $0.windowNumber == sourceWindowNumber }) {
                sourceWindow.close()
            }
        }

        // 6. 激活目标窗口
        if let targetWindow = windows.first(where: { $0.windowNumber == targetWindowNumber }) {
            targetWindow.makeKeyAndOrderFront(nil)
        }

        // 7. 保存 Session（跨窗口移动，需要备份）
        saveSessionWithBackup()

        return true
    }

    // MARK: - Session 管理

    /// 捕获所有窗口的状态
    ///
    /// - Returns: 所有窗口的状态数组
    func captureAllWindowStates() -> [WindowState] {
        var windowStates: [WindowState] = []

        for window in windows {
            // 获取窗口的 Coordinator
            guard let coordinator = coordinators[window.windowNumber] else {
                continue
            }

            // 获取窗口位置和大小
            let frame = CodableRect(rect: window.frame)

            // 获取窗口所在的屏幕
            let screenIdentifier: String?
            let screenFrame: CodableRect?
            if let screen = window.screen {
                screenIdentifier = SessionManager.screenIdentifier(for: screen)
                screenFrame = CodableRect(rect: screen.frame)
            } else {
                screenIdentifier = nil
                screenFrame = nil
            }

            // 获取 TerminalWindow
            let terminalWindow = coordinator.terminalWindow

            // 捕获所有 Pages
            var pageStates: [PageState] = []
            for page in terminalWindow.pages.all {
                if let pageState = capturePageState(page: page, coordinator: coordinator) {
                    pageStates.append(pageState)
                }
            }

            // 确定激活的 Page 索引
            let activePageIndex = terminalWindow.pages.all.firstIndex { $0.pageId == terminalWindow.active.pageId } ?? 0

            // 创建窗口状态
            let windowState = WindowState(
                frame: frame,
                pages: pageStates,
                activePageIndex: activePageIndex,
                screenIdentifier: screenIdentifier,
                screenFrame: screenFrame
            )

            windowStates.append(windowState)
        }

        return windowStates
    }

    /// 捕获 Page 状态
    ///
    /// - Parameters:
    ///   - page: Page 对象
    ///   - coordinator: 窗口的 Coordinator（用于获取 CWD）
    /// - Returns: PageState，失败返回 nil
    private func capturePageState(page: Page, coordinator: TerminalWindowCoordinator) -> PageState? {
        // 捕获布局状态
        guard let layoutState = capturePanelLayoutState(
            layout: page.rootLayout,
            page: page,
            coordinator: coordinator
        ) else {
            return nil
        }

        // 确定激活的 Panel ID（从 TerminalWindow 获取，支持每个 Page 独立记录）
        let activePanelId = coordinator.terminalWindow.active.panelId(for: page.pageId)?.uuidString
            ?? page.allPanelIds.first?.uuidString ?? ""

        return PageState(
            title: page.title,
            layout: layoutState,
            activePanelId: activePanelId
        )
    }

    /// 递归捕获 PanelLayout 状态
    ///
    /// - Parameters:
    ///   - layout: PanelLayout 对象
    ///   - page: Page 对象（用于获取 Panel）
    ///   - coordinator: Coordinator（用于获取 CWD）
    /// - Returns: PanelLayoutState，失败返回 nil
    private func capturePanelLayoutState(
        layout: PanelLayout,
        page: Page,
        coordinator: TerminalWindowCoordinator
    ) -> PanelLayoutState? {
        switch layout {
        case .leaf(let panelId):
            // Leaf 节点 - 捕获 Tabs
            guard let panel = page.getPanel(panelId) else {
                return nil
            }

            var tabStates: [TabState] = []
            for tab in panel.tabs {
                let tabState: TabState

                switch tab.content {
                case .terminal:
                    // 终端 Tab：通过 Registry 获取 CWD（统一接口，支持所有状态）
                    let workingDirectory = coordinator.getWorkingDirectory(
                        tabId: tab.tabId,
                        terminalId: tab.rustTerminalId.map { Int($0) }
                    )
                    tabState = TabState(
                        tabId: tab.tabId.uuidString,
                        title: tab.systemTitle,  // 保存 systemTitle（非显示 title）
                        cwd: workingDirectory.path,
                        userTitle: tab.userTitle,
                        pluginTitle: tab.pluginTitle  // 保存插件设置的标题
                    )

                case .view(let viewContent):
                    // View Tab：保存 viewId 和 pluginId
                    tabState = TabState(
                        tabId: tab.tabId.uuidString,
                        title: tab.systemTitle,  // 保存 systemTitle（非显示 title）
                        viewId: viewContent.viewId,
                        pluginId: viewContent.pluginId,
                        userTitle: tab.userTitle,
                        pluginTitle: tab.pluginTitle  // 保存插件设置的标题
                    )
                }

                tabStates.append(tabState)
            }

            let activeTabIndex = panel.tabs.firstIndex { $0.tabId == panel.activeTabId } ?? 0

            return .leaf(
                panelId: panelId.uuidString,
                tabs: tabStates,
                activeTabIndex: activeTabIndex
            )

        case .split(let direction, let first, let second, let ratio):
            // Split 节点 - 递归处理子节点
            guard let firstState = capturePanelLayoutState(layout: first, page: page, coordinator: coordinator),
                  let secondState = capturePanelLayoutState(layout: second, page: page, coordinator: coordinator) else {
                return nil
            }

            // 根据方向选择对应的 case
            if direction == .horizontal {
                return .horizontal(ratio: ratio, first: firstState, second: secondState)
            } else {
                return .vertical(ratio: ratio, first: firstState, second: secondState)
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension WindowManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? KeyableWindow else { return }

        // 🔑 关键：先保存 Session，再移除窗口
        // 否则保存时窗口已经从列表移除，会保存空 Session
        saveSession()

        // 关键：在注销 Coordinator 之前，先调用 cleanup() 清理终端
        // 这样可以确保在对象开始释放之前完成清理
        if let coordinator = coordinators[window.windowNumber] {
            coordinator.cleanup()
        }

        unregisterCoordinator(for: window)
        removeWindow(window)

        // 🔑 关键：清除 delegate 引用，防止窗口释放后回调导致 crash
        // 参考: https://stackoverflow.com/questions/65116534
        window.delegate = nil

        // 清除 contentView，帮助释放 SwiftUI 视图层级
        window.contentView = nil
    }

    func windowDidMove(_ notification: Notification) {
        // 窗口移动时节流保存 session
        saveSessionDebounced()
    }

    func windowDidResize(_ notification: Notification) {
        // 窗口调整大小时节流保存 session
        saveSessionDebounced()
    }

    /// 节流保存 Session（延迟执行，合并频繁调用）
    ///
    /// 用于窗口移动/调整等高频操作，避免频繁写入磁盘
    private func saveSessionDebounced() {
        // 取消之前的定时器
        saveDebounceTimer?.invalidate()

        // 创建新的延迟定时器
        saveDebounceTimer = Timer.scheduledTimer(withTimeInterval: saveDebounceDelay, repeats: false) { [weak self] _ in
            self?.saveSession()
        }
    }

    /// 保存当前所有窗口的 session（立即执行，不创建备份）
    ///
    /// 用于位置调整等不需要备份的保存。
    /// 对于窗口移动/调整等高频操作，应使用 saveSessionDebounced()
    func saveSession() {
        // 取消待执行的节流保存（避免重复保存）
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil

        let windowStates = captureAllWindowStates()
        SessionManager.shared.save(windows: windowStates, createBackup: false)
    }

    /// 保存当前所有窗口的 session（立即执行，创建备份）
    ///
    /// 用于有意义的变化：新增/删除 tab/panel/page/window、应用关闭前等。
    func saveSessionWithBackup() {
        // 取消待执行的节流保存（避免重复保存）
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil

        let windowStates = captureAllWindowStates()
        SessionManager.shared.save(windows: windowStates, createBackup: true)
    }

    // MARK: - Tab 查找

    /// 根据 terminalId 查找对应的 tabId
    ///
    /// - Parameter terminalId: Rust 终端 ID
    /// - Returns: Tab 的 UUID string，找不到返回 nil
    func findTabId(for terminalId: Int) -> String? {
        for window in windows {
            guard let coordinator = coordinators[window.windowNumber] else { continue }
            for panel in coordinator.terminalWindow.allPanels {
                for tab in panel.tabs {
                    if tab.rustTerminalId == terminalId {
                        return tab.tabId.uuidString
                    }
                }
            }
        }
        return nil
    }
}
