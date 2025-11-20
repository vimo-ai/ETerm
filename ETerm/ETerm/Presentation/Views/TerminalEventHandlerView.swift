//
//  TerminalEventHandlerView.swift
//  ETerm
//
//  表示层 - 统一的终端事件处理视图
//
//  职责：
//  - 处理鼠标事件（点击、拖拽、滚动）
//  - 处理键盘事件
//  - 处理 IME 输入
//  - 将事件转发给对应的协调器
//

import AppKit
import Foundation

/// 终端事件处理视图
///
/// 作为事件处理的统一入口，负责接收所有用户交互并转发给协调器
class TerminalEventHandlerView: NSView {
    // MARK: - Dependencies

    weak var windowController: WindowController?

    // MARK: - State

    /// 当前的 Panel ID
    var currentPanelId: UUID?

    /// 是否正在拖拽选中
    private var isDraggingSelection: Bool = false

    // MARK: - IME Support

    /// 标记文本范围（预编辑文本）
    private var markedText: String = ""
    private var _markedRange: NSRange = NSRange(location: NSNotFound, length: 0)
    private var _selectedRange: NSRange = NSRange(location: NSNotFound, length: 0)

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // 允许成为第一响应者
        // 这是接收键盘和 IME 输入的必要条件
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func resignFirstResponder() -> Bool {
        return true
    }
}

// MARK: - Mouse Events

extension TerminalEventHandlerView {
    /// 鼠标按下
    override func mouseDown(with event: NSEvent) {
        guard let panelId = findPanelAt(event: event),
              let controller = windowController else {
            return
        }

        currentPanelId = panelId

        // 获取鼠标位置（Swift 坐标系）
        let location = convert(event.locationInWindow, from: nil)

        // 开始选中
        controller.textSelectionCoordinator.handleMouseDown(
            at: location,
            panelId: panelId
        )

        isDraggingSelection = true
    }

    /// 鼠标拖拽
    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection,
              let panelId = currentPanelId,
              let controller = windowController else {
            return
        }

        // 获取鼠标位置
        let location = convert(event.locationInWindow, from: nil)

        // 更新选中
        controller.textSelectionCoordinator.handleMouseDragged(
            to: location,
            panelId: panelId
        )
    }

    /// 鼠标松开
    override func mouseUp(with event: NSEvent) {
        guard isDraggingSelection,
              let panelId = currentPanelId,
              let controller = windowController else {
            return
        }

        // 结束选中
        controller.textSelectionCoordinator.handleMouseUp(panelId: panelId)

        isDraggingSelection = false
    }

    /// 滚动
    override func scrollWheel(with event: NSEvent) {
        guard let panelId = findPanelAt(event: event),
              let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab,
              let session = activeTab.terminalSession else {
            return
        }

        // 计算滚动量
        let deltaY = event.scrollingDeltaY

        if abs(deltaY) > 0.1 {
            let deltaLines = Int32(deltaY / 10.0)  // 调整滚动速度
            session.scroll(deltaLines: deltaLines)
        }
    }

    /// 查找鼠标位置下的 Panel
    private func findPanelAt(event: NSEvent) -> UUID? {
        let location = convert(event.locationInWindow, from: nil)
        return windowController?.findPanel(at: location)
    }
}

// MARK: - Keyboard Events

extension TerminalEventHandlerView {
    /// 处理按键事件
    override func keyDown(with event: NSEvent) {
        guard let panelId = currentPanelId,
              let controller = windowController else {
            super.keyDown(with: event)
            return
        }

        // 先尝试让 KeyboardCoordinator 处理
        let handled = controller.keyboardCoordinator.handleKeyDown(
            event: event,
            panelId: panelId
        )

        if !handled {
            // 如果未处理，传递给输入系统（IME）
            interpretKeyEvents([event])
        }
    }

    /// 处理特殊命令
    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) {
            // Escape 键：取消预编辑
            if let panelId = currentPanelId,
               let coordinator = windowController?.inputCoordinator {
                coordinator.handleCancelPreedit(panelId: panelId)
            }
            return
        }

        super.doCommand(by: selector)
    }
}

// MARK: - NSTextInputClient

extension TerminalEventHandlerView: NSTextInputClient {
    /// 插入文本（非 IME 输入）
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String,
              let panelId = currentPanelId,
              let coordinator = windowController?.inputCoordinator else {
            return
        }

        // 如果有标记文本，先清除
        if _markedRange.location != NSNotFound {
            unmarkText()
        }

        // 处理文本输入
        coordinator.handleTextInput(text: text, panelId: panelId)
    }

    /// 设置标记文本（IME 预编辑）
    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        guard let panelId = currentPanelId,
              let coordinator = windowController?.inputCoordinator else {
            return
        }

        // 提取文本
        if let attributedString = string as? NSAttributedString {
            markedText = attributedString.string
        } else if let plainString = string as? String {
            markedText = plainString
        } else {
            markedText = ""
        }

        // 更新标记范围
        _markedRange = NSRange(location: 0, length: (markedText as NSString).length)
        self._selectedRange = selectedRange

        // 通知协调器
        coordinator.handlePreedit(
            text: markedText,
            cursorPosition: selectedRange.location,
            panelId: panelId
        )
    }

    /// 取消标记文本
    func unmarkText() {
        markedText = ""
        _markedRange = NSRange(location: NSNotFound, length: 0)
        _selectedRange = NSRange(location: NSNotFound, length: 0)
    }

    /// 获取选中范围（NSTextInputClient 协议要求）
    func selectedRange() -> NSRange {
        return _selectedRange
    }

    /// 获取标记范围（NSTextInputClient 协议要求）
    func markedRange() -> NSRange {
        return _markedRange
    }

    /// 是否有标记文本
    func hasMarkedText() -> Bool {
        return _markedRange.location != NSNotFound
    }

    /// 获取属性字符串
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    /// 获取有效属性范围
    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    /// 获取第一个矩形（候选框位置）
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let panelId = currentPanelId,
              let coordinator = windowController?.inputCoordinator,
              let rect = coordinator.getCandidateWindowRect(panelId: panelId),
              let window = window else {
            return NSRect.zero
        }

        // 转换为屏幕坐标
        let screenRect = window.convertToScreen(rect)
        return screenRect
    }

    /// 获取字符索引
    func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }

    /// 是否支持属性字符串
    func attributedString() -> NSAttributedString {
        return NSAttributedString(string: markedText)
    }

    /// 获取基线偏移
    func baselineDeltaForCharacter(at anIndex: Int) -> CGFloat {
        return 0.0
    }

    /// 获取窗口级别
    func windowLevel() -> Int {
        return Int(NSWindow.Level.floating.rawValue)
    }

    /// 绘制标记文本（可选）
    func drawsVerticallyForCharacter(at charIndex: Int) -> Bool {
        return false
    }

    /// 获取分数（用于候选词排序）
    func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat {
        return 0.0
    }
}
