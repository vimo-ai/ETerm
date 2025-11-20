//
//  TextSelectionCoordinator.swift
//  ETerm
//
//  应用层 - 文本选中协调器
//
//  职责：
//  - 处理鼠标拖拽选中
//  - 处理 Shift + 方向键选中
//  - 协调 Swift 层和 Rust 层的选中状态
//

import AppKit
import Foundation

/// 文本选中协调器
///
/// 协调鼠标/键盘选中操作与终端 Tab 之间的交互
final class TextSelectionCoordinator {
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

    // MARK: - 鼠标选中

    /// 处理鼠标按下（开始选中）
    ///
    /// - Parameters:
    ///   - screenPoint: 鼠标位置（Swift 坐标系）
    ///   - panelId: Panel ID
    func handleMouseDown(at screenPoint: CGPoint, panelId: UUID) {
        print("[TextSelection] 🖱️ handleMouseDown at: \(screenPoint), panelId: \(panelId)")

        guard let panel = windowController?.getPanel(panelId) else {
            print("[TextSelection] ❌ Panel not found")
            return
        }

        guard let activeTab = panel.activeTab else {
            print("[TextSelection] ❌ No active tab")
            return
        }

        guard let bounds = windowController?.panelBounds[panelId] else {
            print("[TextSelection] ❌ No bounds for panel")
            return
        }

        print("[TextSelection] ✅ Panel found, bounds: \(bounds)")

        // 转换为网格坐标
        let gridPos = coordinateMapper.screenToGrid(
            screenPoint: screenPoint,
            panelOrigin: CGPoint(x: bounds.x, y: bounds.y),
            panelHeight: bounds.height,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )

        print("[TextSelection] 📍 Grid position: (\(gridPos.col), \(gridPos.row))")

        // 调用领域方法
        activeTab.startSelection(at: gridPos)
        print("[TextSelection] ✅ Selection started")

        // 通知 Rust 渲染高亮
        updateRustSelection(tab: activeTab)
        print("[TextSelection] ✅ Rust selection updated")
    }

    /// 处理鼠标拖拽（更新选中）
    ///
    /// - Parameters:
    ///   - screenPoint: 鼠标位置（Swift 坐标系）
    ///   - panelId: Panel ID
    func handleMouseDragged(to screenPoint: CGPoint, panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab,
              let bounds = windowController?.panelBounds[panelId] else {
            return
        }

        // 转换为网格坐标
        let gridPos = coordinateMapper.screenToGrid(
            screenPoint: screenPoint,
            panelOrigin: CGPoint(x: bounds.x, y: bounds.y),
            panelHeight: bounds.height,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )

        // 更新选中
        activeTab.updateSelection(to: gridPos)

        // 通知 Rust 渲染高亮
        updateRustSelection(tab: activeTab)
    }

    /// 处理鼠标松开（结束选中）
    ///
    /// - Parameter panelId: Panel ID
    func handleMouseUp(panelId: UUID) {
        // 目前不需要特殊处理，选中已经完成
        // 未来可以在这里处理双击/三击选中
    }

    // MARK: - Shift + 方向键选中

    /// 处理 Shift + 方向键选中
    ///
    /// - Parameters:
    ///   - direction: 方向
    ///   - panelId: Panel ID
    func handleShiftArrowKey(direction: Direction, panelId: UUID) {
        guard let panel = windowController?.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 如果没有选中，从当前光标位置开始
        if !activeTab.hasSelection() {
            let currentPos = activeTab.cursorState.position
            activeTab.startSelection(at: currentPos)
        }

        // 移动光标并更新选中
        let newCursorPos = activeTab.moveCursor(direction: direction)
        activeTab.updateSelection(to: newCursorPos)

        // 通知 Rust 渲染高亮
        updateRustSelection(tab: activeTab)
    }

    // MARK: - Helper Methods

    /// 更新 Rust 端的选中高亮
    ///
    /// - Parameter tab: 终端 Tab
    private func updateRustSelection(tab: TerminalTab) {
        print("[TextSelection] 🔧 updateRustSelection called")
        print("[TextSelection] 🔧 tab.terminalSession: \(tab.terminalSession != nil ? "exists" : "nil")")

        guard let session = tab.terminalSession as? TerminalSession else {
            print("[TextSelection] ❌ No TerminalSession found!")
            return
        }

        print("[TextSelection] 🔧 tab.textSelection: \(tab.textSelection != nil ? "exists" : "nil")")

        guard let selection = tab.textSelection else {
            // 清除 Rust 的选中高亮
            session.clearSelection()
            return
        }

        // 设置选中高亮
        session.setSelection(selection)
    }
}

