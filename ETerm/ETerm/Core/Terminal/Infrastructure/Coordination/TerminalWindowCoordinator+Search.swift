//
//  TerminalWindowCoordinator+Search.swift
//  ETerm
//
//  MARK: - Terminal Search
//
//  职责：终端内文本搜索
//  - 开始/清除搜索
//  - 跳转到上一个/下一个匹配
//  - 搜索状态管理
//

import Foundation
import Combine
import PanelLayoutKit

// MARK: - Terminal Search (Tab-Level)

extension TerminalWindowCoordinator {

    /// 开始搜索（在指定 Panel 的当前 Tab 中）
    ///
    /// - Parameters:
    ///   - pattern: 搜索模式
    ///   - searchPanelId: 搜索绑定的 Panel ID（由 View 层传入）
    ///   - isRegex: 是否为正则表达式（暂不支持）
    ///   - caseSensitive: 是否区分大小写（暂不支持）
    func startSearch(pattern: String, searchPanelId: UUID?, isRegex: Bool = false, caseSensitive: Bool = false) {
        guard let searchPanelId = searchPanelId,
              let panel = terminalWindow.getPanel(searchPanelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId,
              let wrapper = terminalPool as? TerminalPoolWrapper else {
            return
        }

        // 调用 Rust 端搜索
        let matchCount = wrapper.search(terminalId: Int(terminalId), query: pattern)

        if matchCount > 0 {
            // 更新 Tab 的搜索信息
            let searchInfo = TabSearchInfo(
                pattern: pattern,
                totalCount: matchCount,
                currentIndex: 1  // 搜索后光标在第一个匹配
            )
            activeTab.setSearchInfo(searchInfo)
        } else {
            // 无匹配，清除搜索信息
            activeTab.setSearchInfo(nil)
        }

        // 触发 UI 更新（搜索框需要显示匹配数量）
        objectWillChange.send()

        // 搜索结果需要立即渲染，直接调用 requestRender() 而不是 scheduleRender()
        // scheduleRender() 有 16ms 防抖延迟，会导致高亮响应慢
        renderView?.requestRender()
    }

    /// 跳转到下一个匹配
    /// - Parameter searchPanelId: 搜索绑定的 Panel ID（由 View 层传入）
    func searchNext(searchPanelId: UUID?) {
        guard let searchPanelId = searchPanelId,
              let panel = terminalWindow.getPanel(searchPanelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId,
              let searchInfo = activeTab.searchInfo,
              let wrapper = terminalPool as? TerminalPoolWrapper else {
            return
        }

        // 调用 Rust 端跳转
        wrapper.searchNext(terminalId: Int(terminalId))

        // 更新索引（循环）
        let newIndex = searchInfo.currentIndex % searchInfo.totalCount + 1
        activeTab.updateSearchIndex(currentIndex: newIndex, totalCount: searchInfo.totalCount)

        // 触发 UI 更新（搜索框需要更新当前索引）
        objectWillChange.send()

        // 搜索导航需要立即响应，直接渲染
        renderView?.requestRender()
    }

    /// 跳转到上一个匹配
    /// - Parameter searchPanelId: 搜索绑定的 Panel ID（由 View 层传入）
    func searchPrev(searchPanelId: UUID?) {
        guard let searchPanelId = searchPanelId,
              let panel = terminalWindow.getPanel(searchPanelId),
              let activeTab = panel.activeTab,
              let terminalId = activeTab.rustTerminalId,
              let searchInfo = activeTab.searchInfo,
              let wrapper = terminalPool as? TerminalPoolWrapper else {
            return
        }

        // 调用 Rust 端跳转
        wrapper.searchPrev(terminalId: Int(terminalId))

        // 更新索引（循环）
        let newIndex = searchInfo.currentIndex > 1 ? searchInfo.currentIndex - 1 : searchInfo.totalCount
        activeTab.updateSearchIndex(currentIndex: newIndex, totalCount: searchInfo.totalCount)

        // 触发 UI 更新（搜索框需要更新当前索引）
        objectWillChange.send()

        // 搜索导航需要立即响应，直接渲染
        renderView?.requestRender()
    }

    /// 清除指定 Panel 的搜索
    /// - Parameter searchPanelId: 搜索绑定的 Panel ID（由 View 层传入）
    func clearSearch(searchPanelId: UUID?) {
        // 清除搜索（如果存在）
        if let searchPanelId = searchPanelId,
           let panel = terminalWindow.getPanel(searchPanelId),
           let activeTab = panel.activeTab {
            // 调用 Rust 端清除搜索
            if let terminalId = activeTab.rustTerminalId,
               let wrapper = terminalPool as? TerminalPoolWrapper {
                wrapper.clearSearch(terminalId: Int(terminalId))
            }
            // 清除 Tab 的搜索信息
            activeTab.setSearchInfo(nil)
        }

        // 触发 UI 更新
        objectWillChange.send()

        // 清除搜索高亮需要立即生效
        renderView?.requestRender()
    }

    /// 切换搜索框显示状态（通过 UIEvent 通知 View 层）
    func toggleTerminalSearch() {
        // 发送 UIEvent 通知 View 层切换搜索状态
        if let panelId = activePanelId {
            sendUIEvent(.toggleSearch(panelId: panelId))
        }
    }
}
