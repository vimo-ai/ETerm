//
//  TerminalWindowCoordinator+Page.swift
//  ETerm
//
//  MARK: - Page Management
//
//  职责：Page 生命周期管理
//  - 创建/关闭/切换 Page
//  - Page 重命名/重排序
//  - 跨窗口 Page 移动
//  - Page 拖拽处理
//

import Foundation
import AppKit
import Combine
import ETermKit

// MARK: - Page Lifecycle

extension TerminalWindowCoordinator {

    /// 创建新 Page
    ///
    /// - Parameter title: 页面标题（可选）
    /// - Returns: 新创建的 Page ID
    @discardableResult
    func createPage(title: String? = nil) -> UUID? {
        // 获取当前激活终端的 CWD（用于继承）
        var inheritedCwd: String? = nil
        if let terminalId = getActiveTerminalId() {
            inheritedCwd = getCwd(terminalId: Int(terminalId))
        }

        let result = perform(.page(.create(title: title, cwd: inheritedCwd)))

        guard result.success else {
            return nil
        }

        // activePanelId 通过 focusPublisher 自动同步

        // 返回新创建的 Page ID（执行后是当前激活的 Page）
        return terminalWindow.active.pageId
    }

    /// 切换到指定 Page
    ///
    /// - Parameter pageId: 目标 Page ID
    /// - Returns: 是否成功切换
    @discardableResult
    func switchToPage(_ pageId: UUID) -> Bool {
        // 录制事件
        let fromPageId = terminalWindow.active.pageId
        recordPageEvent(.pageSwitch(fromPageId: fromPageId, toPageId: pageId))

        // 执行命令（处理旧终端停用、同步布局、渲染等副作用）
        let result = perform(.page(.switch(to: .specific(pageId))))
        guard result.success else { return false }

        // 延迟创建终端（Lazy Loading，内部会激活新创建的 activeTab 终端）
        if let activePage = terminalWindow.active.page {
            ensureTerminalsForPage(activePage)
        }

        // activePanelId 通过 focusPublisher 自动同步

        return true
    }

    /// 关闭当前 Page（供快捷键调用）
    ///
    /// - Returns: 是否成功关闭
    @discardableResult
    func closeCurrentPage() -> Bool {
        guard let activePageId = terminalWindow.active.page?.pageId else {
            return false
        }
        return closePage(activePageId)
    }

    /// 关闭指定 Page
    ///
    /// - Parameter pageId: 要关闭的 Page ID
    /// - Returns: 是否成功关闭
    @discardableResult
    func closePage(_ pageId: UUID) -> Bool {
        // 录制事件
        recordPageEvent(.pageClose(pageId: pageId))

        // 执行命令（处理终端关闭、新 Page 终端激活、副作用等）
        let result = perform(.page(.close(scope: .single(pageId))))
        guard result.success else {
            return false
        }

        // activePanelId 通过 focusPublisher 自动同步

        return true
    }

    /// 关闭其他 Page（保留指定的 Page）
    func handlePageCloseOthers(keepPageId: UUID) {
        perform(.page(.close(scope: .others(keep: keepPageId))))
    }

    /// 关闭左侧 Page
    func handlePageCloseLeft(fromPageId: UUID) {
        perform(.page(.close(scope: .left(of: fromPageId))))
    }

    /// 关闭右侧 Page
    func handlePageCloseRight(fromPageId: UUID) {
        perform(.page(.close(scope: .right(of: fromPageId))))
    }

    /// 重命名 Page
    ///
    /// - Parameters:
    ///   - pageId: Page ID
    ///   - newTitle: 新标题
    /// - Returns: 是否成功
    @discardableResult
    func renamePage(_ pageId: UUID, to newTitle: String) -> Bool {
        // 获取旧标题用于录制
        let oldTitle = terminalWindow.pages.all.first(where: { $0.pageId == pageId })?.title ?? ""

        guard terminalWindow.pages.rename(pageId, to: newTitle) else {
            return false
        }

        // 录制事件
        recordPageEvent(.pageRename(pageId: pageId, oldTitle: oldTitle, newTitle: newTitle))

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()

        // 保存 Session
        WindowManager.shared.saveSession()

        return true
    }

    /// 重新排序 Pages
    ///
    /// - Parameter pageIds: 新的 Page ID 顺序
    /// - Returns: 是否成功
    @discardableResult
    func reorderPages(_ pageIds: [UUID]) -> Bool {
        perform(.page(.reorder(order: pageIds))).success
    }

    /// 切换到下一个 Page
    @discardableResult
    func switchToNextPage() -> Bool {
        guard terminalWindow.pages.switchToNext() else {
            return false
        }

        // activePanelId 通过 focusPublisher 自动同步

        // 同步布局到 Rust（Page 切换）
        syncLayoutToRust()

        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return true
    }

    /// 切换到上一个 Page
    @discardableResult
    func switchToPreviousPage() -> Bool {
        guard terminalWindow.pages.switchToPrevious() else {
            return false
        }

        // activePanelId 通过 focusPublisher 自动同步

        // 同步布局到 Rust（Page 切换）
        syncLayoutToRust()

        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return true
    }
}

// MARK: - Cross-Window Page Operations

extension TerminalWindowCoordinator {

