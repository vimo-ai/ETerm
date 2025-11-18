//
//  WindowController.swift
//  ETerm
//
//  应用层 - 窗口控制器

import SwiftUI

/// 窗口控制器
///
/// 连接 Domain Layer 和 Presentation Layer 的桥梁
/// 负责：
/// - 管理窗口的布局状态
/// - 将领域模型转换为视图需要的数据
/// - 协调用户操作和领域逻辑
@Observable
final class WindowController {
    // MARK: - Dependencies

    private let window: TerminalWindow
    private let layoutCalculator: LayoutCalculator
    private var coordinateMapper: CoordinateMapper

    // MARK: - State

    private(set) var containerSize: CGSize
    private let cellWidth: CGFloat = 9.6   // 从 fontMetrics 获取
    private let cellHeight: CGFloat = 20.0

    // 🎯 Panel ID 映射（Swift UUID → Rust usize）
    private var panelIdMapping: [UUID: Int] = [:]
    private var nextRustPanelId: Int = 1

    // MARK: - Initialization

    init(containerSize: CGSize, scale: CGFloat) {
        // 创建初始 Tab 和 Panel
        let initialTab = TerminalTab(metadata: .defaultTerminal())
        let initialPanel = EditorPanel(initialTab: initialTab)

        // 创建窗口
        self.window = TerminalWindow(initialPanel: initialPanel)
        self.layoutCalculator = BinaryTreeLayoutCalculator()
        self.containerSize = containerSize
        self.coordinateMapper = CoordinateMapper(
            scale: scale,
            containerBounds: CGRect(origin: .zero, size: containerSize)
        )
    }

    // MARK: - Layout Query

    /// 获取所有 Panel 的边界
    var panelBounds: [UUID: PanelBounds] {
        layoutCalculator.calculatePanelBounds(
            layout: window.rootLayout,
            containerSize: containerSize
        )
    }

    /// 获取所有 Panel 的渲染配置
    var panelRenderConfigs: [UUID: TerminalRenderConfig] {
        panelBounds.mapValues { bounds in
            TerminalRenderConfig.from(
                bounds: bounds,
                mapper: coordinateMapper,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            )
        }
    }

    /// 获取所有 Panel ID
    var allPanelIds: [UUID] {
        window.allPanelIds
    }

    /// 获取 Panel 数量
    var panelCount: Int {
        window.panelCount
    }

    /// 获取所有分隔线
    var panelDividers: [PanelDivider] {
        calculateDividers(layout: window.rootLayout, containerSize: containerSize)
    }

    // MARK: - Panel Operations

    /// 分割 Panel
    ///
    /// - Parameters:
    ///   - panelId: 要分割的 Panel ID
    ///   - direction: 分割方向
    /// - Returns: 新创建的 Panel ID，如果失败返回 nil
    @discardableResult
    func splitPanel(panelId: UUID, direction: SplitDirection) -> UUID? {
        return window.splitPanel(
            panelId: panelId,
            direction: direction,
            layoutCalculator: layoutCalculator
        )
    }

    /// 获取指定 Panel
    func getPanel(_ panelId: UUID) -> EditorPanel? {
        return window.getPanel(panelId)
    }

    /// 更新分隔线比例
    ///
    /// - Parameters:
    ///   - divider: 分隔线
    ///   - newPosition: 新的位置 (逻辑坐标, Points)
    func updateDivider(_ divider: PanelDivider, newPosition: CGFloat) {
        // 计算新的比例
        let newRatio: CGFloat
        switch divider.direction {
        case .horizontal:
            newRatio = newPosition / containerSize.width
        case .vertical:
            newRatio = newPosition / containerSize.height
        }

        // 限制在合理范围 (10% ~ 90%)
        let clampedRatio = min(max(newRatio, 0.1), 0.9)

        print("[WindowController] 📏 Updating divider ratio: \(divider.direction) → \(clampedRatio)")

        // 更新布局树中的比例
        window.updateDividerRatio(path: divider.layoutPath, newRatio: clampedRatio)
    }

    // MARK: - Panel ID Mapping

    /// 注册 Panel，返回对应的 Rust Panel ID
    func registerPanel(_ panelId: UUID) -> Int {
        if let existingId = panelIdMapping[panelId] {
            return existingId
        }

        let rustId = nextRustPanelId
        panelIdMapping[panelId] = rustId
        nextRustPanelId += 1
        return rustId
    }

