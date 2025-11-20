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
import Foundation

/// 单个 Tab 的视图
///
/// 显示 Tab 的标题和关闭按钮，支持点击和拖拽操作。
final class TabItemView: NSView {
    // MARK: - 属性

    /// Tab ID
    let tabId: UUID

    /// 标题标签
    private let titleLabel: NSTextField

    /// 关闭按钮
    private let closeButton: NSButton

    /// 是否激活
    private var isActive: Bool = false

    /// 是否正在拖拽
    private var isDragging: Bool = false

    // MARK: - 回调

    /// 点击回调
    var onTap: (() -> Void)?

    /// 开始拖拽回调
    var onDragStart: (() -> Void)?

    /// 关闭回调
    var onClose: (() -> Void)?

    // MARK: - 初始化

    init(tabId: UUID, title: String) {
        self.tabId = tabId

        // 创建标题标签
        self.titleLabel = NSTextField(labelWithString: title)
        self.titleLabel.isEditable = false
        self.titleLabel.isBordered = false
        self.titleLabel.backgroundColor = .clear
        self.titleLabel.textColor = .secondaryLabelColor
        self.titleLabel.font = .systemFont(ofSize: 12)

        // 创建关闭按钮
        self.closeButton = NSButton()
        self.closeButton.bezelStyle = .inline
        self.closeButton.isBordered = false
        self.closeButton.title = ""
        self.closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        self.closeButton.imagePosition = .imageOnly

        super.init(frame: .zero)

        setupUI()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// 设置激活状态
    func setActive(_ active: Bool) {
        isActive = active
        updateAppearance()
    }

    /// 更新标题
    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 4

        // 添加子视图
        addSubview(titleLabel)
        addSubview(closeButton)

        // 设置关闭按钮的点击事件
        closeButton.target = self
        closeButton.action = #selector(handleClose)

        // 初始外观
        updateAppearance()
    }

    private func setupGestures() {
        // 拖拽通过 mouseDown 启动，不需要手势识别器
    }

    private func updateAppearance() {
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            titleLabel.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = .secondaryLabelColor
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let padding: CGFloat = 8
        let closeButtonSize: CGFloat = 16

        // 关闭按钮在右侧
        closeButton.frame = CGRect(
            x: bounds.width - closeButtonSize - padding,
            y: (bounds.height - closeButtonSize) / 2,
            width: closeButtonSize,
            height: closeButtonSize
        )

        // 标题占据剩余空间
        titleLabel.frame = CGRect(
            x: padding,
            y: (bounds.height - titleLabel.intrinsicContentSize.height) / 2,
            width: bounds.width - closeButtonSize - padding * 3,
            height: titleLabel.intrinsicContentSize.height
        )
    }

    // MARK: - Event Handlers

    override func mouseDown(with event: NSEvent) {
        // 检查点击位置是否在关闭按钮上
        let location = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(location) {
            // 点击了关闭按钮，交给按钮处理
            super.mouseDown(with: event)
            return
        }

        // 🚧 临时禁用拖拽，只保留点击功能
        // TODO: 后续迁移完整的拖拽逻辑（需要 DragCoordinator）
        // 当前直接触发点击
        onTap?()

        /* 原本的拖拽逻辑（暂时注释）
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setDataProvider(self, forTypes: [.string])

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: createSnapshot())

        isDragging = true
        onDragStart?()

        beginDraggingSession(with: [draggingItem], event: event, source: self)
        */
    }

    override func mouseUp(with event: NSEvent) {
        // 拖拽功能临时禁用，mouseUp 不需要处理
        super.mouseUp(with: event)
    }

    // MARK: - 拖拽预览

    /// 创建拖拽预览图像
    private func createSnapshot() -> NSImage {
        // 使用 PDF 数据创建快照
        let pdfData = dataWithPDF(inside: bounds)
        return NSImage(data: pdfData) ?? NSImage()
    }

    @objc private func handleClose() {
        onClose?()
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // 移除旧的 tracking area
        trackingAreas.forEach { removeTrackingArea($0) }

        // 添加新的 tracking area
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if !isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !isActive {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - NSDraggingSource

extension TabItemView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // 拖拽结束（由目标处理布局更新）
    }
}

// MARK: - NSPasteboardItemDataProvider

extension TabItemView: NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?,
                    item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        // 提供拖拽数据（Tab ID）
        item.setString(tabId.uuidString, forType: .string)
    }
}
