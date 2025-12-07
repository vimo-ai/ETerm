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

    /// Claude 响应完成提醒状态
    private var needsAttention: Bool = false

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

        // 创建新的 SwiftUI 视图
        let closeAction: (() -> Void)? = showCloseButton ? { [weak self] in
            self?.onClose?()
        } : nil

        let simpleTab = SimpleTabView(title, isActive: isActive, needsAttention: needsAttention, height: 22, onClose: closeAction)

        let hosting = NSHostingView(rootView: simpleTab)
        // 让 NSHostingView 使用固有大小，不居中
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

    override var fittingSize: NSSize {
        // 宽度用 hostingView 的，高度用固定值（避免 NSHostingView 返回错误高度）
        let width = hostingView?.fittingSize.width ?? 0
        return NSSize(width: width, height: Self.tabHeight)
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 检查点击是否在 bounds 内
        guard bounds.contains(point) else {
            return nil
        }

        // 检查是否点击了关闭按钮（在 hostingView 内）
        if let hosting = hostingView,
           let swiftUIHit = hosting.hitTest(convert(point, to: hosting)),
           swiftUIHit !== hosting {
            // 点击了 SwiftUI 的某个可交互元素（比如关闭按钮）
            return swiftUIHit
        }

        // 其他区域返回自己，让 PageItemView 处理点击
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // 重置拖拽标志
        isDragging = false
        didActuallyDrag = false

        // 不立即启动拖拽，等待 mouseDragged 确认真正拖动
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)

        // 如果已经在拖拽中，不重复启动
        if isDragging {
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
                // 单击：切换 Page
                onTap?()
            }
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

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        trackingAreas.forEach { removeTrackingArea($0) }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
}

// MARK: - NSDraggingSource

extension PageItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 允许在窗口外部移动（用于创建新窗口）
        return context == .outsideApplication ? .move : .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // 拖拽结束
        // 如果操作为 none（没有被任何目标接收），检查是否拖出了所有窗口
        if operation == [] {
            // 检查是否在任何窗口内
            let isInAnyWindow = WindowManager.shared.findWindow(at: screenPoint) != nil

            if !isInAnyWindow {
                // 拖出了所有窗口，通知回调创建新窗口
                onDragOutOfWindow?(screenPoint)
            }
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
