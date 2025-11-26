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

/// 窗口管理器（单例）
final class WindowManager: NSObject {
    static let shared = WindowManager()

    /// 所有打开的窗口
    private(set) var windows: [KeyableWindow] = []

    /// 窗口与 Coordinator 的映射（用于跨窗口操作）
    private var coordinators: [Int: TerminalWindowCoordinator] = [:]

    /// 默认窗口尺寸
    private let defaultSize = NSSize(width: 900, height: 650)

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

    /// 创建新窗口
    ///
    /// - Parameter inheritCwd: 继承的工作目录（可选）
    @discardableResult
    func createWindow(inheritCwd: String? = nil) -> KeyableWindow {
        let frame = calculateNewWindowFrame()

        print("🏗️ [WindowManager] createWindow called with CWD: \(inheritCwd ?? "nil")")
        // 将 CWD 存入全局管理器（在创建 ContentView 之前）
        WindowCwdManager.shared.setPendingCwd(inheritCwd)
        print("✅ [WindowManager] Set pending CWD: \(inheritCwd ?? "nil")")

        let window = KeyableWindow.create(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .miniaturizable, .closable]
        )

        // 🔑 关键：在 WindowManager 中创建 Coordinator，而不是在 SwiftUI 中
        let initialTab = TerminalTab(tabId: UUID(), title: "终端 1")
        let initialPanel = EditorPanel(initialTab: initialTab)
        let terminalWindow = TerminalWindow(initialPanel: initialPanel)
        let coordinator = TerminalWindowCoordinator(initialWindow: terminalWindow)

        // 设置内容视图，传入 Coordinator
        let contentView = ContentView(coordinator: coordinator)
        let hostingView = NSHostingView(rootView: contentView)
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

    // MARK: - 跨窗口 Page 操作

    /// 创建新窗口（Page 拖出时使用）
    ///
    /// 第一阶段简化实现：
    /// - 从源窗口移除 Page（关闭终端）
    /// - 创建新窗口（新终端）
    /// - 注：终端会话不保留，后续可优化
    ///
    /// - Parameters:
    ///   - page: 要移动的 Page（用于判断是否应该移除）
    ///   - sourceCoordinator: 源窗口的 Coordinator
    ///   - screenPoint: 新窗口的位置（屏幕坐标）
    /// - Returns: 新创建的窗口，失败返回 nil
    @discardableResult
    func createWindowWithPage(_ page: Page, from sourceCoordinator: TerminalWindowCoordinator, at screenPoint: NSPoint) -> KeyableWindow? {
        // 1. 从源窗口移除 Page（关闭终端 - 第一阶段简化）
        _ = sourceCoordinator.removePage(page.pageId, closeTerminals: true)

        // 2. 创建新窗口（使用指定位置，调整到合适的位置）
        let adjustedPoint = NSPoint(
            x: screenPoint.x - defaultSize.width / 2,
            y: screenPoint.y - defaultSize.height / 2
        )
        let frame = NSRect(origin: adjustedPoint, size: defaultSize)
        let window = KeyableWindow.create(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .miniaturizable, .closable]
        )

        // 🔑 在 WindowManager 中创建 Coordinator
        let initialTab = TerminalTab(tabId: UUID(), title: "终端 1")
        let initialPanel = EditorPanel(initialTab: initialTab)
        let terminalWindow = TerminalWindow(initialPanel: initialPanel)
        let coordinator = TerminalWindowCoordinator(initialWindow: terminalWindow)

        // 3. 设置内容视图，传入 Coordinator
        let contentView = ContentView(coordinator: coordinator)
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        // 重新配置圆角
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true

        // 设置最小尺寸
        window.minSize = NSSize(width: 400, height: 300)

        // 监听窗口关闭
        window.delegate = self

        // 🔑 注册 Coordinator
        coordinators[window.windowNumber] = coordinator

        // 添加到列表
        windows.append(window)

        // 显示窗口
        window.makeKeyAndOrderFront(nil)

