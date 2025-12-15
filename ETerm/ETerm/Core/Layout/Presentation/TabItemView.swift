//
//  TabItemView.swift
//  ETerm
//
//  单个 Tab 的视图
//
//  对应 Golden Layout 的 Tab 元素。
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
/// 显示 Tab 的标题和关闭按钮，支持点击和拖拽操作。
final class TabItemView: NSView {
    // MARK: - 属性

    /// Tab ID
    let tabId: UUID

    /// 标题
    private var title: String

    /// 是否激活
    private var isActive: Bool = false

    /// 所属 Page 是否激活
    private var isPageActive: Bool = true

    /// SwiftUI 简约标签视图
    private var hostingView: NSHostingView<SimpleTabView>?

    /// 是否正在拖拽
    private var isDragging: Bool = false

    /// 是否真正发生了拖动（鼠标移动）
    private var didActuallyDrag: Bool = false

    /// Rust Terminal ID（用于 Claude 响应匹配）
    var rustTerminalId: Int?

    /// Claude 响应完成提醒状态
    private var needsAttention: Bool = false

    /// Tab 前缀 emoji（如 📱 表示 Mobile 正在查看）
    private var emoji: String?

    /// 是否鼠标悬停
    private var isHovered: Bool = false

    // MARK: - 回调

    /// 点击回调
    var onTap: (() -> Void)?

    /// 开始拖拽回调
    var onDragStart: (() -> Void)?

    /// 关闭回调
    var onClose: (() -> Void)?

    /// 重命名回调
    var onRename: ((String) -> Void)?

    /// 拖出窗口回调（屏幕坐标）
    var onDragOutOfWindow: ((NSPoint) -> Void)?

    /// 所属 Panel ID（用于拖拽数据）
    var panelId: UUID?

    // MARK: - 编辑相关

    /// 编辑框
    private lazy var editField: NSTextField = {
        let field = NSTextField()
        field.font = .systemFont(ofSize: 26 * 0.4)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.isHidden = true
        field.delegate = self
        return field
    }()

    /// 是否正在编辑
    private var isEditing: Bool = false

    /// 是否已获得焦点
    private var hasFocused: Bool = false

    // MARK: - 初始化

    init(tabId: UUID, title: String) {
        self.tabId = tabId
        self.title = title

        super.init(frame: .zero)

        setupUI()
        setupGestures()
        setupClaudeNotifications()
        setupVlaudeNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// 设置激活状态
    func setActive(_ active: Bool) {
        isActive = active
        updateCyberView()
    }

    /// 设置所属 Page 是否激活
    func setPageActive(_ active: Bool) {
        isPageActive = active
        // Page 激活状态变化不需要重新渲染视图，只影响通知逻辑
    }

    /// 更新标题
    func setTitle(_ newTitle: String) {
        title = newTitle
        updateCyberView()
    }

    /// 设置 emoji
    func setEmoji(_ emoji: String?) {
        self.emoji = emoji
        updateCyberView()
    }

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true

        // 创建赛博标签视图
        updateCyberView()

        // 添加编辑框
        addSubview(editField)
    }

    private func setupGestures() {
        // 拖拽通过 mouseDown 启动，不需要手势识别器
    }

    private func updateCyberView() {
        // 移除旧的 hostingView
        hostingView?.removeFromSuperview()

        // 创建新的 SwiftUI 视图（传入外部控制的 isHovered 状态）
        // 必须显式使用 onClose: 标签，因为 trailing closure 会匹配最后一个参数 onDoubleTap
        let simpleTab = SimpleTabView(title, emoji: emoji, isActive: isActive, needsAttention: needsAttention, height: 26, isHovered: isHovered, onClose: { [weak self] in
            self?.onClose?()
        })

        let hosting = NSHostingView(rootView: simpleTab)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        hostingView = hosting

        // 确保编辑框在最上层
        if editField.superview != nil {
            editField.removeFromSuperview()
            addSubview(editField)
        }
    }

