//
//  TerminalWindowCoordinator+Input.swift
//  ETerm
//
//  MARK: - Input Handling
//
//  职责：处理用户输入
//  - 键盘输入写入终端
//  - 鼠标滚动处理
//  - 鼠标位置到 Panel 的映射
//
//  注：查询方法已迁移到 +Query.swift
//

import Foundation
import CoreGraphics

// MARK: - Input Handling

extension TerminalWindowCoordinator {

    /// 写入输入到指定终端
    func writeInput(terminalId: Int, data: String) {
        writeInputInternal(terminalId: terminalId, data: data)
        // 不主动触发渲染，依赖 Wakeup 事件（终端有输出时自动触发）
    }

    /// 写入输入（统一入口）
    @discardableResult
    func writeInputInternal(terminalId: Int, data: String) -> Bool {
        return terminalPool.writeInput(terminalId: terminalId, data: data)
    }

    /// 滚动（统一入口）
    @discardableResult
    func scrollInternal(terminalId: Int, deltaLines: Int32) -> Bool {
        return terminalPool.scroll(terminalId: terminalId, deltaLines: deltaLines)
    }

    /// 处理滚动
    func handleScroll(terminalId: Int, deltaLines: Int32) {
        _ = scrollInternal(terminalId: terminalId, deltaLines: deltaLines)
        renderView?.requestRender()
    }
}

// MARK: - Mouse Event Helpers

extension TerminalWindowCoordinator {

    /// 根据滚轮事件位置获取应滚动的终端 ID（鼠标所在 Panel 的激活 Tab）
    /// - Parameters:
    ///   - point: 鼠标位置（容器坐标，PageBar 下方区域）
    ///   - containerBounds: 容器区域（PageBar 下方区域）
    /// - Returns: 目标终端 ID，如果找不到则返回当前激活终端
    func getTerminalIdAtPoint(_ point: CGPoint, containerBounds: CGRect) -> Int? {
        if let panelId = findPanel(at: point, containerBounds: containerBounds),
           let panel = terminalWindow.getPanel(panelId),
           let activeTab = panel.activeTab,
           let terminalId = activeTab.rustTerminalId {
            return terminalId
        }

        return getActiveTerminalId()
    }

    /// 根据鼠标位置找到对应的 Panel
    func findPanel(at point: CGPoint, containerBounds: CGRect) -> UUID? {
        // 先更新 Panel bounds
        let _ = terminalWindow.getActiveTabsForRendering(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        )

        // 遍历所有 Panel，找到包含该点的 Panel
        for panel in terminalWindow.allPanels {
            if panel.bounds.contains(point) {
                return panel.panelId
            }
        }

        return nil
    }
}
