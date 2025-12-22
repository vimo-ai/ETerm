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

    /// 关联的 Tab 模型（弱引用，用于读取 effectiveDecoration）
    weak var tab: Tab?

    /// 所属 Panel ID（用于拖拽数据）
    var panelId: UUID?

    /// 所属 Page 是否激活
    private var isPageActive: Bool = true

    /// Rust Terminal ID（用于装饰通知匹配）
    var rustTerminalId: Int?

    /// Tab 前缀 emoji（如 📱 表示 Mobile 正在查看）
    private var emoji: String?

    // MARK: - 宽度计算

    /// 缓存的宽度（由 TabWidthCalculator 计算）
    private var cachedWidth: CGFloat = TabWidthCalculator.minWidth

    /// 冻结的宽度（拖拽期间使用）
    private var frozenWidth: CGFloat?

    /// 当前 slot 宽度（由插件设置）
    private var slotWidth: CGFloat = 0

    /// 实际使用的宽度（拖拽时用冻结值，否则用缓存值）
    private var effectiveWidth: CGFloat {
        frozenWidth ?? cachedWidth
    }

    // MARK: - 初始化

    init(tabId: UUID, title: String, tab: Tab? = nil) {
        self.tabId = tabId
        self.tab = tab

        super.init(frame: .zero)

        // 先设置 title，再计算宽度
        // 注意：不能只依赖 setTitle，因为如果 title 是空字符串会 early return
        setTitle(title)
        recalculateWidth()  // 强制计算宽度
        setupUI()
        setupDecorationNotifications()
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

    // MARK: - 子类实现

    override var editFieldFontSize: CGFloat { 26 * 0.4 }
    override var editFieldHeight: CGFloat { 20 }

    /// Tab 拖拽结束时发送通知（DropIntentQueue 依赖此通知）
    override var dragSessionEndedNotificationName: Notification.Name? { .tabDragSessionEnded }

    /// 标题变化时重新计算宽度
    override func titleDidChange() {
        recalculateWidth()
    }

    /// 拖拽开始时冻结宽度
    override func dragSessionWillStart() {
        freezeWidth()
    }

    /// 拖拽结束时解冻宽度
    override func dragSessionDidEnd() {
        unfreezeWidth()
    }

    override func updateItemView() {
        // 编辑期间不重建视图，避免焦点丢失
        guard !isEditing else { return }

        // 从 Tab 模型读取装饰，计算要显示的装饰
        // 优先级逻辑：
        // - 插件装饰 priority > 100（active）：显示插件装饰
        // - 否则如果 isActive：不传 decoration，让 SimpleTabView 用 active 样式
        // - 否则如果有插件装饰：显示插件装饰
        var displayDecoration: TabDecoration? = nil
        if let pluginDecoration = tab?.decoration {
            if pluginDecoration.priority > 100 {
                // 插件装饰优先级高于 active（如思考中 priority=101）
                displayDecoration = pluginDecoration
            } else if !isActive {
                // 插件装饰优先级低于 active，但当前不是 active
                displayDecoration = pluginDecoration
            }
            // 否则 displayDecoration = nil，SimpleTabView 用 active 样式
        }

        // 获取插件注册的 slot 视图
        let slotViews: [AnyView]
        if let terminalId = rustTerminalId {
            slotViews = TabSlotRegistry.shared.getSlotViews(for: terminalId)
            // 更新 slot 宽度用于宽度计算
            let newSlotWidth = TabSlotRegistry.shared.estimateSlotWidth(for: terminalId)
            if slotWidth != newSlotWidth {
                slotWidth = newSlotWidth
                recalculateWidth()
            }
        } else {
            slotViews = []
        }

        // 移除旧的 hostingView
        hostingView?.removeFromSuperview()

        // 创建新的 SwiftUI 视图（使用动态宽度）
        let simpleTab = SimpleTabView(
            title,
            isActive: isActive,
            decoration: displayDecoration,
            width: effectiveWidth,
            height: Self.tabHeight,
            isHovered: isHovered,
            slotViews: slotViews,
            onClose: { [weak self] in
                self?.onClose?()
            },
            onCloseOthers: { [weak self] in
                self?.onCloseOthers?()
            },
            onCloseLeft: { [weak self] in
                self?.onCloseLeft?()
            },
            onCloseRight: { [weak self] in
                self?.onCloseRight?()
            },
            canCloseLeft: canCloseLeft,
            canCloseRight: canCloseRight,
            canCloseOthers: canCloseOthers
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
        // 使用预计算的宽度，不依赖 SwiftUI 的 fittingSize
        return NSSize(width: effectiveWidth, height: Self.tabHeight)
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: effectiveWidth, height: Self.tabHeight)
    }

    // MARK: - 宽度管理

    /// 重新计算宽度（title 变化时调用）
    func recalculateWidth() {
        cachedWidth = TabWidthCalculator.shared.calculate(
            title: title,
            slotWidth: slotWidth
        )
    }

    /// 冻结当前宽度（拖拽开始时调用）
    func freezeWidth() {
        frozenWidth = cachedWidth
    }

    /// 解冻宽度（拖拽结束后调用）
    func unfreezeWidth() {
        frozenWidth = nil
    }

    /// 设置 slot 宽度（插件调用）
    func setSlotWidth(_ width: CGFloat) {
        guard slotWidth != width else { return }
        slotWidth = width
        recalculateWidth()
        updateItemView()
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

// MARK: - Tab 装饰通知处理（通用机制）

extension TabItemView {
    /// 设置装饰通知监听
    ///
    /// 监听 tabDecorationChanged 通知，由插件通过 PluginContext.ui.setTabDecoration() 发送。
    /// 核心层不知道具体是哪个插件发送的，只负责渲染。
    private func setupDecorationNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDecorationChanged(_:)),
            name: .tabDecorationChanged,
            object: nil
        )
    }

    @objc private func handleDecorationChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo else {
            return
        }

        // 支持两种匹配方式：
        // 1. terminal_id（插件通过 PluginContext.ui.setTabDecoration 设置时）
        // 2. tabId（Tab.clearDecoration 清除时）
        if let terminalId = userInfo["terminal_id"] as? Int {
            guard let myTerminalId = rustTerminalId, myTerminalId == terminalId else {
                return
            }
        } else if let notificationTabId = userInfo["tabId"] as? UUID {
            guard notificationTabId == tabId else {
                return
            }
        } else {
            return
        }

        // Tab 模型已更新，刷新视图即可（updateItemView 会从模型读取装饰）
        updateItemView()
    }
}

// MARK: - Tab Slot 通知处理

extension TabItemView {
    /// 设置 Slot 通知监听
    private func setupSlotNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSlotChanged(_:)),
            name: TabSlotRegistry.slotDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleSlotChanged(_ notification: Notification) {
        // Slot 注册变化，刷新视图
        updateItemView()
    }
}
