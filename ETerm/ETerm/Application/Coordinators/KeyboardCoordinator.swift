//
//  KeyboardCoordinator.swift
//  ETerm
//
//  应用层 - 键盘协调器
//
//  职责：
//  - 处理键盘事件（快捷键、方向键等）
//  - 协调选中、复制、粘贴等操作
//  - 与其他协调器配合（如 TextSelectionCoordinator）
//

import AppKit
import Foundation

/// 键盘协调器
///
/// 负责处理所有键盘相关的事件
final class KeyboardCoordinator {
    // MARK: - Dependencies

    private weak var windowController: WindowController?
    private let selectionCoordinator: TextSelectionCoordinator

    // MARK: - Initialization

    init(
        windowController: WindowController,
        selectionCoordinator: TextSelectionCoordinator
    ) {
        self.windowController = windowController
        self.selectionCoordinator = selectionCoordinator
    }

    // MARK: - 键盘事件处理

    /// 处理按键按下事件
    ///
    /// - Parameters:
    ///   - event: 键盘事件
    ///   - panelId: Panel ID
    /// - Returns: 是否已处理该事件
    func handleKeyDown(event: NSEvent, panelId: UUID) -> Bool {
        // Cmd+C: 复制
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            handleCopy(panelId: panelId)
            return true
        }

        // Cmd+V: 粘贴
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            handlePaste(panelId: panelId)
            return true
        }

        // Shift + 方向键: 扩展选中
        if event.modifierFlags.contains(.shift) && isArrowKey(event) {
            if let direction = getDirection(from: event) {
                selectionCoordinator.handleShiftArrowKey(
                    direction: direction,
                    panelId: panelId
                )
                return true
            }
        }

        // 纯方向键: 清除选中
        if isArrowKey(event) && !event.modifierFlags.contains(.shift) {
            handleArrowKey(event: event, panelId: panelId)
            return true
        }

        // Escape: 清除选中
        if event.keyCode == 53 {  // Escape key
            clearSelection(panelId: panelId)
            return true
        }

        // 其他键：如果有选中，根据情况处理
        if let panel = windowController?.getPanel(panelId),
           let activeTab = panel.activeTab,
           activeTab.hasSelection() {
            // 如果选中在输入行，输入会替换选中
            // 这个逻辑在 InputCoordinator 中处理
        }

        return false
    }

    // MARK: - 快捷键处理

    /// 处理复制（Cmd+C）
    ///
    /// - Parameter panelId: Panel ID
    private func handleCopy(panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab,
              activeTab.hasSelection() else {
            return
        }

        // 获取选中的文本
        guard let text = activeTab.getSelectedText() else {
            return
        }

        // 写入剪贴板
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        print("[KeyboardCoordinator] 已复制: \(text.prefix(50))...")
    }

    /// 处理粘贴（Cmd+V）
    ///
    /// - Parameter panelId: Panel ID
    private func handlePaste(panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 从剪贴板读取
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else {
            return
        }

        // 插入文本（会自动处理选中替换）
        activeTab.insertText(text)

        print("[KeyboardCoordinator] 已粘贴: \(text.prefix(50))...")
    }

    // MARK: - 方向键处理

    /// 处理方向键（清除选中）
    ///
    /// - Parameters:
    ///   - event: 键盘事件
    ///   - panelId: Panel ID
    private func handleArrowKey(event: NSEvent, panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 清除选中
        activeTab.clearSelection()

        // 移动光标（如果需要的话，目前由终端自己处理）
        // let direction = getDirection(from: event)
        // activeTab.moveCursor(direction: direction)
    }

    /// 清除选中
    ///
    /// - Parameter panelId: Panel ID
    private func clearSelection(panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        activeTab.clearSelection()
    }

    // MARK: - Helper Methods

    /// 判断是否是方向键
    ///
    /// - Parameter event: 键盘事件
    /// - Returns: 是否是方向键
    private func isArrowKey(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        return keyCode == 123 ||  // Left
               keyCode == 124 ||  // Right
               keyCode == 125 ||  // Down
               keyCode == 126     // Up
    }

    /// 从键盘事件获取方向
    ///
    /// - Parameter event: 键盘事件
    /// - Returns: 方向，如果不是方向键返回 nil
    private func getDirection(from event: NSEvent) -> Direction? {
        switch event.keyCode {
        case 126:  // Up
            return .up
        case 125:  // Down
            return .down
        case 123:  // Left
            return .left
        case 124:  // Right
            return .right
        default:
            return nil
        }
    }
}

// MARK: - NSEvent Extension

extension NSEvent {
    /// 是否是方向键
    var isArrowKey: Bool {
        let keyCode = self.keyCode
        return keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126
    }
}
