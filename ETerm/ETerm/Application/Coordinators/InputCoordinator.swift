//
//  InputCoordinator.swift
//  ETerm
//
//  应用层 - 输入协调器
//
//  职责：
//  - 处理 NSTextInputClient 事件
//  - 协调 IME 输入与终端 Tab 的交互
//  - 计算候选框位置
//  - 处理预编辑文本和确认输入
//

import AppKit
import Foundation

/// 输入协调器
///
/// 负责 IME 输入的完整流程
final class InputCoordinator {
    // MARK: - Dependencies

    private weak var windowController: WindowController?
    private let coordinateMapper: CoordinateMapper

    // MARK: - Configuration

    private let cellWidth: CGFloat
    private let cellHeight: CGFloat

    // MARK: - Initialization

    init(
        windowController: WindowController,
        coordinateMapper: CoordinateMapper,
        cellWidth: CGFloat = 9.6,
        cellHeight: CGFloat = 20.0
    ) {
        self.windowController = windowController
        self.coordinateMapper = coordinateMapper
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
    }

    // MARK: - IME 输入处理

    /// 处理预编辑文本（Preedit）
    ///
    /// 当用户在输入法中输入拼音时调用
    ///
    /// - Parameters:
    ///   - text: 预编辑文本（如 "nihao"）
    ///   - cursorPosition: 光标位置
    ///   - panelId: Panel ID
    func handlePreedit(text: String, cursorPosition: Int, panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 更新预编辑文本
        activeTab.updatePreedit(text: text, cursor: cursorPosition)

        print("[InputCoordinator] Preedit: \(text), cursor: \(cursorPosition)")
    }

    /// 处理确认输入（Commit）
    ///
    /// 当用户选择候选词或按空格确认时调用
    ///
    /// - Parameters:
    ///   - text: 确认的文本（如 "你好"）
    ///   - panelId: Panel ID
    func handleCommit(text: String, panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 确认输入（会自动处理选中替换）
        activeTab.commitInput(text: text)

        print("[InputCoordinator] Commit: \(text)")
    }

    /// 取消预编辑（用户按 Escape）
    ///
    /// - Parameter panelId: Panel ID
    func handleCancelPreedit(panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        activeTab.cancelPreedit()

        print("[InputCoordinator] Cancel preedit")
    }

    // MARK: - 候选框位置计算

    /// 获取候选框位置
    ///
    /// 基于当前光标位置计算候选框应该显示的位置
    ///
    /// - Parameter panelId: Panel ID
    /// - Returns: 候选框位置（NSRect），如果无法计算返回 nil
    func getCandidateWindowRect(panelId: UUID) -> NSRect? {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab,
              let bounds = windowController?.panelBounds[panelId] else {
            return nil
        }

        // 获取光标位置
        let cursorPosition = activeTab.cursorState.position

        // 转换为屏幕坐标
        let cursorRect = coordinateMapper.gridToScreen(
            position: cursorPosition,
            panelOrigin: CGPoint(x: bounds.x, y: bounds.y),
            panelHeight: bounds.height,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )

        // 候选框显示在光标下方
        return NSRect(
            x: cursorRect.origin.x,
            y: cursorRect.origin.y - cellHeight,  // 显示在光标下方
            width: cellWidth,
            height: cellHeight
        )
    }

    /// 获取标记范围（用于 NSTextInputClient）
    ///
    /// 返回预编辑文本的显示范围
    ///
    /// - Parameter panelId: Panel ID
    /// - Returns: 标记范围的矩形
    func getMarkedRect(panelId: UUID) -> NSRect? {
        // 与候选框位置相同
        return getCandidateWindowRect(panelId: panelId)
    }

    // MARK: - 输入焦点管理

    /// 判断是否可以接受输入
    ///
    /// - Parameter panelId: Panel ID
    /// - Returns: 是否可以接受输入
    func canAcceptInput(panelId: UUID) -> Bool {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return false
        }

        // 检查 Tab 是否激活
        return activeTab.isActive
    }

    /// 处理普通文本输入（非 IME）
    ///
    /// - Parameters:
    ///   - text: 输入的文本
    ///   - panelId: Panel ID
    func handleTextInput(text: String, panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 插入文本（会自动处理选中替换）
        activeTab.insertText(text)

        print("[InputCoordinator] Text input: \(text)")
    }
}
