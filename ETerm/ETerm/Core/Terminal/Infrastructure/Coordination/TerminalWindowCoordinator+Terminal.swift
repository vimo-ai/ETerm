//
//  TerminalWindowCoordinator+Terminal.swift
//  ETerm
//
//  MARK: - Terminal Lifecycle & FFI
//
//  职责：终端生命周期管理和 FFI 操作
//  - 创建/关闭终端
//  - 终端池管理
//  - 终端迁移（跨窗口）
//
//  注：查询方法已迁移到 +Query.swift
//

import Foundation
import AppKit
import Combine

// MARK: - Terminal Lifecycle

extension TerminalWindowCoordinator {

    /// 标记终端为 keepAlive
    ///
    /// 调用后，closeTerminalInternal 会 detach daemon session 而非 kill，
    /// daemon session 保留，后续可通过 reattach 恢复。
    func markTerminalKeepAlive(_ terminalId: Int) {
        terminalPool.markKeepAlive(terminalId)
    }

    /// 强制关闭终端（无视 keepAlive 标记，直接 kill daemon session）
    ///
    /// 先查找对应 tabId 以发射 DidClose 事件，再调用强制关闭。
    @discardableResult
    func closeTerminalForce(_ terminalId: Int) -> Bool {
        // 在关闭前查找 tabId（关闭后就找不到了）
        var tabId: String?
        for panel in terminalWindow.allPanels {
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                tabId = tab.tabId.uuidString
                break
            }
        }

        let success = terminalPool.closeTerminalForce(terminalId)

        if success {
            EventBus.shared.emit(CoreEvents.Terminal.DidClose(
                terminalId: terminalId,
                tabId: tabId
            ))
        }

