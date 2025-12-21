//
//  TerminalWindowCoordinator+Layout.swift
//  ETerm
//
//  MARK: - Layout Synchronization & Rendering
//
//  职责：布局同步和渲染管理
//  - 布局同步到 Rust 层
//  - 渲染调度（防抖）
//  - 坐标映射器管理
//  - 分隔线比例管理
//

import Foundation
import CoreGraphics
import Combine
import PanelLayoutKit

// MARK: - Layout Synchronization

extension TerminalWindowCoordinator {

    /// 同步布局到 Rust 层
    ///
    /// 这是布局变化的统一入口，只在以下情况调用：
    /// - 窗口 resize
    /// - DPI 变化
    /// - 创建/关闭 Tab/Page
    /// - 切换 Page/Tab
    /// - 分栏/合并 Panel
    ///
    /// 调用时机：布局变化时主动触发，而非每帧调用
    ///
    /// 注意：新架构中，布局同步在渲染过程中自动处理（通过 renderTerminal()）
    /// 这里只需要触发渲染更新即可
    func syncLayoutToRust() {
        // 新架构：布局同步已集成到 renderAllPanels() 中
        // 这里只需触发一次渲染更新
        scheduleRender()
    }
}

// MARK: - Render Scheduling

extension TerminalWindowCoordinator {

    /// 调度渲染（带防抖）
    ///
    /// 在短时间窗口内的多次调用会被合并为一次实际渲染，
    /// 用于 UI 变更（Tab 切换、Page 切换等）触发的渲染请求。
    ///
    /// - Note: 不影响即时响应（如键盘输入、滚动），这些场景应直接调用 `renderView?.requestRender()`
    func scheduleRender() {
        // 取消之前的延迟任务
        pendingRenderWorkItem?.cancel()

        // 创建新的延迟任务
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.renderView?.requestRender()
        }
        pendingRenderWorkItem = workItem

        // 延迟执行
        DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounceInterval, execute: workItem)
    }
}

// MARK: - Coordinate Mapper Management

extension TerminalWindowCoordinator {

    /// 设置坐标映射器（初始化时使用）
    func setCoordinateMapper(_ mapper: CoordinateMapper) {
        self.coordinateMapper = mapper
    }

    /// 更新坐标映射器（容器尺寸变化时使用）
    func updateCoordinateMapper(scale: CGFloat, containerBounds: CGRect) {
        self.coordinateMapper = CoordinateMapper(scale: scale, containerBounds: containerBounds)
    }

    /// 更新字体度量
    func updateFontMetrics(_ metrics: SugarloafFontMetrics) {
        self.fontMetrics = metrics
    }
}

// MARK: - Rendering

extension TerminalWindowCoordinator {

