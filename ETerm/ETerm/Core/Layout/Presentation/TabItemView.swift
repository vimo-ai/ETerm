//
//  TabItemView.swift
//  ETerm
//
//  单个 Tab 的视图
//
//  继承 DraggableItemView，对应 Golden Layout 的 Tab 元素
//  支持：
//  - 点击切换激活状态
//  - 拖拽移动 Tab
//  - 关闭 Tab
//

import AppKit
import SwiftUI
import Foundation

/// 单个 Tab 的视图
///
/// 显示 Tab 的标题和关闭按钮，支持点击和拖拽操作
final class TabItemView: DraggableItemView {
    // MARK: - 属性

    /// Tab ID
    let tabId: UUID

    override var itemId: UUID { tabId }

    /// 所属 Panel ID（用于拖拽数据）
    var panelId: UUID?

    /// 所属 Page 是否激活
    private var isPageActive: Bool = true

    /// Rust Terminal ID（用于 Claude 响应匹配）
    var rustTerminalId: Int?

    /// Tab 前缀 emoji（如 📱 表示 Mobile 正在查看）
    private var emoji: String?

    // MARK: - 初始化

    init(tabId: UUID, title: String) {
        self.tabId = tabId

        super.init(frame: .zero)

        setTitle(title)
        setupUI()
        setupClaudeNotifications()
        setupVlaudeNotifications()
    }

    // 注意：macOS 10.11+ 会自动移除 NotificationCenter 观察者
    // 不需要在 deinit 中手动 removeObserver

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// 设置所属 Page 是否激活
    func setPageActive(_ active: Bool) {
        isPageActive = active
        // Page 激活状态变化不需要重新渲染视图，只影响通知逻辑
    }

    /// 设置 emoji
    func setEmoji(_ emoji: String?) {
        self.emoji = emoji
        updateItemView()
    }

    // MARK: - 子类实现

    override var editFieldFontSize: CGFloat { 26 * 0.4 }
    override var editFieldHeight: CGFloat { 20 }

    /// Tab 拖拽结束时发送通知（DropIntentQueue 依赖此通知）
    override var dragSessionEndedNotificationName: Notification.Name? { .tabDragSessionEnded }

    override func updateItemView() {
        // 移除旧的 hostingView
        hostingView?.removeFromSuperview()

        // 创建新的 SwiftUI 视图
        let simpleTab = SimpleTabView(
            title,
            emoji: emoji,
            isActive: isActive,
            needsAttention: needsAttention,
            height: Self.tabHeight,
            isHovered: isHovered,
            onClose: { [weak self] in
                self?.onClose?()
            }
        )

        let hosting = NSHostingView(rootView: simpleTab)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting

        // 确保编辑框在最上层
        bringEditFieldToFront()
    }

    override func createPasteboardData() -> String {
        // 格式：tab:{windowNumber}:{panelId}:{tabId}
        let windowNumber = window?.windowNumber ?? 0
        let panelIdString = panelId?.uuidString ?? ""
        return "tab:\(windowNumber):\(panelIdString):\(tabId.uuidString)"
    }

    // MARK: - Layout

    /// SimpleTabView 的固定高度
    private static let tabHeight: CGFloat = 26

    override var fittingSize: NSSize {
        return hostingView?.fittingSize ?? .zero
    }

    override var intrinsicContentSize: NSSize {
        return hostingView?.intrinsicContentSize ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Private Methods

    private func setupUI() {
        updateItemView()
    }
}

// MARK: - Drag Session Notification

extension Notification.Name {
    /// Tab 拖拽 session 结束通知
    static let tabDragSessionEnded = Notification.Name("tabDragSessionEnded")
}

/// 全局 drag 锁，用于防止在 UI 更新期间启动新的 drag
/// 当 drag session 结束后，需要等待 UI 更新完成才能开始新的 drag
final class DragLock {
    static let shared = DragLock()
    private init() {}

    /// 是否锁定新 drag
    private(set) var isLocked: Bool = false

    /// 锁定 drag（在 drop 处理后调用）
    func lock() {
        isLocked = true
    }

    /// 解锁 drag（在 UI 更新完成后调用）
    func unlock() {
        isLocked = false
    }
}

// MARK: - Claude Notification Handling

extension TabItemView {
    /// 设置 Claude 通知监听
    private func setupClaudeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClaudeResponseComplete(_:)),
            name: .claudeResponseComplete,
            object: nil
        )
    }

    @objc private func handleClaudeResponseComplete(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let terminalId = userInfo["terminal_id"] as? Int else {
            return
        }

        // 检查是否是当前 Tab 的 terminal
        guard let myTerminalId = rustTerminalId, myTerminalId == terminalId else {
            return
        }

        // 如果 Tab 已激活 且 Page 也激活，不需要提醒
        if isActive && isPageActive {
            return
        }

        // 设置需要注意状态（不自动消失，只有用户点击才消失）
        setNeedsAttention(true)
    }
}

// MARK: - Vlaude Notification Handling

extension TabItemView {
    /// 设置 Vlaude 通知监听
    private func setupVlaudeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMobileViewingChanged(_:)),
            name: .vlaudeMobileViewingChanged,
            object: nil
        )
    }

    @objc private func handleMobileViewingChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let terminalId = userInfo["terminal_id"] as? Int,
              let isViewing = userInfo["is_viewing"] as? Bool else {
            return
        }

        // 检查是否是当前 Tab 的 terminal
        guard let myTerminalId = rustTerminalId, myTerminalId == terminalId else {
            return
        }

        setEmoji(isViewing ? "📱" : nil)
    }
}