        return success
    }

    /// 关闭终端（统一入口）
    @discardableResult
    func closeTerminalInternal(_ terminalId: Int) -> Bool {
        // 在关闭前查找 tabId（关闭后就找不到了）
        var tabId: String?
        for panel in terminalWindow.allPanels {
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                tabId = tab.tabId.uuidString
                break
            }
        }

        let success = terminalPool.closeTerminal(terminalId)

        // close 成功后再发射事件，避免 close 失败时误报
        if success {
            EventBus.shared.emit(CoreEvents.Terminal.DidClose(
                terminalId: terminalId,
                tabId: tabId
            ))
        }

        return success
    }

    /// 创建终端（统一入口）
    ///
    /// 如果有 initialCwd，则使用指定的工作目录创建第一个终端
    func createTerminalInternal(cols: UInt16, rows: UInt16, shell: String, cwd: String? = nil) -> Int {
        // 优先使用传入的 CWD
        var effectiveCwd = cwd

        // 如果没有传入 CWD，检查是否有 initialCwd（用于新窗口继承）
        if effectiveCwd == nil {
            effectiveCwd = initialCwd
        }

        // 如果有 CWD，使用 createTerminalWithCwd
        if let cwdPath = effectiveCwd {
            let terminalId = terminalPool.createTerminalWithCwd(cols: cols, rows: rows, shell: shell, cwd: cwdPath)

            if terminalId >= 0 {
                // 如果使用的是 initialCwd，清除它（只有第一个终端使用）
                if cwd == nil && initialCwd != nil {
                    initialCwd = nil
                }

                return terminalId
            }
            // 如果带 CWD 创建失败，继续走默认逻辑
        }

        // 默认行为：不指定 CWD
        return terminalPool.createTerminal(cols: cols, rows: rows, shell: shell)
    }

    /// 为 Tab 创建终端（使用 Tab 的 stableId）
    ///
    /// 用于确保重启后 Terminal ID 保持一致
    func createTerminalForTab(_ tab: Tab, cols: UInt16, rows: UInt16, cwd: String? = nil) -> Int {
        let stableId = tab.tabId.stableId

        // 优先使用传入的 CWD
        var effectiveCwd = cwd

        // 如果没有传入 CWD，检查是否有 initialCwd（用于新窗口继承）
        if effectiveCwd == nil {
            effectiveCwd = initialCwd
        }

        // 使用 stableId 创建终端
        let terminalId = terminalPool.createTerminalWithIdAndCwd(
            stableId,
            cols: cols,
            rows: rows,
            cwd: effectiveCwd
        )

        if terminalId >= 0 {
            // 如果使用的是 initialCwd，清除它（只有第一个终端使用）
            if cwd == nil && initialCwd != nil {
                initialCwd = nil
            }
        }

        return terminalId
    }

    /// 为 TerminalSpec 创建终端
    func createTerminalForSpec(_ spec: TerminalSpec) {
        // 查找 Tab
        var targetTab: Tab?
        for page in terminalWindow.pages.all {
            for panel in page.allPanels {
                if let tab = panel.tabs.first(where: { $0.tabId == spec.tabId }) {
                    targetTab = tab
                    break
                }
            }
            if targetTab != nil { break }
        }

        guard let tab = targetTab else { return }

        // 获取 CWD（从 spec 或继承）
        let cwd = spec.cwd ?? getActiveTabCwd()

        // 创建终端
        let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: cwd)
        if terminalId >= 0 {
            tab.setRustTerminalId(terminalId)

            // 注册到 CWD Registry
            if let effectiveCwd = cwd {
                workingDirectoryRegistry.registerActiveTerminal(
                    tabId: tab.tabId,
                    terminalId: terminalId,
                    workingDirectory: .inherited(path: effectiveCwd)
                )
            }

            // 激活新创建的终端
            terminalPool.setMode(terminalId: terminalId, mode: .active)
        }
    }

    /// 为所有 Tab 创建终端（只创建当前激活Page的终端）
    func createTerminalsForAllTabs() {
        ensureTerminalsForActivePage()
    }

    /// 确保指定Page的所有终端都已创建（延迟创建）
    func ensureTerminalsForPage(_ page: Page) {
        for (_, panel) in page.allPanels.enumerated() {
            for (_, tab) in panel.tabs.enumerated() {
                // 如果 Tab 还没有终端，创建一个
                if tab.rustTerminalId == nil {
                    // 从 Registry 查询 CWD（非破坏性，支持重试）
                    let cwd = workingDirectoryRegistry.queryWorkingDirectory(
                        tabId: tab.tabId,
                        terminalId: nil
                    )

                    // 使用 Tab 的 stableId 创建终端
                    let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: cwd.path)
                    if terminalId >= 0 {
                        tab.setRustTerminalId(terminalId)

                        // 如果是 Panel 的 activeTab，激活终端
                        if panel.activeTab?.tabId == tab.tabId {
                            terminalPool.setMode(terminalId: terminalId, mode: .active)
                        }

                        // 创建成功，迁移状态到 active
                        workingDirectoryRegistry.promotePendingTerminal(
                            tabId: tab.tabId,
                            terminalId: terminalId
                        )

                        // 发射终端创建事件
                        EventBus.shared.emit(CoreEvents.Terminal.DidCreate(
                            terminalId: terminalId,
                            tabId: tab.tabId.uuidString
                        ))
                    } else {
                        // 创建失败，保留状态供重试
                        workingDirectoryRegistry.retainPendingTerminal(tabId: tab.tabId)
                    }
                }
            }
        }
    }

    /// 确保当前激活Page的终端都已创建
    func ensureTerminalsForActivePage() {
        guard let activePage = terminalWindow.active.page else {
            return
        }
        ensureTerminalsForPage(activePage)
    }

    /// 处理终端关闭事件
    func handleTerminalClosed(terminalId: Int) {
        // 找到对应的 Tab 并关闭
        for panel in terminalWindow.allPanels {
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                handleTabClose(panelId: panel.panelId, tabId: tab.tabId)
                return
            }
        }
    }

    /// 处理 Bell 事件
    func handleBell(terminalId: Int) {
        // 播放系统提示音
        NSSound.beep()
    }

    /// 处理系统标题变更事件（由 TabTitleCoordinator 调用）
    ///
    /// 更新 Tab 的系统标题（目录名/进程名）
    func handleSystemTitleChange(terminalId: Int, title: String) {
        // 找到对应的 Tab 并更新系统标题
        for panel in terminalWindow.allPanels {
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                tab.updateSystemTitle(title)
                objectWillChange.send()
                updateTrigger = UUID()
                return
            }
        }
    }

    /// 处理插件标题清除事件（进程退出时由 TabTitleCoordinator 调用）
    ///
    /// 清除 Tab 的插件标题，恢复显示系统标题
    func handlePluginTitleClear(terminalId: Int) {
        // 找到对应的 Tab 并清除插件标题
        for panel in terminalWindow.allPanels {
            if let tab = panel.tabs.first(where: { $0.rustTerminalId == terminalId }) {
                tab.clearPluginTitle()
                objectWillChange.send()
                updateTrigger = UUID()
                return
            }
        }
    }
}

