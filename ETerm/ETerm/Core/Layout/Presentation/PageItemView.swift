//
//  PageItemView.swift
//  ETerm
//
//  单个 Page 的视图
//
//  使用 SimpleTabView 实现简约风格
//  支持：
//  - 点击切换 Page
//  - 双击编辑标题（重命名）
//  - 关闭 Page（当 Page > 1 时）
//

import AppKit
import SwiftUI
import Foundation

// MARK: - 禁止窗口拖动的 NSHostingView

/// 自定义 NSHostingView 子类，禁止窗口拖动
/// 让 PageItemView 可以正确处理拖拽事件
final class PageItemHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}

/// 单个 Page 的视图
///
/// 显示 Page 的标题和关闭按钮，支持点击、双击编辑
final class PageItemView: NSView {
    // MARK: - 属性

    /// Page ID
    let pageId: UUID

    /// 标题
    private var title: String

    /// 是否激活
    private var isActive: Bool = false

    /// 是否显示关闭按钮
    private var showCloseButton: Bool = true

    /// SwiftUI 简约标签视图
    private var hostingView: NSView?

    /// 是否正在拖拽
    private var isDragging: Bool = false

    /// 是否真正发生了拖动（鼠标移动）
    private var didActuallyDrag: Bool = false

    /// mouseDown 位置（用于计算拖拽阈值）
    private var mouseDownLocation: NSPoint = .zero

    /// 拖拽阈值（像素）
    private let dragThreshold: CGFloat = 3

    /// Claude 响应完成提醒状态
    private var needsAttention: Bool = false

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

    // MARK: - 编辑相关

    /// 编辑框
    private lazy var editField: NSTextField = {
        let field = NSTextField()
        field.font = .systemFont(ofSize: 22 * 0.4)
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

    init(pageId: UUID, title: String) {
        self.pageId = pageId
        self.title = title

        super.init(frame: .zero)

        setupUI()
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

    /// 更新标题
    func setTitle(_ newTitle: String) {
        title = newTitle
        updateCyberView()
    }

    /// 设置是否显示关闭按钮
    func setShowCloseButton(_ show: Bool) {
        showCloseButton = show
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

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true

        // 创建赛博标签视图
        updateCyberView()

        // 添加编辑框
        addSubview(editField)
    }

    private func updateCyberView() {
        // 移除旧的 hostingView
        hostingView?.removeFromSuperview()

        // 创建新的 SwiftUI 视图（传入外部控制的 isHovered 状态）
        let closeAction: (() -> Void)? = showCloseButton ? { [weak self] in
            self?.onClose?()
        } : nil

        let simpleTab = SimpleTabView(title, isActive: isActive, needsAttention: needsAttention, height: 22, isHovered: isHovered, onClose: closeAction)

        // 使用自定义子类禁止窗口拖动
        let hosting = PageItemHostingView(rootView: simpleTab)
        hosting.translatesAutoresizingMaskIntoConstraints = true

        addSubview(hosting)
        hostingView = hosting

        // 立即布局 hostingView，确保它的 frame 和 PageItemView 的 bounds 一致
        hosting.frame = bounds

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
        let padding: CGFloat = 6
        editField.frame = CGRect(
            x: padding,
            y: (bounds.height - 18) / 2,
            width: bounds.width - padding * 2,
            height: 18
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
                // 通知父视图重新布局（pageContainer -> PageBarView）
                superview?.superview?.needsLayout = true
                onRename?(newTitle)
            }
        }

        editField.isHidden = true
        hostingView?.isHidden = false
    }

    // MARK: - Layout

    /// ShuimoTabView 的固定高度
    private static let tabHeight: CGFloat = 22

    /// SimpleTabView 的固定宽度（与 SimpleTabView.tabWidth 保持一致）
    private static let tabWidth: CGFloat = 180

    override var fittingSize: NSSize {
        // 使用固定宽度，避免 NSHostingView 还没布局时返回 0
        return NSSize(width: Self.tabWidth, height: Self.tabHeight)
    }

    override var intrinsicContentSize: NSSize {
        let width = hostingView?.intrinsicContentSize.width ?? NSView.noIntrinsicMetric
        return NSSize(width: width, height: Self.tabHeight)
    }

    override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    // MARK: - Event Handlers

    // MARK: - 阻止窗口拖动

    override var mouseDownCanMoveWindow: Bool {
        return false  // 阻止窗口跟着拖动，让 Page 拖拽生效
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 检查点击是否在 bounds 内
        guard bounds.contains(point) else {
            return nil
        }

        // 检查 SwiftUI 层是否有按钮（NSControl）响应
        // 不硬编码区域，由 SwiftUI 按钮的实际 frame 决定
        if showCloseButton,
           let hosting = hostingView,
           let swiftUIHit = hosting.hitTest(convert(point, to: hosting)),
           swiftUIHit is NSControl {
            return swiftUIHit
        }

        // 其他区域返回自己，让 PageItemView 处理点击/拖拽
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // 如果正在编辑，不处理拖拽
        guard !isEditing else { return }

        // 重置拖拽标志
        isDragging = false
        didActuallyDrag = false
        mouseDownLocation = convert(event.locationInWindow, from: nil)

        // 使用事件追踪循环判断是拖拽还是点击（macOS 标准方式）
        guard let theWindow = window else { return }

        var dragStarted = false
        var mouseUpEvent: NSEvent?

        theWindow.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: .infinity, mode: .eventTracking) { trackedEvent, stop in
            guard let trackedEvent = trackedEvent else {
                stop.pointee = true
                return
            }

            switch trackedEvent.type {
            case .leftMouseUp:
                mouseUpEvent = trackedEvent
                stop.pointee = true

            case .leftMouseDragged:
                let currentLocation = self.convert(trackedEvent.locationInWindow, from: nil)
                let dx = currentLocation.x - self.mouseDownLocation.x
                let dy = currentLocation.y - self.mouseDownLocation.y
                let distance = sqrt(dx * dx + dy * dy)

                if distance >= self.dragThreshold {
                    dragStarted = true
                    self.didActuallyDrag = true
                    self.isDragging = true
                    stop.pointee = true
                }

            default:
                break
            }
        }

        if dragStarted {
            startDragSession(with: event)
        } else if let upEvent = mouseUpEvent {
            handleClick(event: upEvent)
        }
    }

