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