// MARK: - Terminal Pool Management

extension TerminalWindowCoordinator {

    /// 获取终端池（用于字体大小调整等操作）
    func getTerminalPool() -> TerminalPoolProtocol? {
        return terminalPool
    }

    /// 调整字体大小
    ///
    /// - Parameter operation: 字体大小操作（增大、减小、重置）
    func changeFontSize(operation: FontSizeOperation) {
        renderView?.changeFontSize(operation: operation)
    }

    /// 设置终端池（由 PanelRenderView 初始化后调用）
    func setTerminalPool(_ pool: TerminalPoolProtocol) {
        // 1. 捕获所有当前终端的 CWD（Pool 切换前）
        var tabIdMapping: [Int: UUID] = [:]
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    tabIdMapping[Int(terminalId)] = tab.tabId
                }
            }
        }
        workingDirectoryRegistry.captureBeforePoolTransition(tabIdMapping: tabIdMapping)

        // 2. 关闭旧终端池的所有终端，并清空 rustTerminalId
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    closeTerminalInternal(Int(terminalId))
                    tab.setRustTerminalId(nil)  // 清空 ID，准备重新分配
                }
            }
        }

        // 3. 切换到新终端池
        self.terminalPool = pool
        workingDirectoryRegistry.setTerminalPool(pool)

        // 4. 如果有待附加的分离终端，优先使用它们（跨窗口迁移场景）
        if !pendingDetachedTerminals.isEmpty {
            attachPendingDetachedTerminals()
        } else {
            // 否则创建新终端
            createTerminalsForAllTabs()
        }

        // 5. Pool 切换完成，恢复状态
        var newMapping: [UUID: Int] = [:]
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    newMapping[tab.tabId] = Int(terminalId)
                }
            }
        }
        workingDirectoryRegistry.restoreAfterPoolTransition(tabIdMapping: newMapping)

        // 初始化键盘系统
        self.keyboardSystem = KeyboardSystem(coordinator: self)

        // 初始化 Tab 标题自动更新协调器
        self.tabTitleCoordinator = TabTitleCoordinator(
            terminalPool: pool,
            onSystemTitleUpdate: { [weak self] terminalId, title in
                self?.handleSystemTitleChange(terminalId: terminalId, title: title)
            },
            onPluginTitleClear: { [weak self] terminalId in
                self?.handlePluginTitleClear(terminalId: terminalId)
            }
        )

        // 连接 TerminalPoolWrapper 的事件回调
        if let poolWrapper = pool as? TerminalPoolWrapper {
            poolWrapper.onCurrentDirectoryChanged = { [weak self] terminalId, cwd in
                self?.tabTitleCoordinator?.handleCurrentDirectoryChanged(terminalId: terminalId, cwd: cwd)
            }

            poolWrapper.onCommandExecuted = { [weak self] terminalId, command in
                self?.tabTitleCoordinator?.handleCommandExecuted(terminalId: terminalId, command: command)
            }
        }
    }

    /// 设置待附加的分离终端（跨窗口迁移时使用）
    ///
    /// 在创建新窗口时调用，这些终端会在 setTerminalPool 时被附加到新池
    func setPendingDetachedTerminals(_ terminals: [UUID: DetachedTerminalHandle]) {
        self.pendingDetachedTerminals = terminals
    }

    /// 附加所有待处理的分离终端
    func attachPendingDetachedTerminals() {
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                // 查找并附加分离的终端
                if let detached = pendingDetachedTerminals[tab.tabId] {
                    let newTerminalId = terminalPool.attachTerminal(detached)
                    if newTerminalId >= 0 {
                        tab.setRustTerminalId(newTerminalId)
                        // 通知注册表重新附加
                        workingDirectoryRegistry.reattachTerminal(
                            tabId: tab.tabId,
                            newTerminalId: newTerminalId
                        )
                    }
                } else {
                    // 如果没有找到分离的终端，创建新的
                    // 从 Registry 查询 CWD（非破坏性）
                    let cwd = workingDirectoryRegistry.queryWorkingDirectory(
                        tabId: tab.tabId,
                        terminalId: nil
                    )
                    let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: cwd.path)
                    if terminalId >= 0 {
                        tab.setRustTerminalId(terminalId)
                        // 创建成功，迁移状态
                        workingDirectoryRegistry.promotePendingTerminal(
                            tabId: tab.tabId,
                            terminalId: terminalId
                        )
                    } else {
                        // 创建失败，保留状态供重试
                        workingDirectoryRegistry.retainPendingTerminal(tabId: tab.tabId)
                    }
                }
            }
        }
        // 清空待附加列表
        pendingDetachedTerminals.removeAll()
    }
}