    /// 渲染所有 Panel
    ///
    /// 单向数据流：从 AR 拉取数据，调用 Rust 渲染
    func renderAllPanels(containerBounds: CGRect) {
        // 如果当前激活的 Page 是插件页面，不需要渲染终端
        if let activePage = terminalWindow.active.page, activePage.isPluginPage {
            return
        }

        let totalStart = CFAbsoluteTimeGetCurrent()

        guard let mapper = coordinateMapper,
              let metrics = fontMetrics else {
            return
        }

        // 更新 coordinateMapper 的 containerBounds
        // 确保坐标转换使用最新的容器尺寸（窗口 resize 后）
        updateCoordinateMapper(scale: mapper.scale, containerBounds: containerBounds)

        // 从 AR 获取所有需要渲染的 Tab
        let getTabsStart = CFAbsoluteTimeGetCurrent()
        let tabsToRender = terminalWindow.getActiveTabsForRendering(
            containerBounds: containerBounds,
            headerHeight: headerHeight
        )
        let getTabsTime = (CFAbsoluteTimeGetCurrent() - getTabsStart) * 1000

        // 清除渲染缓冲区（在渲染新内容前）
        // 这确保切换 Page 时旧内容不会残留
        terminalPool.clear()

        // 渲染每个 Tab
        // PTY 读取在 Rust 侧事件驱动处理，这里只负责渲染

        var renderTimes: [(Int, Double)] = []

        for (terminalId, contentBounds) in tabsToRender {
            let terminalStart = CFAbsoluteTimeGetCurrent()

            // 1. 坐标转换：Swift 坐标 → Rust 逻辑坐标
            // 注意：这里只传递逻辑坐标 (Points)，Sugarloaf 内部会自动乘上 scale。
            // 如果这里传物理像素，会导致双重缩放 (Double Scaling) 问题。
            let logicalRect = mapper.swiftToRust(rect: contentBounds)

            // 2. 网格计算
            // 注意：Sugarloaf 返回的 fontMetrics 是物理像素 (Physical Pixels)
            // cell_width: 字符宽度 (物理)
            // cell_height: 字符高度 (物理)
            // line_height: 行高 (物理，通常 > cell_height)

            let cellWidth = CGFloat(metrics.cell_width)
            let lineHeight = CGFloat(metrics.line_height > 0 ? metrics.line_height : metrics.cell_height)

            // 计算列数：使用物理宽度 / 物理字符宽度
            // 因为 cellWidth 是物理像素，所以必须用 physicalRect.width (或者 logicalRect.width * scale)
            // 这里我们用 logicalRect * scale 来确保一致性
            let physicalWidth = logicalRect.width * mapper.scale
            let cols = UInt16(physicalWidth / cellWidth)

            // 计算行数：使用物理高度 / 物理行高
            let physicalHeight = logicalRect.height * mapper.scale
            let rows = UInt16(physicalHeight / lineHeight)

            let success = terminalPool.render(
                terminalId: Int(terminalId),
                x: Float(logicalRect.origin.x),
                y: Float(logicalRect.origin.y),
                width: Float(logicalRect.width),
                height: Float(logicalRect.height),
                cols: cols,
                rows: rows
            )

            let terminalTime = (CFAbsoluteTimeGetCurrent() - terminalStart) * 1000
            renderTimes.append((Int(terminalId), terminalTime))

            if !success {
                // 渲染失败，静默处理
            }
        }

        // 统一提交所有 objects
        let flushStart = CFAbsoluteTimeGetCurrent()
        terminalPool.flush()
        let flushTime = (CFAbsoluteTimeGetCurrent() - flushStart) * 1000

        let totalTime = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
    }
}

// MARK: - Divider Ratio Management

extension TerminalWindowCoordinator {

    /// 更新分隔线比例
    ///
    /// - Parameters:
    ///   - layoutPath: 从根节点到分割节点的路径（0=first, 1=second）
    ///   - newRatio: 新的比例值（0.1 到 0.9）
    func updateDividerRatio(layoutPath: [Int], newRatio: CGFloat) {
        // 更新 Domain 层的布局
        terminalWindow.updateDividerRatio(path: layoutPath, newRatio: newRatio)

        // 同步布局到 Rust（重新计算所有 Panel 的 bounds）
        syncLayoutToRust()

        // 触发 UI 更新
        objectWillChange.send()
        updateTrigger = UUID()
        scheduleRender()

        // 保存 Session
        WindowManager.shared.saveSession()
    }

    /// 获取指定路径的分割比例
    ///
    /// - Parameter layoutPath: 从根节点到分割节点的路径
    /// - Returns: 当前比例，失败返回 nil
    func getRatioAtPath(_ layoutPath: [Int]) -> CGFloat? {
        return getRatioAtPathInternal(layoutPath, in: terminalWindow.rootLayout)
    }

    /// 递归查找指定路径的比例
    func getRatioAtPathInternal(_ path: [Int], in layout: PanelLayout) -> CGFloat? {
        // 空路径表示根节点
        if path.isEmpty {
            if case .split(_, _, _, let ratio) = layout {
                return ratio
            }
            return nil
        }

        // 继续向下查找
        guard case .split(_, let first, let second, _) = layout else {
            return nil
        }

        // 递归到子节点
        let nextPath = Array(path.dropFirst())
        let nextLayout = path[0] == 0 ? first : second
        return getRatioAtPathInternal(nextPath, in: nextLayout)
    }
}