        return window
    }

    /// 移动 Page 到另一个窗口
    ///
    /// 支持跨窗口终端迁移：所有终端会话保留，只更新路由表
    ///
    /// - Parameters:
    ///   - pageId: 要移动的 Page ID
    ///   - sourceWindowNumber: 源窗口编号
    ///   - targetWindowNumber: 目标窗口编号
    /// - Returns: 是否成功
    @discardableResult
    func movePage(_ pageId: UUID, from sourceWindowNumber: Int, to targetWindowNumber: Int) -> Bool {
        guard let sourceCoordinator = coordinators[sourceWindowNumber],
              let targetCoordinator = coordinators[targetWindowNumber] else {
            return false
        }

        // 1. 收集 Page 中所有终端 ID
        var terminalIds: [Int] = []
        if let page = sourceCoordinator.terminalWindow.pages.first(where: { $0.pageId == pageId }) {
            for panel in page.allPanels {
                for tab in panel.tabs {
                    if let terminalId = tab.rustTerminalId {
                        terminalIds.append(Int(terminalId))
                    }
                }
            }
        }

        // 2. 从源窗口移除 Page（不关闭终端）
        guard let page = sourceCoordinator.removePage(pageId, closeTerminals: false) else {
            return false
        }

        // 3. 批量迁移终端路由到目标 Coordinator
        if !terminalIds.isEmpty {
            GlobalTerminalManager.shared.migrateTerminals(terminalIds, to: targetCoordinator)
        }

        // 4. 添加到目标窗口
        targetCoordinator.addPage(page)

        // 5. 激活目标窗口
        if let targetWindow = windows.first(where: { $0.windowNumber == targetWindowNumber }) {
            targetWindow.makeKeyAndOrderFront(nil)
        }

        return true
    }

    // MARK: - 跨窗口 Tab 操作

    /// 创建新窗口（Tab 拖出时使用）
    ///
    /// 第一阶段简化实现：
    /// - 从源 Panel 移除 Tab（关闭终端）
    /// - 创建新窗口（新终端）
    /// - 注：终端会话不保留，后续可优化
    ///
    /// - Parameters:
    ///   - tab: 要移动的 Tab
    ///   - sourcePanelId: 源 Panel ID
    ///   - sourceCoordinator: 源窗口的 Coordinator
    ///   - screenPoint: 新窗口的位置（屏幕坐标）
    /// - Returns: 新创建的窗口，失败返回 nil
    @discardableResult
    func createWindowWithTab(_ tab: TerminalTab, from sourcePanelId: UUID, sourceCoordinator: TerminalWindowCoordinator, at screenPoint: NSPoint) -> KeyableWindow? {
        // 1. 从源 Panel 移除 Tab（关闭终端 - 第一阶段简化）
        guard sourceCoordinator.removeTab(tab.tabId, from: sourcePanelId, closeTerminal: true) else {
            return nil
        }

        // 2. 创建新窗口（使用指定位置，调整到合适的位置）
        let adjustedPoint = NSPoint(
            x: screenPoint.x - defaultSize.width / 2,
            y: screenPoint.y - defaultSize.height / 2
        )
        let frame = NSRect(origin: adjustedPoint, size: defaultSize)
        let window = KeyableWindow.create(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .miniaturizable, .closable]
        )

        // 🔑 在 WindowManager 中创建 Coordinator
        let initialTab = TerminalTab(tabId: UUID(), title: "终端 1")
        let initialPanel = EditorPanel(initialTab: initialTab)
        let terminalWindow = TerminalWindow(initialPanel: initialPanel)
        let coordinator = TerminalWindowCoordinator(initialWindow: terminalWindow)

        // 3. 设置内容视图，传入 Coordinator
        let contentView = ContentView(coordinator: coordinator)
        let hostingView = NSHostingView(rootView: contentView)
        window.contentView = hostingView

        // 重新配置圆角
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true

        // 设置最小尺寸
        window.minSize = NSSize(width: 400, height: 300)

        // 监听窗口关闭
        window.delegate = self

        // 🔑 注册 Coordinator
        coordinators[window.windowNumber] = coordinator

        // 添加到列表
        windows.append(window)

        // 显示窗口
        window.makeKeyAndOrderFront(nil)

        return window
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

        // 1. 获取 Tab 对象和终端 ID
        guard let sourcePanel = sourceCoordinator.terminalWindow.getPanel(sourcePanelId),
              let tab = sourcePanel.tabs.first(where: { $0.tabId == tabId }) else {
            return false
        }

        let terminalId = tab.rustTerminalId

        // 2. 从源 Panel 移除（不关闭终端）
        guard sourceCoordinator.removeTab(tabId, from: sourcePanelId, closeTerminal: false) else {
            return false
        }

        // 3. 迁移终端路由到目标 Coordinator
        if let terminalId = terminalId {
            GlobalTerminalManager.shared.migrateTerminal(Int(terminalId), to: targetCoordinator)
        }

        // 4. 添加到目标 Panel
        targetCoordinator.addTab(tab, to: targetPanelId)

        // 5. 激活目标窗口
        if let targetWindow = windows.first(where: { $0.windowNumber == targetWindowNumber }) {
            targetWindow.makeKeyAndOrderFront(nil)
        }

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

            // 获取 TerminalWindow
            let terminalWindow = coordinator.terminalWindow

            // 捕获所有 Pages
            var pageStates: [PageState] = []
            for page in terminalWindow.pages {
                if let pageState = capturePageState(page: page, coordinator: coordinator) {
                    pageStates.append(pageState)
                }
            }

            // 确定激活的 Page 索引
            let activePageIndex = terminalWindow.pages.firstIndex { $0.pageId == terminalWindow.activePageId } ?? 0

            // 创建窗口状态
            let windowState = WindowState(
                frame: frame,
                pages: pageStates,
                activePageIndex: activePageIndex
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

        // 确定激活的 Panel ID
        let activePanelId = coordinator.activePanelId?.uuidString ?? page.allPanelIds.first?.uuidString ?? ""

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
                // 获取 CWD
                var cwd = NSHomeDirectory()  // 默认值
                if let terminalId = tab.rustTerminalId,
                   let actualCwd = coordinator.getCwd(terminalId: Int(terminalId)) {
                    cwd = actualCwd
                }

                let tabState = TabState(title: tab.title, cwd: cwd)
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
}