    /// 开始编辑标题
    private func startEditing() {
        isEditing = true
        editField.stringValue = title
        editField.isHidden = false
        hostingView?.isHidden = true

        // 布局编辑框
        let padding: CGFloat = 8
        editField.frame = CGRect(
            x: padding,
            y: (bounds.height - 20) / 2,
            width: bounds.width - padding * 2,
            height: 20
        )

        // 延迟获取焦点
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isEditing else { return }
            self.editField.selectText(nil)
            if self.window?.makeFirstResponder(self.editField) == true {
                self.hasFocused = true
            }
        }
    }

    /// 结束编辑标题
    private func endEditing(save: Bool) {
        guard isEditing else { return }
        isEditing = false
        hasFocused = false

        if save {
            let newTitle = editField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newTitle.isEmpty && newTitle != title {
                title = newTitle
                updateCyberView()
                // 通知父视图重新布局（tabContainer -> PanelHeaderView）
                superview?.superview?.needsLayout = true
                onRename?(newTitle)
            }
        }

        editField.isHidden = true
        hostingView?.isHidden = false
    }

    // MARK: - Layout

    override var fittingSize: NSSize {
        return hostingView?.fittingSize ?? .zero
    }

    override var intrinsicContentSize: NSSize {
        return hostingView?.intrinsicContentSize ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()

        // 更新 hostingView 的 frame
        hostingView?.frame = bounds
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 移除旧的 tracking area
        trackingAreas.forEach { removeTrackingArea($0) }

        // 添加新的 tracking area
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateCyberView()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateCyberView()
    }

    // MARK: - Event Handlers

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 检查点击是否在 bounds 内
        guard bounds.contains(point) else {
            return nil
        }

        // 关闭按钮在右侧约 30px 区域
        // 直接返回 hostingView，让 NSHostingView 处理 SwiftUI Button 事件
        let closeButtonArea: CGFloat = 30
        if point.x > bounds.width - closeButtonArea {
            return hostingView
        }

        // 其他区域返回自己，让 TabItemView 处理点击/拖拽
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // 重置拖拽标志
        isDragging = false
        didActuallyDrag = false

        // 不立即启动拖拽，等待 mouseDragged 确认真正拖动
    }

    override func mouseDragged(with event: NSEvent) {
        // 如果已经在拖拽中，不重复启动
        if isDragging {
            return
        }

        // 检查全局 drag 锁（防止在 UI 更新期间启动新 drag）
        if DragLock.shared.isLocked {
            return
        }

        // 标记真正发生了拖动
        didActuallyDrag = true
        isDragging = true

        // 现在才启动拖拽会话
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setDataProvider(self, forTypes: [.string])

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: createSnapshot())

        onDragStart?()

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        // 如果正在编辑，不处理
        guard !isEditing else {
            super.mouseUp(with: event)
            return
        }

        // 只有在没有真正拖动时才处理点击
        if !didActuallyDrag {
            if event.clickCount == 2 {
                // 双击：开始编辑
                startEditing()
            } else if event.clickCount == 1 {
                // 单击：切换 Tab
                onTap?()
            }
            // 重置拖拽状态并直接返回，不传递事件
            isDragging = false
            didActuallyDrag = false
            return
        }

        // 重置拖拽状态
        isDragging = false
        didActuallyDrag = false

        super.mouseUp(with: event)
    }

    // MARK: - 拖拽预览

    /// 创建拖拽预览图像
    private func createSnapshot() -> NSImage {
        // 使用 PDF 数据创建快照
        let pdfData = dataWithPDF(inside: bounds)
        return NSImage(data: pdfData) ?? NSImage()
    }

}

// MARK: - NSDraggingSource

extension TabItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 允许在窗口外部移动（用于创建新窗口）
        return context == .outsideApplication ? .move : .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {

        // 重置拖拽状态（确保在拖放源上也能正确重置）
        isDragging = false
        didActuallyDrag = false

        // 捕获需要的值（因为 self 可能在回调后被销毁）
        let capturedTabId = tabId
        let capturedOnDragOutOfWindow = onDragOutOfWindow
        let capturedOperation = operation
        let capturedScreenPoint = screenPoint

        // 延迟通知到下一个 runloop 迭代
        // 这确保 AppKit 有机会完成其内部清理，再触发我们的 UI 更新
        // 不使用 asyncAfter，因为 async 已经足够推迟到回调返回后
        DispatchQueue.main.async {

            // 通知 drag session 已结束（用于安全地更新 UI）
            NotificationCenter.default.post(
                name: .tabDragSessionEnded,
                object: nil,
                userInfo: ["tabId": capturedTabId]
            )

            // 拖拽结束
            // 如果操作为 none（没有被任何目标接收），检查是否拖出了所有窗口
            if capturedOperation == [] {
                // 检查是否在任何窗口内
                let isInAnyWindow = WindowManager.shared.findWindow(at: capturedScreenPoint) != nil

                if !isInAnyWindow {
                    // 拖出了所有窗口，通知回调创建新窗口
                    capturedOnDragOutOfWindow?(capturedScreenPoint)
                }
            }
        }
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

// MARK: - NSPasteboardItemDataProvider

extension TabItemView: NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?,
                    item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        // 提供拖拽数据（包含窗口编号、Panel ID 和 Tab ID）
        // 格式：tab:{windowNumber}:{panelId}:{tabId}
        let windowNumber = window?.windowNumber ?? 0
        let panelIdString = panelId?.uuidString ?? ""
        item.setString("tab:\(windowNumber):\(panelIdString):\(tabId.uuidString)", forType: .string)
    }
}

// MARK: - NSTextFieldDelegate

extension TabItemView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard hasFocused else { return }
        endEditing(save: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            // Enter 键：保存
            endEditing(save: true)
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            // Escape 键：取消
            endEditing(save: false)
            return true
        }
        return false
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
        needsAttention = true
        updateCyberView()
    }

    /// 设置提醒状态
    func setNeedsAttention(_ attention: Bool) {
        needsAttention = attention
        updateCyberView()
    }

    /// 清除提醒状态
    func clearAttention() {
        if needsAttention {
            needsAttention = false
            updateCyberView()
        }
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