    /// 获取 Swift Panel ID 对应的 Rust Panel ID
    func getRustPanelId(_ swiftId: UUID) -> Int? {
        return panelIdMapping[swiftId]
    }

    /// 获取所有已注册的 Panel ID 映射（用于调试）
    func getAllPanelMappings() -> [UUID: Int] {
        return panelIdMapping
    }

    // MARK: - Container Management

    /// 调整容器尺寸
    ///
    /// 在窗口 resize 时调用
    func resizeContainer(newSize: CGSize, scale: CGFloat) {
        containerSize = newSize
        coordinateMapper = CoordinateMapper(
            scale: scale,
            containerBounds: CGRect(origin: .zero, size: newSize)
        )
    }

    // MARK: - Coordinate Mapping

    /// 将像素坐标转换为网格坐标
    ///
    /// - Parameters:
    ///   - point: 像素坐标
    ///   - panelId: Panel ID
    /// - Returns: 网格坐标 (col, row)，如果 Panel 不存在返回 nil
    func pixelToGrid(point: CGPoint, panelId: UUID) -> (col: UInt16, row: UInt16)? {
        guard let bounds = panelBounds[panelId] else {
            return nil
        }

        return coordinateMapper.pixelToGrid(
            point: point,
            paneOrigin: CGPoint(x: bounds.x, y: bounds.y),
            paneHeight: bounds.height,
            cellSize: CGSize(width: cellWidth, height: cellHeight)
        )
    }

    // MARK: - Private Helpers

    /// 递归计算布局树中的所有分隔线
    private func calculateDividers(
        layout: PanelLayout,
        containerSize: CGSize,
        path: [Int] = []
    ) -> [PanelDivider] {
        var dividers: [PanelDivider] = []

        switch layout {
        case .leaf:
            // 叶子节点没有分隔线
            return []

        case .split(let direction, let first, let second, let ratio):
            // 计算分割位置
            let position: CGFloat
            let firstPanelId: UUID
            let secondPanelId: UUID

            switch direction {
            case .horizontal:
                // 垂直分隔线 (左右分割)
                position = containerSize.width * ratio

            case .vertical:
                // 水平分隔线 (上下分割)
                position = containerSize.height * ratio
            }

            // 获取第一个和第二个 Panel ID
            if let firstId = first.allPanelIds().first,
               let secondId = second.allPanelIds().first {
                firstPanelId = firstId
                secondPanelId = secondId

                // 创建分隔线
                let divider = PanelDivider(
                    direction: direction,
                    firstPanelId: firstPanelId,
                    secondPanelId: secondPanelId,
                    position: position,
                    layoutPath: path
                )
                dividers.append(divider)
            }

            // 递归处理子节点
            // 根据分割方向计算子容器尺寸
            let firstSize: CGSize
            let secondSize: CGSize

            switch direction {
            case .horizontal:
                firstSize = CGSize(
                    width: containerSize.width * ratio,
                    height: containerSize.height
                )
                secondSize = CGSize(
                    width: containerSize.width * (1 - ratio),
                    height: containerSize.height
                )

            case .vertical:
                firstSize = CGSize(
                    width: containerSize.width,
                    height: containerSize.height * ratio
                )
                secondSize = CGSize(
                    width: containerSize.width,
                    height: containerSize.height * (1 - ratio)
                )
            }

            // 递归
            dividers += calculateDividers(layout: first, containerSize: firstSize, path: path + [0])
            dividers += calculateDividers(layout: second, containerSize: secondSize, path: path + [1])

            return dividers
        }
    }

    /// 将像素坐标转换为网格坐标（兼容旧代码）
    ///
    /// - Parameters:
    ///   - point: 像素坐标
    ///   - paneX: Pane X 坐标
    ///   - paneY: Pane Y 坐标
    ///   - paneHeight: Pane 高度
    /// - Returns: 网格坐标 (col, row)
    func pixelToGrid(
        point: CGPoint,
        paneX: CGFloat,
        paneY: CGFloat,
        paneHeight: CGFloat
    ) -> (col: UInt16, row: UInt16) {
        return coordinateMapper.pixelToGrid(
            point: point,
            paneOrigin: CGPoint(x: paneX, y: paneY),
            paneHeight: paneHeight,
            cellSize: CGSize(width: cellWidth, height: cellHeight)
        )
    }

    /// 查找指定坐标下的 Panel ID
    func findPanel(at point: CGPoint) -> UUID? {
        return panelBounds.first { (panelId, bounds) in
            bounds.contains(point)
        }?.key
    }
}
