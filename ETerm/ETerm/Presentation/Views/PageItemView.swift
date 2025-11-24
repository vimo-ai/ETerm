//
//  PageItemView.swift
//  ETerm
//
//  单个 Page 的视图
//
//  类似 Tab，但用于 Page 级别的切换
//  支持：
//  - 点击切换 Page
//  - 双击编辑标题（重命名）
//  - 关闭 Page（当 Page > 1 时）
//  - 拖拽支持（为未来 Tab 拖入 Page 栏做准备）
//

import AppKit
import Foundation

/// 单个 Page 的视图
///
/// 显示 Page 的标题和关闭按钮，支持点击、双击编辑和拖拽操作
final class PageItemView: NSView {
    // MARK: - 属性

    /// Page ID
    let pageId: UUID

    /// 标题标签
    private let titleLabel: NSTextField

    /// 编辑框（双击重命名时显示）
    private let editField: NSTextField

    /// 关闭按钮
    private let closeButton: NSButton

    /// 是否激活
    private var isActive: Bool = false

    /// 是否正在编辑标题
    private var isEditing: Bool = false

    /// 是否已经成功获得焦点（用于过滤误触发的 textDidEndEditing）
    private var hasFocused: Bool = false

    /// 是否显示关闭按钮
    private var showCloseButton: Bool = true

    // MARK: - 回调

    /// 点击回调
    var onTap: (() -> Void)?

    /// 关闭回调
    var onClose: (() -> Void)?

    /// 重命名回调
    var onRename: ((String) -> Void)?

    /// 开始拖拽回调（预留）
    var onDragStart: (() -> Void)?

    // MARK: - 初始化

    init(pageId: UUID, title: String) {
        self.pageId = pageId

        // 创建标题标签
        self.titleLabel = NSTextField(labelWithString: title)
        self.titleLabel.isEditable = false
        self.titleLabel.isBordered = false
        self.titleLabel.backgroundColor = .clear
        self.titleLabel.textColor = .secondaryLabelColor
        self.titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        self.titleLabel.lineBreakMode = .byTruncatingTail

        // 创建编辑框
        self.editField = NSTextField()
        self.editField.font = .systemFont(ofSize: 11, weight: .medium)
        self.editField.isBordered = true
        self.editField.bezelStyle = .roundedBezel
        self.editField.isHidden = true
        self.editField.backgroundColor = .red  // 调试用：红色背景
        self.editField.drawsBackground = true

        // 创建关闭按钮
        self.closeButton = NSButton()
        self.closeButton.bezelStyle = .inline
        self.closeButton.isBordered = false
        self.closeButton.title = ""
        self.closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        self.closeButton.imagePosition = .imageOnly
        self.closeButton.contentTintColor = .secondaryLabelColor

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

    /// 设置是否显示关闭按钮
    func setShowCloseButton(_ show: Bool) {
        showCloseButton = show
        closeButton.isHidden = !show
        needsLayout = true
    }

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 4

        // 添加子视图
        addSubview(titleLabel)
        addSubview(editField)
        addSubview(closeButton)

        // 设置关闭按钮的点击事件
        closeButton.target = self
        closeButton.action = #selector(handleClose)

        // 设置编辑框代理
        editField.delegate = self

        // 初始外观
        updateAppearance()
    }

    private func setupGestures() {
        // 双击检测在 mouseUp 中处理，不使用手势识别器
        // 手势识别器与 mouseUp 事件存在冲突，会导致双击检测失败
    }

    private func updateAppearance() {
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
            titleLabel.textColor = .labelColor
            closeButton.contentTintColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = .secondaryLabelColor
            closeButton.contentTintColor = .secondaryLabelColor
        }
    }

    /// 开始编辑标题
    private func startEditing() {
        isEditing = true
        editField.stringValue = titleLabel.stringValue
        editField.isHidden = false
        titleLabel.isHidden = true

        // 延迟一帧再获取焦点，等待视图层级稳定
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
            if !newTitle.isEmpty && newTitle != titleLabel.stringValue {
                titleLabel.stringValue = newTitle
                onRename?(newTitle)
            }
        }

        editField.isHidden = true
        titleLabel.isHidden = false
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let padding: CGFloat = 6
        let closeButtonSize: CGFloat = 14
        let spacing: CGFloat = 4

        if showCloseButton && !closeButton.isHidden {
            // 关闭按钮在右侧
            closeButton.frame = CGRect(
                x: bounds.width - closeButtonSize - padding,
                y: (bounds.height - closeButtonSize) / 2,
                width: closeButtonSize,
                height: closeButtonSize
            )

            // 标题占据剩余空间
            let titleWidth = bounds.width - closeButtonSize - padding * 2 - spacing
            titleLabel.frame = CGRect(
                x: padding,
                y: (bounds.height - titleLabel.intrinsicContentSize.height) / 2,
                width: titleWidth,
                height: titleLabel.intrinsicContentSize.height
            )

            // 编辑框
            editField.frame = CGRect(
                x: padding,
                y: (bounds.height - 20) / 2,
                width: titleWidth,
                height: 20
            )
        } else {
            // 没有关闭按钮，标题居中
            let titleWidth = bounds.width - padding * 2
            titleLabel.frame = CGRect(
                x: padding,
                y: (bounds.height - titleLabel.intrinsicContentSize.height) / 2,
                width: titleWidth,
                height: titleLabel.intrinsicContentSize.height
            )

            // 编辑框
            editField.frame = CGRect(
                x: padding,
                y: (bounds.height - 20) / 2,
                width: titleWidth,
                height: 20
            )
        }
    }

    // MARK: - Event Handlers

    override func mouseDown(with event: NSEvent) {
        // 检查点击位置是否在关闭按钮上
        let location = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(location) && showCloseButton {
            super.mouseDown(with: event)
            return
        }

        // 单击事件在 mouseUp 中处理
    }

    override func mouseUp(with event: NSEvent) {
        // 检查点击位置是否在关闭按钮上
        let location = convert(event.locationInWindow, from: nil)
        if closeButton.frame.contains(location) && showCloseButton {
            super.mouseUp(with: event)
            return
        }

        // 如果正在编辑状态，不处理点击事件
        guard !isEditing else {
            super.mouseUp(with: event)
            return
        }

        // 根据点击次数处理：双击编辑，单击切换
        if event.clickCount == 2 {
            startEditing()
        } else if event.clickCount == 1 {
            onTap?()
        }

        super.mouseUp(with: event)
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
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !isActive {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - NSTextFieldDelegate

extension PageItemView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        // 只有在成功获得焦点后才处理结束编辑
        // 过滤掉"刚显示还没获得焦点就触发的 textDidEndEditing"
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
