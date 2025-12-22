//
//  DraggableItemView.swift
//  ETerm
//
//  可拖拽标签项的基类
//
//  提供统一的拖拽检测、点击处理、编辑功能
//  PageItemView 和 TabItemView 继承此类
//

import AppKit
import SwiftUI
import Foundation

/// 可拖拽标签项的基类
///
/// 提供：
/// - trackEvents 拖拽检测（带阈值）
/// - 点击/双击处理
/// - 标题编辑
/// - hover 追踪
/// - 拖拽快照
class DraggableItemView: NSView {
    // MARK: - 子类必须提供的属性

    /// 项目 ID（子类实现）
    var itemId: UUID { fatalError("Subclass must override itemId") }

    /// 标题（didSet 保证一致性，直接赋值即可触发回调）
    var title: String = "" {
        didSet {
            guard oldValue != title else { return }
            titleDidChange()
            updateItemView()
        }
    }

    /// 标题变化时的回调（子类可覆盖）
    func titleDidChange() {
        // 默认空实现，子类可覆盖
    }

    /// SwiftUI hosting view（子类设置）
    var hostingView: NSView?

    // MARK: - 状态属性

    /// 是否激活
    private(set) var isActive: Bool = false

    /// 是否鼠标悬停
    private(set) var isHovered: Bool = false

    /// 是否正在拖拽
    private var isDragging: Bool = false

    /// 是否真正发生了拖动（鼠标移动）
    private var didActuallyDrag: Bool = false

    /// mouseDown 位置（用于计算拖拽阈值）
    private var mouseDownLocation: NSPoint = .zero

    /// 拖拽阈值（像素）
    let dragThreshold: CGFloat = 3

    /// 拖拽检测超时（秒）
    let dragTimeout: TimeInterval = 5.0

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

    /// 关闭其他回调（用于右键菜单）
    var onCloseOthers: (() -> Void)?

    /// 关闭左侧回调
    var onCloseLeft: (() -> Void)?

    /// 关闭右侧回调
    var onCloseRight: (() -> Void)?

    /// 是否可以关闭左侧
    var canCloseLeft: Bool = false

    /// 是否可以关闭右侧
    var canCloseRight: Bool = false

    /// 是否可以关闭其他
    var canCloseOthers: Bool = false

    // MARK: - 编辑相关

    /// 编辑框字体大小（子类可覆盖）
    var editFieldFontSize: CGFloat { 10 }

    /// 编辑框高度（子类可覆盖）
    var editFieldHeight: CGFloat { 18 }

    /// 编辑框
    private(set) lazy var editField: NSTextField = {
        let field = NSTextField()
        field.font = .systemFont(ofSize: editFieldFontSize)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.isHidden = true
        field.delegate = self
        return field
    }()

    /// 是否正在编辑
    private(set) var isEditing: Bool = false

    /// 是否已获得焦点
    private var hasFocused: Bool = false

    /// 是否正在等待焦点（用于防止异步焦点获取期间的虚假通知）
    private var isAwaitingFocus: Bool = false

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBase()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupBase() {
        wantsLayer = true
        addSubview(editField)
    }

    // MARK: - Public Methods

