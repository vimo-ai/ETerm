//
//  Tab.swift
//  ETerm
//
//  Tab 容器壳 - 通用 Tab 抽象
//
//  设计说明：
//  - Tab 是纯容器，不包含具体内容逻辑
//  - 内容由 TabContent 枚举承载
//  - 支持 Terminal、View 等多种内容类型
//

import Foundation
import PanelLayoutKit

/// Tab 容器（聚合根）
///
/// 职责：
/// - 管理 Tab 的通用属性（id、title、active 状态）
/// - 持有内容引用（TabContent）
/// - 不关心内容的具体类型
final class Tab {
    // MARK: - 基本属性

    /// Tab ID（唯一标识）
    let tabId: UUID

    /// Tab 标题
    private(set) var title: String

    /// Tab 状态（激活/未激活）
    private(set) var isActive: Bool

    /// Tab 内容
    private(set) var content: TabContent

    /// 插件设置的装饰（nil 表示无插件装饰）
    private(set) var decoration: TabDecoration?

    // MARK: - 初始化

    init(tabId: UUID = UUID(), title: String, content: TabContent) {
        self.tabId = tabId
        self.title = title
        self.isActive = false
        self.content = content
        self.decoration = nil
    }

    // MARK: - 装饰系统

    /// 有效装饰（综合 isActive 和插件装饰，取最高优先级）
    ///
    /// 优先级规则：
    /// - 0: 默认（灰色）
    /// - 5: 已完成（橙色）
    /// - 100: active（深红）
    /// - 101: 思考中（蓝色脉冲）
    var effectiveDecoration: TabDecoration {
        let activeDecoration = TabDecoration.active

        if let pluginDecoration = decoration {
            if isActive {
                // 有插件装饰且 active，取优先级高的
                return pluginDecoration.priority > activeDecoration.priority
                    ? pluginDecoration
                    : activeDecoration
            } else {
                // 有插件装饰但不 active
                return pluginDecoration
            }
        }

        // 无插件装饰
        return isActive ? activeDecoration : .default
    }

    /// 设置装饰（由插件调用）
    func setDecoration(_ newDecoration: TabDecoration?) {
        decoration = newDecoration
    }

    /// 清除装饰
    func clearDecoration() {
        guard decoration != nil else { return }
        decoration = nil
        NotificationCenter.default.post(
            name: .tabDecorationChanged,
            object: nil,
            userInfo: ["tabId": id]
        )
    }

    // MARK: - 状态管理

    /// 激活 Tab
    func activate() {
        isActive = true
        // 通知内容激活（如果内容需要响应）
        content.didActivate()
    }

    /// 失活 Tab
    func deactivate() {
        isActive = false
        // 通知内容失活（如果内容需要响应）
        content.didDeactivate()
    }

    /// 设置标题
    func setTitle(_ newTitle: String) {
        title = newTitle
    }

    // MARK: - 内容访问便捷方法

    /// 获取终端内容（如果是终端类型）
    var terminalContent: TerminalTabContent? {
        if case .terminal(let content) = content {
            return content
        }
        return nil
    }

    /// 获取视图内容（如果是视图类型）
    var viewContent: ViewTabContent? {
        if case .view(let content) = content {
            return content
        }
        return nil
    }

    /// 是否为终端 Tab
    var isTerminal: Bool {
        if case .terminal = content {
            return true
        }
        return false
    }

    /// 是否为视图 Tab
    var isView: Bool {
        if case .view = content {
            return true
        }
        return false
    }

    // MARK: - 终端便捷属性（兼容 TerminalTab 接口）

    /// Rust 终端 ID（仅终端 Tab 有效）
    var rustTerminalId: Int? {
        return terminalContent?.rustTerminalId
    }

    /// 设置 Rust 终端 ID（仅终端 Tab 有效）
    func setRustTerminalId(_ terminalId: Int?) {
        terminalContent?.setRustTerminalId(terminalId)
    }

    /// 设置待恢复的 CWD（仅终端 Tab 有效）
    func setPendingCwd(_ cwd: String) {
        terminalContent?.setPendingCwd(cwd)
    }

    /// 获取并清除待恢复的 CWD（仅终端 Tab 有效）
    func takePendingCwd() -> String? {
        return terminalContent?.takePendingCwd()
    }

    /// 搜索信息（仅终端 Tab 有效）
    var searchInfo: TabSearchInfo? {
        return terminalContent?.searchInfo
    }

    /// 设置搜索信息（仅终端 Tab 有效）
    func setSearchInfo(_ info: TabSearchInfo?) {
        terminalContent?.setSearchInfo(info)
    }

    /// 更新搜索索引（仅终端 Tab 有效）
    func updateSearchIndex(currentIndex: Int, totalCount: Int) {
        terminalContent?.updateSearchIndex(currentIndex: currentIndex, totalCount: totalCount)
    }

    /// 光标状态（仅终端 Tab 有效）
    var cursorState: CursorState? {
        return terminalContent?.cursorState
    }

    /// 文本选中（仅终端 Tab 有效）
    var textSelection: TextSelection? {
        return terminalContent?.textSelection
    }

    /// 输入状态（仅终端 Tab 有效）
    var inputState: InputState? {
        return terminalContent?.inputState
    }

    /// 显示偏移量（仅终端 Tab 有效）
    var displayOffset: Int {
        return terminalContent?.displayOffset ?? 0
    }

    /// 是否有选中文本（仅终端 Tab 有效）
    func hasSelection() -> Bool {
        return terminalContent?.hasSelection() ?? false
    }

    /// 清除选中（仅终端 Tab 有效）
    func clearSelection() {
        terminalContent?.clearSelection()
    }

    /// 开始选中（仅终端 Tab 有效）
    func startSelection(absoluteRow: Int64, col: UInt16) {
        terminalContent?.startSelection(absoluteRow: absoluteRow, col: col)
    }

    /// 更新选中（仅终端 Tab 有效）
    func updateSelection(absoluteRow: Int64, col: UInt16) {
        terminalContent?.updateSelection(absoluteRow: absoluteRow, col: col)
    }

    /// 更新显示偏移量（仅终端 Tab 有效）
    func updateDisplayOffset(_ newOffset: Int) {
        terminalContent?.updateDisplayOffset(newOffset)
    }

    /// 同步输入行（仅终端 Tab 有效）
    func syncInputRow(_ row: UInt16?) {
        terminalContent?.syncInputRow(row)
    }

    /// 更新光标位置（仅终端 Tab 有效）
    func updateCursorPosition(col: UInt16, row: UInt16) {
        terminalContent?.updateCursorPosition(col: col, row: row)
    }

    /// 隐藏光标（仅终端 Tab 有效）
    func hideCursor() {
        terminalContent?.hideCursor()
    }

    /// 显示光标（仅终端 Tab 有效）
    func showCursor() {
        terminalContent?.showCursor()
    }
}

// MARK: - Identifiable

extension Tab: Identifiable {
    var id: UUID { tabId }
}

// MARK: - Equatable

extension Tab: Equatable {
    static func == (lhs: Tab, rhs: Tab) -> Bool {
        lhs.tabId == rhs.tabId
    }
}

// MARK: - Hashable

extension Tab: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(tabId)
    }
}

// MARK: - CustomStringConvertible

extension Tab: CustomStringConvertible {
    var description: String {
        """
        Tab(
          id: \(tabId),
          title: "\(title)",
          active: \(isActive),
          content: \(content.contentTypeDescription)
        )
        """
    }
}
