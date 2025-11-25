//
//  PageItemView.swift
//  ETerm
//
//  单个 Page 的视图
//
//  使用 ShuimoTabView 实现水墨风格
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

    /// SwiftUI 水墨标签视图
    private var hostingView: NSView?

    // MARK: - 回调

    /// 点击回调
    var onTap: (() -> Void)?

    /// 关闭回调
    var onClose: (() -> Void)?

    /// 重命名回调
    var onRename: ((String) -> Void)?

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
        updateShuimoView()
    }

    /// 更新标题
    func setTitle(_ newTitle: String) {
        title = newTitle
        updateShuimoView()
    }

    /// 设置是否显示关闭按钮
    func setShowCloseButton(_ show: Bool) {
        showCloseButton = show
        updateShuimoView()
    }

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true
        // 调试：绿色背景
        layer?.backgroundColor = NSColor.green.withAlphaComponent(0.5).cgColor

        // 创建水墨标签视图
        updateShuimoView()

        // 添加编辑框
        addSubview(editField)
    }

    private func updateShuimoView() {
        // 移除旧的 hostingView
        hostingView?.removeFromSuperview()

        // 创建新的 SwiftUI 视图
        let closeAction: (() -> Void)? = showCloseButton ? { [weak self] in
            self?.onClose?()
        } : nil

        let shuimoTab = ShuimoTabView(title, isActive: isActive, height: 22, onClose: closeAction)

        let hosting = NSHostingView(rootView: shuimoTab)
        // 让 NSHostingView 使用固有大小，不居中
        hosting.translatesAutoresizingMaskIntoConstraints = true
        let size = hosting.fittingSize
        hosting.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
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
                updateShuimoView()
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
        print("📦 PageItemView.layout()")
        print("   bounds: \(bounds)")
        print("   hostingView.frame: \(hostingView?.frame ?? .zero)")
    }

    // MARK: - Event Handlers

    override func mouseDown(with event: NSEvent) {
        // 不做处理，等待 mouseUp
    }

    override func mouseUp(with event: NSEvent) {
        // 如果正在编辑，不处理
        guard !isEditing else {
            super.mouseUp(with: event)
            return
        }

        // 根据点击次数处理
        if event.clickCount == 2 {
            startEditing()
        } else if event.clickCount == 1 {
            onTap?()
        }

        super.mouseUp(with: event)
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
