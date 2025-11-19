//
//  DragCoordinator.swift
//  ETerm
//
//  拖拽协调器
//
//  负责管理 Tab 的拖拽流程，协调 UI 层和算法层。
//  工作流程：
//  1. 开始拖拽：记录被拖拽的 Tab 和来源 Panel
//  2. 鼠标移动：找到目标 PanelView，让它计算并显示 Drop Zone
//  3. 结束拖拽：调用 PanelLayoutKit 重构布局树
//

import AppKit
import Foundation
import PanelLayoutKit

/// 拖拽协调器
///
/// 管理 Tab 拖拽的完整流程。
final class DragCoordinator {
    // MARK: - 依赖

    /// WindowController 引用
    private weak var windowController: WindowController?

    /// PanelView 映射（Panel ID -> PanelView）
    private var panelViews: [UUID: PanelView] = [:]

    /// PanelLayoutKit 实例
    private let layoutKit: PanelLayoutKit

    // MARK: - 拖拽状态

    /// 被拖拽的 Tab
    private var draggedTab: TabNode?

    /// 来源 Panel ID
    private var sourcePanelId: UUID?

    /// 当前的 Drop Zone
    private var currentDropZone: DropZone?

    /// 目标 Panel ID
    private var targetPanelId: UUID?

    // MARK: - 初始化

    init(windowController: WindowController, layoutKit: PanelLayoutKit) {
        self.windowController = windowController
        self.layoutKit = layoutKit
    }

    // MARK: - Panel 管理

    /// 注册 PanelView
    ///
    /// - Parameters:
    ///   - panelId: Panel ID
    ///   - panelView: PanelView 实例
    func registerPanelView(_ panelId: UUID, panelView: PanelView) {
        panelViews[panelId] = panelView
    }

    /// 注销 PanelView
    ///
    /// - Parameter panelId: Panel ID
    func unregisterPanelView(_ panelId: UUID) {
        panelViews.removeValue(forKey: panelId)
    }

    // MARK: - 拖拽流程

    /// 开始拖拽 Tab
    ///
    /// - Parameters:
    ///   - tab: 被拖拽的 Tab
    ///   - panelId: 来源 Panel ID
    func startDrag(tab: TabNode, fromPanel panelId: UUID) {
        print("[DragCoordinator] 开始拖拽 Tab: \(tab.title) from Panel: \(panelId)")
        draggedTab = tab
        sourcePanelId = panelId
    }

    /// 鼠标移动（拖拽中）
    ///
    /// - Parameter position: 鼠标位置（全局坐标）
    func onMouseMove(position: CGPoint) {
        guard draggedTab != nil else { return }

        // 1. 找到鼠标下方的 PanelView
        guard let targetPanel = findPanelView(at: position) else {
            clearHighlight()
            return
        }

        // 2. 转换鼠标坐标到 PanelView 的本地坐标
        let localPosition = targetPanel.convert(position, from: nil)

        // 3. 让 PanelView 自己计算 Drop Zone（充血模型）
        guard let dropZone = targetPanel.calculateDropZone(mousePosition: localPosition) else {
            clearHighlight()
            return
        }

        // 4. 让 PanelView 自己显示高亮
        targetPanel.highlightDropZone(dropZone)

        // 5. 记录状态
        currentDropZone = dropZone
        targetPanelId = targetPanel.panel.id

        print("[DragCoordinator] Drop Zone: \(dropZone.type) at Panel: \(targetPanel.panel.id)")
    }

    /// 结束拖拽
    func endDrag() {
        guard let tab = draggedTab,
              let sourceId = sourcePanelId,
              let zone = currentDropZone,
              let targetId = targetPanelId else {
            print("[DragCoordinator] 结束拖拽失败：状态不完整")
            cleanup()
            return
        }

        print("[DragCoordinator] 结束拖拽：\(tab.title) -> \(zone.type)")

        // TODO: 调用 WindowController 更新布局
        // 这里需要 WindowController 提供类似的接口：
        // windowController?.handleTabDrop(tab: tab, sourcePanel: sourceId, dropZone: zone, targetPanel: targetId)

        // 清理状态
        cleanup()
    }

    // MARK: - Private Methods

    /// 查找鼠标位置处的 PanelView
    ///
    /// - Parameter point: 全局坐标
    /// - Returns: 找到的 PanelView，如果没有找到返回 nil
    private func findPanelView(at point: CGPoint) -> PanelView? {
        return panelViews.values.first { panelView in
            // 将全局坐标转换为 PanelView 的本地坐标
            let localPoint = panelView.convert(point, from: nil)
            return panelView.bounds.contains(localPoint)
        }
    }

    /// 清除所有高亮
    private func clearHighlight() {
        panelViews.values.forEach { $0.clearHighlight() }
    }

    /// 清理拖拽状态
    private func cleanup() {
        draggedTab = nil
        sourcePanelId = nil
        currentDropZone = nil
        targetPanelId = nil
        clearHighlight()
    }
}

// MARK: - WindowController Extension

extension WindowController {
    /// 处理 Tab 拖拽
    ///
    /// - Parameters:
    ///   - tab: 被拖拽的 Tab
    ///   - sourcePanel: 来源 Panel ID
    ///   - dropZone: Drop Zone
    ///   - targetPanel: 目标 Panel ID
    func handleTabDrop(
        tab: TabNode,
        sourcePanel: UUID,
        dropZone: DropZone,
        targetPanel: UUID
    ) {
        print("[WindowController] 处理 Tab Drop: \(tab.title)")
        print("  来源 Panel: \(sourcePanel)")
        print("  目标 Panel: \(targetPanel)")
        print("  Drop Zone: \(dropZone.type)")

        // TODO: 实现布局树重构逻辑
        // 1. 从 sourcePanel 移除 tab
        // 2. 根据 dropZone 类型决定如何添加到 targetPanel
        // 3. 更新 window.rootLayout
        // 4. 触发 UI 重新渲染
    }
}
