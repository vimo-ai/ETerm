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

    /// SwiftUI 水墨标签视图
    private var hostingView: NSHostingView<ShuimoTabView>?

    /// 是否正在拖拽
    private var isDragging: Bool = false

    /// 是否真正发生了拖动（鼠标移动）
    private var didActuallyDrag: Bool = false

    // MARK: - 回调

    /// 点击回调
    var onTap: (() -> Void)?

    /// 开始拖拽回调
    var onDragStart: (() -> Void)?

    /// 关闭回调
    var onClose: (() -> Void)?

    /// 重命名回调
    var onRename: ((String) -> Void)?

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

    // MARK: - Private Methods

    private func setupUI() {
        wantsLayer = true

        // 创建水墨标签视图
        updateShuimoView()

        // 添加编辑框
        addSubview(editField)
    }

    private func setupGestures() {
        // 拖拽通过 mouseDown 启动，不需要手势识别器
    }

    private func updateShuimoView() {
        // 移除旧的 hostingView
        hostingView?.removeFromSuperview()

        // 创建新的 SwiftUI 视图
        let shuimoTab = ShuimoTabView(title, isActive: isActive, height: 26) { [weak self] in
            self?.onClose?()
        }

        let hosting = NSHostingView(rootView: shuimoTab)
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
                updateShuimoView()
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

    // MARK: - Event Handlers

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
                // 单击：切换 Tab
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
        // 提供拖拽数据（Tab ID）- 使用 "tab:" 前缀与 Page 区分
        item.setString("tab:\(tabId.uuidString)", forType: .string)
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
