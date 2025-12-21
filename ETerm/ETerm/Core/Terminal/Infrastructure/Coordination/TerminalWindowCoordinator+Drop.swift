//
//  TerminalWindowCoordinator+Drop.swift
//  ETerm
//
//  MARK: - Drop Intent Handling
//
//  职责：处理 Tab/Panel 的拖拽操作
//  - Tab 拖拽到其他 Panel
//  - Tab 拖拽到边缘分栏
//  - Panel 在布局中移动
//

import Foundation
import Combine
import PanelLayoutKit

// MARK: - Drop Intent Handling

extension TerminalWindowCoordinator {

    /// 设置 Drop 意图执行监听
    func setupDropIntentHandler() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExecuteDropIntent(_:)),
            name: .executeDropIntent,
            object: nil
        )
    }

    /// 处理 Drop 意图执行
    @objc func handleExecuteDropIntent(_ notification: Notification) {
        guard let intent = notification.userInfo?["intent"] as? DropIntent else {
            return
        }

        // 标记是否需要 Coordinator 级别的后处理
        // 走 perform() 的命令已自带 effects 处理，不需要额外后处理
        var needsPostProcessing = false

        switch intent {
        case .reorderTabs(let panelId, let tabIds):
            // 通过命令管道执行
            let result = perform(.tab(.reorder(panelId: panelId, order: tabIds)))
            if result.success {
                // 通知视图层应用重排序（视图复用，不重建）
                NotificationCenter.default.post(
                    name: .applyTabReorder,
                    object: nil,
                    userInfo: ["panelId": panelId, "tabIds": tabIds]
                )
            }

        case .moveTabToPanel(let tabId, let sourcePanelId, let targetPanelId):
            // 通过命令管道执行（自动处理搜索状态清理）
            perform(.tab(.move(tabId: tabId, from: sourcePanelId, to: .existingPanel(targetPanelId))))

        case .splitWithNewPanel(let tabId, let sourcePanelId, let targetPanelId, let edge):
            // 需要 layoutCalculator，保留在 Coordinator 层
            executeSplitWithNewPanel(tabId: tabId, sourcePanelId: sourcePanelId, targetPanelId: targetPanelId, edge: edge)
            needsPostProcessing = true

        case .movePanelInLayout(let panelId, let targetPanelId, let edge):
            // 需要 layoutCalculator，保留在 Coordinator 层
            executeMovePanelInLayout(panelId: panelId, targetPanelId: targetPanelId, edge: edge)
            needsPostProcessing = true

        case .moveTabAcrossWindow(let tabId, let sourcePanelId, let sourceWindowNumber, let targetPanelId, let targetWindowNumber):
            // 跨窗口移动由 WindowManager 处理
            WindowManager.shared.moveTab(tabId, from: sourcePanelId, sourceWindowNumber: sourceWindowNumber, to: targetPanelId, targetWindowNumber: targetWindowNumber)
            return
        }

        // 仅对不走命令管道的操作执行后处理
        if needsPostProcessing {
            syncLayoutToRust()
            objectWillChange.send()
            updateTrigger = UUID()
            scheduleRender()
            WindowManager.shared.saveSession()
        }
    }

    /// 执行分割（创建新 Panel）
    func executeSplitWithNewPanel(tabId: UUID, sourcePanelId: UUID, targetPanelId: UUID, edge: EdgeDirection) {
        guard let sourcePanel = terminalWindow.getPanel(sourcePanelId),
              let tab = sourcePanel.tabs.first(where: { $0.tabId == tabId }) else {
            return
        }

        // 1. 从源 Panel 移除 Tab
        _ = sourcePanel.closeTab(tabId)

        // 2. 使用已有 Tab 分割目标 Panel
        let layoutCalculator = BinaryTreeLayoutCalculator()
        guard let newPanelId = terminalWindow.splitPanelWithExistingTab(
            panelId: targetPanelId,
            existingTab: tab,
            edge: edge,
            layoutCalculator: layoutCalculator
        ) else {
            // 分割失败，恢复 Tab 到源 Panel
            sourcePanel.addTab(tab)
            return
        }

        // 设置新 Panel 为激活
        setActivePanel(newPanelId)
    }

    /// 执行 Panel 移动（复用 Panel，不创建新的）
    func executeMovePanelInLayout(panelId: UUID, targetPanelId: UUID, edge: EdgeDirection) {
        let layoutCalculator = BinaryTreeLayoutCalculator()
        if terminalWindow.movePanelInLayout(
            panelId: panelId,
            targetPanelId: targetPanelId,
            edge: edge,
            layoutCalculator: layoutCalculator
        ) {
            // 设置该 Panel 为激活
            setActivePanel(panelId)
        }
    }

    /// 处理 Tab 拖拽 Drop（两阶段模式）
    ///
    /// Phase 1: 只捕获意图，不执行任何模型变更
    /// Phase 2: 在 drag session 结束后执行实际变更
    ///
    /// - Parameters:
    ///   - tabId: 被拖拽的 Tab ID
    ///   - sourcePanelId: 源 Panel ID（从拖拽数据中获取，不再搜索）
    ///   - dropZone: Drop Zone
    ///   - targetPanelId: 目标 Panel ID
    /// - Returns: 是否成功接受 drop
    func handleDrop(tabId: UUID, sourcePanelId: UUID, dropZone: DropZone, targetPanelId: UUID) -> Bool {
        // 验证（不修改模型）
        guard let sourcePanel = terminalWindow.getPanel(sourcePanelId),
              sourcePanel.tabs.contains(where: { $0.tabId == tabId }) else {
            return false
        }

        guard terminalWindow.getPanel(targetPanelId) != nil else {
            return false
        }

        // 同一个 Panel 内部移动交给 PanelHeaderHostingView 处理
        if sourcePanelId == targetPanelId && (dropZone.type == .header || dropZone.type == .body) {
            return false
        }

        // 根据场景创建不同的意图
        let intent: DropIntent
        switch dropZone.type {
        case .header, .body:
            // Tab 合并到目标 Panel
            intent = .moveTabToPanel(tabId: tabId, sourcePanelId: sourcePanelId, targetPanelId: targetPanelId)

        case .left, .right, .top, .bottom:
            // 边缘分栏 - 将 dropZone.type 转换为 EdgeDirection
            let edge: EdgeDirection = {
                switch dropZone.type {
                case .top: return .top
                case .bottom: return .bottom
                case .left: return .left
                case .right: return .right
                default: return .bottom // fallback，不应该发生
                }
            }()

            if sourcePanel.tabCount == 1 {
                // 源 Panel 只有 1 个 Tab → 复用 Panel（关键优化！）
                intent = .movePanelInLayout(panelId: sourcePanelId, targetPanelId: targetPanelId, edge: edge)
            } else {
                // 源 Panel 有多个 Tab → 创建新 Panel
                intent = .splitWithNewPanel(tabId: tabId, sourcePanelId: sourcePanelId, targetPanelId: targetPanelId, edge: edge)
            }
        }

        // 提交意图到队列，等待 drag session 结束后执行
        DropIntentQueue.shared.submit(intent)
        return true
    }
}
