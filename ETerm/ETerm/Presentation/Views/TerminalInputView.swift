//
//  TerminalInputView.swift
//  ETerm
//
//  表示层 - NSTextInputClient 实现
//
//  职责：
//  - 实现 NSTextInputClient 协议
//  - 处理 IME 输入事件
//  - 与 InputCoordinator 协作
//

import AppKit
import Foundation

/// Terminal 输入视图
///
/// 实现 NSTextInputClient 协议，支持 IME 输入
class TerminalInputView: NSView {
    // MARK: - Dependencies

    weak var windowController: WindowController?
    var inputCoordinator: InputCoordinator?

    // MARK: - IME 状态

    /// 标记文本范围（预编辑文本）
    private var markedText: String = ""

    /// 选中的范围（内部存储）
    private var _selectedRange: NSRange = NSRange(location: NSNotFound, length: 0)

    /// 标记范围（内部存储）
    private var _markedRange: NSRange = NSRange(location: NSNotFound, length: 0)

    /// 当前的 Panel ID
    var currentPanelId: UUID?

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
        // 允许成为第一响应者（接收键盘输入）
        // 这个在 macOS 中是必须的
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

// MARK: - NSTextInputClient

extension TerminalInputView: NSTextInputClient {
    /// 插入文本（非 IME 输入）
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String,
              let panelId = currentPanelId,
              let coordinator = inputCoordinator else {
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
              let coordinator = inputCoordinator else {
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
        _selectedRange = selectedRange

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

    /// 是否有标记文本
    func hasMarkedText() -> Bool {
        return _markedRange.location != NSNotFound
    }

    /// 获取选中范围（NSTextInputClient 协议要求）
    func selectedRange() -> NSRange {
        return _selectedRange
    }

    /// 获取标记范围（NSTextInputClient 协议要求）
    func markedRange() -> NSRange {
        return _markedRange
    }

    /// 获取属性字符串
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // 终端不需要返回子字符串
        return nil
    }

    /// 获取有效属性范围
    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        // 返回空数组，表示不支持属性
        return []
    }

    /// 获取第一个矩形（候选框位置）
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let panelId = currentPanelId,
              let coordinator = inputCoordinator,
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
        // 终端不需要实现这个方法
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

// MARK: - Key Events

extension TerminalInputView {
    /// 处理按键事件
    override func keyDown(with event: NSEvent) {
        // 解释键盘事件（让输入法处理）
        interpretKeyEvents([event])
    }

    /// 处理输入
    override func doCommand(by selector: Selector) {
        // 处理特殊命令（如 Escape、Enter）
        if selector == #selector(cancelOperation(_:)) {
            // Escape 键
            if let panelId = currentPanelId,
               let coordinator = inputCoordinator {
                coordinator.handleCancelPreedit(panelId: panelId)
            }
        }

        // 其他命令传递给父视图
        super.doCommand(by: selector)
    }
}