    /// 设置激活状态（只在真正变化时才刷新视图）
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        updateItemView()
    }

    // MARK: - 子类可覆盖的方法

    /// 更新视图（子类实现）
    /// 注意：编辑期间不应重建视图，避免闪烁
    func updateItemView() {
        // 编辑期间不重建视图，避免闪烁和焦点丢失
        guard !isEditing else { return }
        // 子类实现具体的 SwiftUI 视图更新
    }

    /// 创建 pasteboard 数据（子类实现）
    func createPasteboardData() -> String {
        fatalError("Subclass must override createPasteboardData()")
    }

    /// 关闭按钮区域宽度（子类可覆盖）
    var closeButtonAreaWidth: CGFloat { 30 }

    /// 是否显示关闭按钮（子类可覆盖）
    var showCloseButton: Bool { true }

    /// 拖拽结束时发送的通知名（子类可覆盖，nil 表示不发送）
    var dragSessionEndedNotificationName: Notification.Name? { nil }

    // MARK: - 编辑功能

    /// 开始编辑标题
    func startEditing() {
        isEditing = true
        isAwaitingFocus = true
        editField.stringValue = title
        editField.isHidden = false
        hostingView?.isHidden = true

        // 布局编辑框
        let padding: CGFloat = 6
        editField.frame = CGRect(
            x: padding,
            y: (bounds.height - editFieldHeight) / 2,
            width: bounds.width - padding * 2,
            height: editFieldHeight
        )

        // 确保编辑框在最上层（在隐藏 hosting view 后）
        bringEditFieldToFront()

        // 延迟获取焦点（给视图层级时间稳定，避免 NSHostingView + NSTextField 的焦点冲突）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self, self.isEditing, !self.editField.isHidden else { return }
            self.editField.selectText(nil)
            if self.window?.makeFirstResponder(self.editField) == true {
                self.hasFocused = true
            }
            self.isAwaitingFocus = false
        }
    }

    /// 结束编辑标题
    func endEditing(save: Bool) {
        guard isEditing else { return }
        isEditing = false
        hasFocused = false
        isAwaitingFocus = false

        if save {
            let newTitle = editField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newTitle.isEmpty && newTitle != title {
                title = newTitle  // didSet 自动触发 titleDidChange() 和 updateItemView()
                onRename?(newTitle)
            }
        }

        editField.isHidden = true
        hostingView?.isHidden = false
    }

    /// 确保编辑框在最上层
    func bringEditFieldToFront() {
        if editField.superview != nil {
            editField.removeFromSuperview()
            addSubview(editField)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        // 如果 hostingView 不存在但视图有有效尺寸，延迟创建它
        // 这处理了 init() 时 bounds 为 zero、updateItemView() 跳过创建的情况
        if hostingView == nil && bounds.width > 0 && bounds.height > 0 {
            updateItemView()
        }

        hostingView?.frame = bounds
    }

    // MARK: - 阻止窗口拖动

    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    // MARK: - Hit Test

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        // 关闭按钮区域让 SwiftUI 处理
        // 直接返回 hostingView，让 NSHostingView 内部处理 SwiftUI Button 点击
        if showCloseButton,
           let hosting = hostingView,
           point.x > bounds.width - closeButtonAreaWidth {
            return hosting
        }

        // 其他区域返回自己处理点击/拖拽
        return self
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        trackingAreas.forEach { removeTrackingArea($0) }

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
        updateItemView()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateItemView()
    }

    // MARK: - Event Handlers

    override func mouseDown(with event: NSEvent) {
        // 如果正在编辑，不处理拖拽
        guard !isEditing else { return }

        // 检查全局 drag 锁（防止在 UI 更新期间启动新 drag）
        if DragLock.shared.isLocked { return }

        // 重置拖拽标志
        isDragging = false
        didActuallyDrag = false
        mouseDownLocation = convert(event.locationInWindow, from: nil)

        // 保存 mouseDown 的 clickCount（比 mouseUp 更可靠）
        let clickCount = event.clickCount

        // 使用事件追踪循环判断是拖拽还是点击（macOS 标准方式）
        guard let theWindow = window else { return }

        var dragEvent: NSEvent?  // 捕获触发阈值的拖拽事件
        var didMouseUp = false

        // 使用超时避免无限阻塞（如窗口关闭、应用失焦等异常情况）
        theWindow.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: dragTimeout, mode: .eventTracking) { [weak self] trackedEvent, stop in
            guard let self = self else {
                stop.pointee = true
                return
            }

            // 超时或无事件时退出
            guard let trackedEvent = trackedEvent else {
                stop.pointee = true
                return
            }

            switch trackedEvent.type {
            case .leftMouseUp:
                didMouseUp = true
                stop.pointee = true

            case .leftMouseDragged:
                let currentLocation = self.convert(trackedEvent.locationInWindow, from: nil)
                let dx = currentLocation.x - self.mouseDownLocation.x
                let dy = currentLocation.y - self.mouseDownLocation.y
                let distance = sqrt(dx * dx + dy * dy)

                if distance >= self.dragThreshold {
                    dragEvent = trackedEvent
                    self.didActuallyDrag = true
                    self.isDragging = true
                    stop.pointee = true
                }

            default:
                break
            }
        }

        if let dragEvent = dragEvent {
            // 使用触发阈值的拖拽事件启动拖拽会话
            startDragSession(with: dragEvent)
        } else if didMouseUp {
            // 使用 mouseDown 的 clickCount 处理点击
            handleClick(clickCount: clickCount)
        }
        // 超时情况：不做任何处理，视为取消操作
    }

    override func mouseDragged(with event: NSEvent) {
        // 拖拽由 mouseDown 中的事件追踪循环处理
    }

    override func mouseUp(with event: NSEvent) {
        // 点击逻辑已在 mouseDown 的事件追踪循环中处理
        isDragging = false
        didActuallyDrag = false
    }

    // MARK: - 右键菜单

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        // 关闭当前
        if showCloseButton {
            let closeItem = NSMenuItem(title: "关闭", action: #selector(handleClose), keyEquivalent: "")
            closeItem.target = self
            menu.addItem(closeItem)
        }

        // 关闭其他
        if canCloseOthers {
            let closeOthersItem = NSMenuItem(title: "关闭其他", action: #selector(handleCloseOthers), keyEquivalent: "")
            closeOthersItem.target = self
            menu.addItem(closeOthersItem)
        }

        // 关闭左侧
        if canCloseLeft {
            let closeLeftItem = NSMenuItem(title: "关闭左侧", action: #selector(handleCloseLeft), keyEquivalent: "")
            closeLeftItem.target = self
            menu.addItem(closeLeftItem)
        }

        // 关闭右侧
        if canCloseRight {
            let closeRightItem = NSMenuItem(title: "关闭右侧", action: #selector(handleCloseRight), keyEquivalent: "")
            closeRightItem.target = self
            menu.addItem(closeRightItem)
        }

        // 只有有菜单项时才显示
        if menu.items.count > 0 {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    @objc private func handleClose() {
        onClose?()
    }

    @objc private func handleCloseOthers() {
        onCloseOthers?()
    }

    @objc private func handleCloseLeft() {
        onCloseLeft?()
    }

    @objc private func handleCloseRight() {
        onCloseRight?()
    }

    // MARK: - 点击处理

    private func handleClick(clickCount: Int) {
        if clickCount == 2 {
            startEditing()
        } else if clickCount == 1 {
            onTap?()
        }
    }

    // MARK: - 拖拽会话

    private func startDragSession(with event: NSEvent) {
        // 通知子类拖拽即将开始
        dragSessionWillStart()

        let snapshot = createSnapshot()

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setDataProvider(self, forTypes: [.string])

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let dragFrame = NSRect(origin: .zero, size: bounds.size)
        draggingItem.setDraggingFrame(dragFrame, contents: snapshot)

        onDragStart?()
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// 拖拽即将开始时的回调（子类可覆盖）
    func dragSessionWillStart() {
        // 默认空实现，子类可覆盖
    }

    /// 拖拽结束时的回调（子类可覆盖）
    func dragSessionDidEnd() {
        // 默认空实现，子类可覆盖
    }

    // MARK: - 拖拽预览

    /// 创建拖拽预览图像
    func createSnapshot() -> NSImage {
        guard bounds.width > 0 && bounds.height > 0 else {
            return NSImage()
        }

        // 使用 bitmapImageRepForCachingDisplay 创建快照
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
            // 回退到 PDF 方式
            let pdfData = dataWithPDF(inside: bounds)
            return NSImage(data: pdfData) ?? NSImage()
        }

        cacheDisplay(in: bounds, to: bitmapRep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}

// MARK: - NSDraggingSource

extension DraggableItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // 通知子类拖拽结束（在 self 可能被销毁前调用）
        dragSessionDidEnd()

        // 捕获需要的值（因为 self 可能在回调后被销毁）
        let capturedItemId = itemId
        let capturedOnDragOutOfWindow = onDragOutOfWindow
        let capturedNotificationName = dragSessionEndedNotificationName

        // 延迟通知到下一个 runloop 迭代
        // 确保 AppKit 有机会完成其内部清理，再触发 UI 更新
        DispatchQueue.main.async {
            // 发送拖拽结束通知（用于 DropIntentQueue 等待）
            if let notificationName = capturedNotificationName {
                NotificationCenter.default.post(
                    name: notificationName,
                    object: nil,
                    userInfo: ["itemId": capturedItemId]
                )
            }

            // 检查是否拖出了所有窗口
            // 不检查 operation，因为即使拖到其他区域 operation 也可能不为空
            let isInAnyWindow = WindowManager.shared.findWindow(at: screenPoint) != nil
            if !isInAnyWindow {
                capturedOnDragOutOfWindow?(screenPoint)
            }
        }
    }
}

// MARK: - NSPasteboardItemDataProvider

extension DraggableItemView: NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?,
                    item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(createPasteboardData(), forType: .string)
    }
}

// MARK: - NSTextFieldDelegate

extension DraggableItemView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        // 防护：只在编辑状态且编辑框可见时处理
        guard isEditing, !editField.isHidden else { return }

        // 防护：确保通知来自我们的编辑框
        guard let textField = obj.object as? NSTextField,
              textField === editField else { return }

        // 防护：如果正在等待焦点，忽略此通知（异步焦点获取期间的虚假通知）
        guard !isAwaitingFocus else { return }

        // 只有获得过焦点才保存编辑结果
        endEditing(save: hasFocused)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            endEditing(save: true)
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            endEditing(save: false)
            return true
        }
        return false
    }
}
