//
//  TerminalWindowCoordinator.swift
//  ETerm
//
//  基础设施层 - 终端窗口协调器（DDD 架构）
//
//  职责：
//  - 连接 Domain AR 和基础设施层
//  - 管理终端生命周期
//  - 协调渲染流程
//
//  架构原则：
//  - Domain AR 是唯一的状态来源
//  - UI 层不持有状态，只负责显示和捕获输入
//  - 数据流单向：AR → UI → 用户事件 → AR
//

import Foundation
import AppKit
import CoreGraphics
import Combine
import PanelLayoutKit

/// 渲染视图协议 - 统一不同的 RenderView 实现
protocol RenderViewProtocol: AnyObject {
    func requestRender()
}

/// 终端窗口协调器（DDD 架构）
class TerminalWindowCoordinator: ObservableObject {
    // MARK: - Domain Aggregates

    /// 终端窗口聚合根（唯一的状态来源）
    @Published private(set) var terminalWindow: TerminalWindow

    /// 更新触发器 - 用于触发 SwiftUI 的 updateNSView
    @Published var updateTrigger = UUID()

    /// 当前激活的 Panel ID（用于键盘输入）
    private(set) var activePanelId: UUID?

    // MARK: - Infrastructure

    /// 终端池（基础设施）
    private var terminalPool: TerminalPoolProtocol

    /// 坐标映射器
    private(set) var coordinateMapper: CoordinateMapper?

    /// 字体度量
    private var fontMetrics: SugarloafFontMetrics?

    /// 渲染视图引用
    weak var renderView: RenderViewProtocol?

    // MARK: - Constants

    private let headerHeight: CGFloat = 30.0

    // MARK: - Initialization

    init(initialWindow: TerminalWindow, terminalPool: TerminalPoolProtocol? = nil) {
        self.terminalWindow = initialWindow
        self.terminalPool = terminalPool ?? MockTerminalPool()

        // 为初始的所有 Tab 创建终端
        createTerminalsForAllTabs()

        // 设置初始激活的 Panel 为第一个 Panel
        activePanelId = initialWindow.allPanels.first?.panelId
    }

