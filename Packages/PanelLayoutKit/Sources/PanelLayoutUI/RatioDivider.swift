//
//  RatioDivider.swift
//  PanelLayoutUI
//
//  Ratio 驱动的可拖拽分割线
//

import SwiftUI
import PanelLayoutKit

/// Ratio 驱动的可拖拽分割线
///
/// 用于分割两个视图区域，支持水平（左右）和垂直（上下）方向。
/// 通过拖拽改变 ratio 值（0.1 ~ 0.9），由 GeometryReader 提供的 totalSize 换算像素偏移。
public struct RatioDivider: View {
    @Binding var ratio: CGFloat
    let direction: SplitDirection
    let totalSize: CGFloat

    /// 分割线视觉宽度
    private let lineThickness: CGFloat = 1

    /// 拖拽热区宽度（两侧各扩展）
    private let hitAreaPadding: CGFloat = 3

    /// ratio 限制范围
    private let minRatio: CGFloat = 0.1
    private let maxRatio: CGFloat = 0.9

    /// 拖拽起始时的 ratio 快照
    @GestureState private var dragStartRatio: CGFloat?

    public init(ratio: Binding<CGFloat>, direction: SplitDirection, totalSize: CGFloat) {
        self._ratio = ratio
        self.direction = direction
        self.totalSize = totalSize
    }

    public var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: direction == .horizontal ? lineThickness : nil,
                height: direction == .vertical ? lineThickness : nil
            )
            .contentShape(
                Rectangle().inset(by: -hitAreaPadding)
            )
            .onHover { hovering in
                if hovering {
                    let cursor: NSCursor = direction == .horizontal
                        ? .resizeLeftRight
                        : .resizeUpDown
                    cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($dragStartRatio) { _, state, _ in
                        if state == nil {
                            state = ratio
                        }
                    }
                    .onChanged { value in
                        guard let startRatio = dragStartRatio, totalSize > 0 else { return }

                        let delta: CGFloat
                        switch direction {
                        case .horizontal:
                            delta = value.translation.width
                        case .vertical:
                            delta = value.translation.height
                        }

                        let deltaRatio = delta / totalSize
                        let newRatio = startRatio + deltaRatio
                        ratio = max(minRatio, min(maxRatio, newRatio))
                    }
            )
    }
}
