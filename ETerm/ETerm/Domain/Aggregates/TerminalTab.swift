//
//  TerminalTab.swift
//  ETerm
//
//  领域聚合根 - 终端 Tab

import Foundation

/// 终端 Tab
///
/// 表示一个终端会话，包含元数据和状态
final class TerminalTab {
    let tabId: UUID
    private(set) var metadata: TabMetadata
    private(set) var state: TabState

    /// Tab 状态
    enum TabState {
        case active    // 激活状态
        case inactive  // 非激活状态
    }

    // MARK: - Initialization

    init(metadata: TabMetadata) {
        self.tabId = UUID()
        self.metadata = metadata
        self.state = .inactive
    }

    // MARK: - Public Methods

    /// 激活 Tab
    func activate() {
        state = .active
    }

    /// 取消激活 Tab
    func deactivate() {
        state = .inactive
    }

    /// 更新 Tab 标题
    func updateTitle(_ title: String) {
        metadata = metadata.withTitle(title)
    }

    /// 检查是否处于激活状态
    var isActive: Bool {
        state == .active
    }
}

// MARK: - Equatable

extension TerminalTab: Equatable {
    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool {
        lhs.tabId == rhs.tabId
    }
}

// MARK: - Hashable

extension TerminalTab: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(tabId)
    }
}