    /// 处理点击事件
    private func handleClick(event: NSEvent) {
        if event.clickCount == 2 {
            startEditing()
        } else if event.clickCount == 1 {
            onTap?()
        }
    }

    /// 启动拖拽会话
    private func startDragSession(with event: NSEvent) {
        let snapshot = createSnapshot()

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setDataProvider(self, forTypes: [.string])

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let dragFrame = NSRect(origin: .zero, size: bounds.size)
        draggingItem.setDraggingFrame(dragFrame, contents: snapshot)

        onDragStart?()
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseDragged(with event: NSEvent) {
        // 拖拽由 mouseDown 中的事件追踪循环处理
        // 这里不需要额外处理
    }

    override func mouseUp(with event: NSEvent) {
        // 点击逻辑已在 mouseDown 的事件追踪循环中处理
        // 这里只重置状态
        isDragging = false
        didActuallyDrag = false
    }

    // MARK: - 拖拽预览

    /// 创建拖拽预览图像
    private func createSnapshot() -> NSImage {
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
        updateCyberView()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateCyberView()
    }
}

// MARK: - NSDraggingSource

extension PageItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // 检查是否拖出了所有窗口（不依赖 operation，因为 PageBarHostingView 会接收拖拽）
        let isInAnyWindow = WindowManager.shared.findWindow(at: screenPoint) != nil
        if !isInAnyWindow {
            onDragOutOfWindow?(screenPoint)
        }
    }
}

// MARK: - NSPasteboardItemDataProvider

extension PageItemView: NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?,
                    item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        // 提供拖拽数据（包含窗口编号和 Page ID）
        // 格式：page:{windowNumber}:{pageId}
        let windowNumber = window?.windowNumber ?? 0
        item.setString("page:\(windowNumber):\(pageId.uuidString)", forType: .string)
    }
}

// MARK: - NSTextFieldDelegate

extension PageItemView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard hasFocused else { return }
        endEditing(save: true)
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