    deinit {
        print("[TerminalWindowCoordinator] 析构，清理所有终端")
        // 关闭所有终端
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    terminalPool.closeTerminal(Int(terminalId))
                }
            }
        }
    }

    // MARK: - Terminal Pool Management

    /// 设置终端池（由 PanelRenderView 初始化后调用）
    func setTerminalPool(_ pool: TerminalPoolProtocol) {
        print("[TerminalWindowCoordinator] 切换到真实终端池")

        // 关闭旧终端池的所有终端，并清空 rustTerminalId
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                if let terminalId = tab.rustTerminalId {
                    terminalPool.closeTerminal(Int(terminalId))
                    tab.setRustTerminalId(nil)  // 清空 ID，准备重新分配
                }
            }
        }

        // 切换到新终端池
        self.terminalPool = pool

        // 重新创建所有终端
        createTerminalsForAllTabs()
    }

    /// 设置坐标映射器（初始化时使用）
    func setCoordinateMapper(_ mapper: CoordinateMapper) {
        self.coordinateMapper = mapper
        print("[TerminalWindowCoordinator] 设置 CoordinateMapper: scale=\(mapper.scale), bounds=\(mapper.logicalContainerSize)")
    }

    /// 更新坐标映射器（容器尺寸变化时使用）
    func updateCoordinateMapper(scale: CGFloat, containerBounds: CGRect) {
        self.coordinateMapper = CoordinateMapper(scale: scale, containerBounds: containerBounds)
        print("[TerminalWindowCoordinator] 更新 CoordinateMapper: scale=\(scale), bounds=\(containerBounds)")
    }

    /// 更新字体度量
    func updateFontMetrics(_ metrics: SugarloafFontMetrics) {
        self.fontMetrics = metrics
        print("[TerminalWindowCoordinator] 更新 FontMetrics: cellWidth=\(metrics.cell_width), cellHeight=\(metrics.cell_height)")
    }

    // MARK: - Terminal Lifecycle

    /// 为所有 Tab 创建终端
    private func createTerminalsForAllTabs() {
        for panel in terminalWindow.allPanels {
            for tab in panel.tabs {
                // 如果 Tab 还没有终端，创建一个
                if tab.rustTerminalId == nil {
                    let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                    if terminalId >= 0 {
                        tab.setRustTerminalId(UInt32(terminalId))
                        print("[TerminalWindowCoordinator] 为 Tab \(tab.tabId.uuidString.prefix(8)) 创建终端 \(terminalId)")
                    } else {
                        print("[TerminalWindowCoordinator] 创建终端失败")
                    }
                }
            }
        }
    }

    /// 创建新的 Tab 并分配终端
    func createNewTab(in panelId: UUID) -> TerminalTab? {
        let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
        guard terminalId >= 0 else {
            print("[TerminalWindowCoordinator] 创建终端失败")
            return nil
        }

        guard let panel = terminalWindow.getPanel(panelId) else {
            print("[TerminalWindowCoordinator] Panel 不存在: \(panelId)")
            return nil
        }

        let tabNumber = panel.tabCount + 1
        let newTab = TerminalTab(
            tabId: UUID(),
            title: "终端 \(tabNumber)",
            rustTerminalId: UInt32(terminalId)
        )

        panel.addTab(newTab)
        print("[TerminalWindowCoordinator] 创建新 Tab，终端 ID: \(terminalId)")

        return newTab
    }

    // MARK: - User Interactions (从 UI 层调用)

    /// 用户点击 Tab
    func handleTabClick(panelId: UUID, tabId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            print("[TerminalWindowCoordinator] Panel 不存在: \(panelId)")
            return
        }

        // 检查是否已经是激活的 Tab
        if panel.activeTabId == tabId {
            print("[TerminalWindowCoordinator] Tab 已激活，忽略点击")
            return
        }

        // 调用 AR 的方法切换 Tab
        if panel.setActiveTab(tabId) {
            print("[TerminalWindowCoordinator] 切换到 Tab: \(tabId.uuidString.prefix(8))")
            // 触发渲染更新
            objectWillChange.send()
            updateTrigger = UUID()
            renderView?.requestRender()
        }
    }

    /// 设置激活的 Panel（用于键盘输入）
    func setActivePanel(_ panelId: UUID) {
        guard terminalWindow.getPanel(panelId) != nil else {
            print("[TerminalWindowCoordinator] Panel 不存在: \(panelId)")
            return
        }

        if activePanelId != panelId {
            activePanelId = panelId
            print("[TerminalWindowCoordinator] 激活 Panel: \(panelId.uuidString.prefix(8))")
        }
    }

    /// 用户关闭 Tab
    func handleTabClose(panelId: UUID, tabId: UUID) {
        guard let panel = terminalWindow.getPanel(panelId) else {
            print("[TerminalWindowCoordinator] Panel 不存在: \(panelId)")
            return
        }

        // 获取 Tab 的终端 ID，关闭终端
        if let tab = panel.tabs.first(where: { $0.tabId == tabId }),
           let terminalId = tab.rustTerminalId {
            terminalPool.closeTerminal(Int(terminalId))
            print("[TerminalWindowCoordinator] 关闭终端 \(terminalId)")
        }

        // 调用 AR 的方法关闭 Tab
        if panel.closeTab(tabId) {
            print("[TerminalWindowCoordinator] 关闭 Tab: \(tabId.uuidString.prefix(8))")
            objectWillChange.send()
            updateTrigger = UUID()
            renderView?.requestRender()
        } else {
            print("[TerminalWindowCoordinator] 关闭 Tab 失败（可能是最后一个 Tab）")
        }
    }

    /// 用户添加 Tab
    func handleAddTab(panelId: UUID) {
        guard let newTab = createNewTab(in: panelId) else {
            return
        }

        // 切换到新 Tab
        if let panel = terminalWindow.getPanel(panelId) {
            _ = panel.setActiveTab(newTab.tabId)
        }

        // 设置为激活的 Panel
        setActivePanel(panelId)

        objectWillChange.send()
        updateTrigger = UUID()
        renderView?.requestRender()
    }

    /// 用户分割 Panel
    func handleSplitPanel(panelId: UUID, direction: SplitDirection) {
        // 使用 BinaryTreeLayoutCalculator 计算新布局
        let layoutCalculator = BinaryTreeLayoutCalculator()

        if let newPanelId = terminalWindow.splitPanel(
            panelId: panelId,
            direction: direction,
            layoutCalculator: layoutCalculator
        ) {
            print("[TerminalWindowCoordinator] 分割 Panel 成功，新 Panel: \(newPanelId.uuidString.prefix(8))")

            // 为新 Panel 的默认 Tab 创建终端
            if let newPanel = terminalWindow.getPanel(newPanelId) {
                for tab in newPanel.tabs {
                    if tab.rustTerminalId == nil {
                        let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
                        if terminalId >= 0 {
                            tab.setRustTerminalId(UInt32(terminalId))
                            print("[TerminalWindowCoordinator] 为新 Panel 的 Tab 创建终端 \(terminalId)")
                        }
                    }
                }
            }

            // 设置新 Panel 为激活状态
            setActivePanel(newPanelId)

            objectWillChange.send()
            updateTrigger = UUID()
            renderView?.requestRender()
        }
    }

    // MARK: - Drag & Drop

    /// 处理 Tab 拖拽 Drop
    ///
    /// - Parameters:
    ///   - tabId: 被拖拽的 Tab ID
    ///   - dropZone: Drop Zone
    ///   - targetPanelId: 目标 Panel ID
    /// - Returns: 是否成功处理
    func handleDrop(tabId: UUID, dropZone: DropZone, targetPanelId: UUID) -> Bool {
        print("[TerminalWindowCoordinator] 🎯 handleDrop:")
        print("  Tab ID: \(tabId.uuidString.prefix(8))")
        print("  DropZone: \(dropZone.type)")
        print("  InsertIndex: \(dropZone.insertIndex?.description ?? "nil")")
        print("  Target Panel: \(targetPanelId.uuidString.prefix(8))")

        // 1. 找到源 Panel 和 Tab
        guard let sourcePanel = terminalWindow.allPanels.first(where: { panel in
            panel.tabs.contains(where: { $0.tabId == tabId })
        }),
              let tab = sourcePanel.tabs.first(where: { $0.tabId == tabId }) else {
            print("[TerminalWindowCoordinator] ❌ 找不到源 Tab")
            return false
        }

        // 2. 找到目标 Panel
        guard let targetPanel = terminalWindow.getPanel(targetPanelId) else {
            print("[TerminalWindowCoordinator] ❌ 找不到目标 Panel")
            return false
        }

        // 3. 根据 DropZone 类型处理
        switch dropZone.type {
        case .header:
            // Tab 合并：移动到目标 Panel
            if sourcePanel.panelId == targetPanel.panelId {
                // 同一个 Panel 内部移动（重新排序）
                print("[TerminalWindowCoordinator] ⚠️ 同一 Panel 内 Tab 重新排序暂未实现")
                return false
            } else {
                // 跨 Panel 移动
                if !sourcePanel.closeTab(tabId) {
                    print("[TerminalWindowCoordinator] ❌ 关闭源 Tab 失败")
                    return false
                }
                targetPanel.addTab(tab)
                _ = targetPanel.setActiveTab(tabId)

                print("[TerminalWindowCoordinator] ✅ Tab 跨 Panel 移动成功")
            }

        case .body:
            // 合并到中心（同 .header）
            if sourcePanel.panelId != targetPanel.panelId {
                if !sourcePanel.closeTab(tabId) {
                    return false
                }
                targetPanel.addTab(tab)
                _ = targetPanel.setActiveTab(tabId)

                print("[TerminalWindowCoordinator] ✅ Tab 移动到空 Panel 成功")
            }

        case .left, .right, .top, .bottom:
            // 拖拽到边缘 → 分割 Panel
            print("[TerminalWindowCoordinator] 🔀 拖拽到边缘，分割 Panel")

            // 1. 确定分割方向
            let splitDirection: SplitDirection = {
                switch dropZone.type {
                case .left, .right:
                    return .horizontal  // 左右分割
                case .top, .bottom:
                    return .vertical    // 上下分割
                default:
                    fatalError("不应该到达这里")
                }
            }()

            // 2. 分割目标 Panel
            let layoutCalculator = BinaryTreeLayoutCalculator()
            guard let newPanelId = terminalWindow.splitPanel(
                panelId: targetPanelId,
                direction: splitDirection,
                layoutCalculator: layoutCalculator
            ) else {
                print("[TerminalWindowCoordinator] ❌ 分割 Panel 失败")
                return false
            }

            print("[TerminalWindowCoordinator] ✅ 分割成功，新 Panel: \(newPanelId.uuidString.prefix(8))")

            // 3. 获取新 Panel
            guard let newPanel = terminalWindow.getPanel(newPanelId) else {
                print("[TerminalWindowCoordinator] ❌ 找不到新 Panel")
                return false
            }

            // 4. 将拖拽的 Tab 移动到新 Panel
            // 4.1 添加到新 Panel（此时新 Panel 有 2 个 Tab：默认 Tab + 拖拽的 Tab）
            newPanel.addTab(tab)
            _ = newPanel.setActiveTab(tabId)

            // 4.2 删除新 Panel 的默认 Tab
            if let defaultTab = newPanel.tabs.first(where: { $0.tabId != tabId }) {
                // 关闭默认 Tab 的终端（如果已创建）
                if let terminalId = defaultTab.rustTerminalId {
                    terminalPool.closeTerminal(Int(terminalId))
                }
                // 删除默认 Tab（因为我们刚添加了拖拽的 Tab，现在有 2 个，可以删除）
                _ = newPanel.closeTab(defaultTab.tabId)
                print("[TerminalWindowCoordinator] 删除新 Panel 的默认 Tab")
            }

            // 4.3 从源 Panel 移除拖拽的 Tab
            if !sourcePanel.closeTab(tabId) {
                print("[TerminalWindowCoordinator] ❌ 关闭源 Tab 失败")
                return false
            }

            print("[TerminalWindowCoordinator] ✅ Tab 移动到新 Panel 成功")
        }

        // 4. 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        renderView?.requestRender()

        return true
    }

    // MARK: - Input Handling

    /// 获取当前激活的终端 ID
    func getActiveTerminalId() -> UInt32? {
        // 使用激活的 Panel
        guard let activePanelId = activePanelId,
              let panel = terminalWindow.getPanel(activePanelId),
              let activeTab = panel.activeTab else {
            // 如果没有激活的 Panel，fallback 到第一个
            return terminalWindow.allPanels.first?.activeTab?.rustTerminalId
        }

        return activeTab.rustTerminalId
    }

    /// 写入输入到指定终端
    func writeInput(terminalId: UInt32, data: String) {
        terminalPool.writeInput(terminalId: Int(terminalId), data: data)
    }

    // MARK: - Mouse Event Helpers

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

    /// 处理滚动
    func handleScroll(terminalId: UInt32, deltaLines: Int32) {
        guard let terminalPoolWrapper = terminalPool as? TerminalPoolWrapper else {
            return
        }

        _ = terminalPoolWrapper.scroll(terminalId: Int(terminalId), deltaLines: deltaLines)
        renderView?.requestRender()
    }

    // MARK: - Rendering (核心方法)

    /// 渲染所有 Panel
    ///
    /// 单向数据流：从 AR 拉取数据，调用 Rust 渲染
    func renderAllPanels(containerBounds: CGRect) {
        print("[TerminalWindowCoordinator] 📏 收到 containerBounds = \(containerBounds)")

        guard let mapper = coordinateMapper,
              let metrics = fontMetrics else {
            print("[TerminalWindowCoordinator] 坐标映射器或字体度量未初始化")
            return
        }

        // 更新 coordinateMapper 的 containerBounds
        // 确保坐标转换使用最新的容器尺寸（窗口 resize 后）
        updateCoordinateMapper(scale: mapper.scale, containerBounds: containerBounds)

        // 从 AR 获取所有需要渲染的 Tab
        let tabsToRender = terminalWindow.getActiveTabsForRendering(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        )

        print("[TerminalWindowCoordinator] 渲染 \(tabsToRender.count) 个 Tab")

        // 渲染每个 Tab
        guard let terminalPoolWrapper = terminalPool as? TerminalPoolWrapper else {
            // MockTerminalPool，跳过渲染
            return
        }

        for (terminalId, contentBounds) in tabsToRender {
            // Swift 坐标 → Rust 物理坐标（用于计算网格）
            let physicalRect = mapper.swiftToRustPhysical(rect: contentBounds)
            
            // Swift 坐标 → Rust 逻辑坐标（用于渲染位置，Sugarloaf 会自动处理 scale）
            let logicalRect = mapper.swiftToRust(rect: contentBounds)

            // 计算终端网格尺寸（fontMetrics 返回的是逻辑点，所以用逻辑尺寸计算）
            let cellWidth = CGFloat(metrics.cell_width)
            let cellHeight = CGFloat(metrics.cell_height)
            let cols = UInt16(logicalRect.width / cellWidth)
            let rows = UInt16(logicalRect.height / cellHeight)

            print("[TerminalWindowCoordinator] 渲染终端 \(terminalId)")
            print("  Swift Rect: \(contentBounds)")
            print("  Physical Rect: \(physicalRect)")
            print("  Logical Rect: \(logicalRect)")
            print("  Cell: \(cellWidth)×\(cellHeight), Grid: \(cols)×\(rows)")

            let success = terminalPoolWrapper.render(
                terminalId: Int(terminalId),
                x: Float(logicalRect.origin.x),
                y: Float(logicalRect.origin.y),
                width: Float(logicalRect.width),
                height: Float(logicalRect.height),
                cols: cols,
                rows: rows
            )

            if !success {
                print("[TerminalWindowCoordinator] 渲染失败: 终端 \(terminalId)")
            }
        }

        // 统一提交所有 objects
        terminalPoolWrapper.flush()
        print("[TerminalWindowCoordinator] 提交了 \(tabsToRender.count) 个终端的渲染内容")
    }
}
