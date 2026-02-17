//
//  SplitLayoutView.swift
//  PanelLayoutUI
//
//  递归渲染 LayoutTree 的 SwiftUI 视图
//

import SwiftUI
import PanelLayoutKit

/// 递归渲染 LayoutTree 的通用分栏视图
///
/// 使用方法：
/// ```swift
/// @State var layout: LayoutTree = .panel(PanelNode(tabs: [tab1]))
///
/// SplitLayoutView(layout: $layout) { panelId, panel in
///     MyCustomPanelView(panel: panel)
/// }
/// ```
///
/// - `.panel` 节点：调用 content 闭包渲染
/// - `.split` 节点：按 direction 和 ratio 递归分割，中间插入 RatioDivider
public struct SplitLayoutView<Content: View>: View {
    @Binding var layout: LayoutTree
    let content: (UUID, PanelNode) -> Content

    public init(
        layout: Binding<LayoutTree>,
        @ViewBuilder content: @escaping (UUID, PanelNode) -> Content
    ) {
        self._layout = layout
        self.content = content
    }

    public var body: some View {
        NodeView(node: $layout, content: content)
    }
}

/// 递归节点视图（内部使用）
private struct NodeView<Content: View>: View {
    @Binding var node: LayoutTree
    let content: (UUID, PanelNode) -> Content

    var body: some View {
        switch node {
        case .panel(let panel):
            content(panel.id, panel)

        case .split(let direction, _, _, _):
            SplitContainerView(
                node: $node,
                direction: direction,
                content: content
            )
        }
    }
}

/// 分割容器（内部使用）
///
/// 根据 direction 选择 HStack 或 VStack 布局。
/// 注意坐标系转换：PanelLayoutKit 使用 macOS 坐标系（Y 向上），
/// SwiftUI 使用 Y 向下。对于 vertical split：
/// - PanelLayoutKit: first 在下方，second 在上方
/// - SwiftUI: first 在上方，second 在下方（翻转）
private struct SplitContainerView<Content: View>: View {
    @Binding var node: LayoutTree
    let direction: SplitDirection
    let content: (UUID, PanelNode) -> Content

    var body: some View {
        GeometryReader { geo in
            let totalSize = direction == .horizontal ? geo.size.width : geo.size.height
            let ratio = $node.splitRatio.wrappedValue
            let dividerThickness: CGFloat = 1

            switch direction {
            case .horizontal:
                HStack(spacing: 0) {
                    NodeView(node: $node.splitFirst, content: content)
                        .frame(width: max(0, totalSize * ratio - dividerThickness / 2))

                    RatioDivider(
                        ratio: $node.splitRatio,
                        direction: direction,
                        totalSize: totalSize
                    )

                    NodeView(node: $node.splitSecond, content: content)
                        .frame(maxWidth: .infinity)
                }

            case .vertical:
                // SwiftUI Y 向下：first 显示在上方（对应 PanelLayoutKit 的下方）
                VStack(spacing: 0) {
                    NodeView(node: $node.splitSecond, content: content)
                        .frame(height: max(0, totalSize * (1 - ratio) - dividerThickness / 2))

                    RatioDivider(
                        ratio: $node.splitRatio,
                        direction: direction,
                        totalSize: totalSize
                    )

                    NodeView(node: $node.splitFirst, content: content)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }
}