    /// 移除 Page（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - pageId: 要移除的 Page ID
    ///   - closeTerminals: 是否关闭终端（跨窗口移动时为 false）
    /// - Returns: 被移除的 Page，失败返回 nil
    func removePage(_ pageId: UUID, closeTerminals: Bool) -> Page? {
        // 获取要移除的 Page
        guard let page = terminalWindow.pages.all.first(where: { $0.pageId == pageId }) else {
            return nil
        }

        // 如果需要关闭终端
        if closeTerminals {
            for panel in page.allPanels {
                for tab in panel.tabs {
                    if let terminalId = tab.rustTerminalId {
                        closeTerminalInternal(Int(terminalId))
                    }
                }
            }
        }

        // 从 TerminalWindow 移除 Page（使用 forceRemovePage 允许移除最后一个 Page）
        guard let removedPage = terminalWindow.pages.forceRemove(pageId) else {
            return nil
        }

        // activePanelId 通过 focusPublisher 自动同步

        // 如果还有其他 Page，确保新激活 Page 的终端设置为 Active 模式
        // （与 closePage 相同的修复）
        if let newPage = terminalWindow.active.page {
            for panel in newPage.allPanels {
                if let activeTab = panel.activeTab, let terminalId = activeTab.rustTerminalId {
                    terminalPool.setMode(terminalId: Int(terminalId), mode: .active)
                }
            }
        }

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        return removedPage
    }

    /// 添加已有的 Page（用于跨窗口移动）
    ///
    /// - Parameters:
    ///   - page: 要添加的 Page
    ///   - insertBefore: 插入到指定 Page 之前（nil 表示插入到末尾）
    ///   - tabCwds: Tab ID 到 CWD 的映射（用于跨窗口移动时重建终端，已废弃）
    ///   - detachedTerminals: Tab ID 到分离终端的映射（用于真正的终端迁移）
    func addPage(_ page: Page, insertBefore targetPageId: UUID? = nil, tabCwds: [UUID: String]? = nil, detachedTerminals: [UUID: DetachedTerminalHandle]? = nil) {
        if let targetId = targetPageId {
            // 插入到指定位置
            terminalWindow.pages.addExisting(page, insertBefore: targetId)
        } else {
            // 添加到末尾
            terminalWindow.pages.addExisting(page)
        }

        // 优先使用终端迁移（保留 PTY 连接和历史）
        if let terminals = detachedTerminals {
            attachTerminalsForPage(page, detachedTerminals: terminals)
        } else if let cwds = tabCwds {
            // 回退到重建终端（会丢失历史）
            recreateTerminalsForPage(page, tabCwds: cwds)
        }

        // 切换到新添加的 Page
        _ = terminalWindow.pages.switchTo(page.pageId)

        // activePanelId 通过 focusPublisher 自动同步

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()
    }
}

// MARK: - Page Drag & Drop

extension TerminalWindowCoordinator {

    /// 处理 Page 重排序（同窗口内）
    ///
    /// - Parameters:
    ///   - draggedPageId: 被拖拽的 Page ID
    ///   - targetPageId: 目标 Page ID（插入到该 Page 之前）
    /// - Returns: 是否成功
    @discardableResult
    func handlePageReorder(draggedPageId: UUID, targetPageId: UUID) -> Bool {
        perform(.page(.move(pageId: draggedPageId, before: targetPageId))).success
    }

    /// 处理 Page 移动到末尾（同窗口内）
    ///
    /// - Parameter pageId: 要移动的 Page ID
    /// - Returns: 是否成功
    @discardableResult
    func handlePageMoveToEnd(pageId: UUID) -> Bool {
        perform(.page(.moveToEnd(pageId: pageId))).success
    }

    /// 处理从其他窗口接收 Page（跨窗口拖拽）
    ///
    /// - Parameters:
    ///   - pageId: 被拖拽的 Page ID
    ///   - sourceWindowNumber: 源窗口编号
    ///   - targetWindowNumber: 目标窗口编号
    ///   - insertBefore: 插入到指定 Page 之前（nil 表示插入到末尾）
    func handlePageReceivedFromOtherWindow(_ pageId: UUID, sourceWindowNumber: Int, targetWindowNumber: Int, insertBefore targetPageId: UUID?) {
        WindowManager.shared.movePage(
            pageId,
            from: sourceWindowNumber,
            to: targetWindowNumber,
            insertBefore: targetPageId
        )
    }

    /// 处理 Page 拖出窗口（创建新窗口）
    ///
    /// - Parameters:
    ///   - pageId: 被拖拽的 Page ID
    ///   - screenPoint: 屏幕坐标
    func handlePageDragOutOfWindow(_ pageId: UUID, at screenPoint: NSPoint) {
        // 检查是否拖到了其他窗口
        if WindowManager.shared.findWindow(at: screenPoint) != nil {
            // 拖到了其他窗口，由 dropDestination 处理
            return
        }

        // 拖出了所有窗口，创建新窗口
        guard let page = terminalWindow.pages.all.first(where: { $0.pageId == pageId }) else {
            return
        }

        // 在新窗口位置创建窗口
        WindowManager.shared.createWindowWithPage(page, from: self, at: screenPoint)
    }
}