// MARK: - Terminal Migration (跨窗口移动)

extension TerminalWindowCoordinator {

    /// 分离终端（用于跨窗口迁移）
    ///
    /// - Parameter terminalId: 要分离的终端 ID
    /// - Returns: DetachedTerminalHandle，失败返回 nil
    func detachTerminal(_ terminalId: Int) -> DetachedTerminalHandle? {
        return terminalPool.detachTerminal(terminalId)
    }

    /// 附加分离的终端到 Page（用于跨窗口迁移）
    ///
    /// - Parameters:
    ///   - page: 目标 Page
    ///   - detachedTerminals: Tab ID 到分离终端的映射
    func attachTerminalsForPage(_ page: Page, detachedTerminals: [UUID: DetachedTerminalHandle]) {
        for panel in page.allPanels {
            for tab in panel.tabs {
                // 清除旧的终端 ID（它属于源窗口的 Pool）
                tab.setRustTerminalId(nil)

                // 查找并附加分离的终端
                if let detached = detachedTerminals[tab.tabId] {
                    let newTerminalId = terminalPool.attachTerminal(detached)
                    if newTerminalId >= 0 {
                        tab.setRustTerminalId(newTerminalId)
                    }
                }
            }
        }
    }

    /// 设置 reattach hint
    ///
    /// 下次 createTerminalForTab 时，优先 attach 到此 daemon session。
    func setReattachHint(_ sessionId: String) {
        terminalPool.setReattachHint(sessionId)
    }

    /// 查询终端关联的 daemon session ID
    func getDaemonSessionId(_ terminalId: Int) -> String? {
        terminalPool.getDaemonSessionId(terminalId)
    }

    /// 重建 Page 中所有 Tab 的终端（已废弃，使用 attachTerminalsForPage）
    ///
    /// 当 Page 从另一个窗口移动过来时，旧终端在源窗口的 Pool 中，
    /// 需要在当前窗口的 Pool 中重建终端。
    ///
    /// - Parameters:
    ///   - page: 要重建终端的 Page
    ///   - tabCwds: Tab ID 到 CWD 的映射
    func recreateTerminalsForPage(_ page: Page, tabCwds: [UUID: String]) {
        for panel in page.allPanels {
            for tab in panel.tabs {
                // 清除旧的终端 ID（它属于源窗口的 Pool）
                tab.setRustTerminalId(nil)

                // 获取 CWD
                let cwd = tabCwds[tab.tabId]

                // 使用 Tab 的 stableId 在当前窗口的 Pool 中创建新终端
                let terminalId = createTerminalForTab(tab, cols: 80, rows: 24, cwd: cwd)
                if terminalId >= 0 {
                    tab.setRustTerminalId(terminalId)
                }
            }
        }
    }
}
