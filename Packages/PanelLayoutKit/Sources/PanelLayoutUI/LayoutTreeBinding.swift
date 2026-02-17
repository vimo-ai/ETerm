//
//  LayoutTreeBinding.swift
//  PanelLayoutUI
//
//  LayoutTree 的 Binding 辅助扩展
//

import SwiftUI
import PanelLayoutKit

/// Binding<LayoutTree> 的子节点访问扩展
///
/// 用于在 SwiftUI 递归渲染时，从 split 节点提取子 binding。
extension Binding where Value == LayoutTree {

    /// 获取 split 节点的 ratio binding
    var splitRatio: Binding<CGFloat> {
        Binding<CGFloat>(
            get: {
                if case .split(_, _, _, let ratio) = wrappedValue {
                    return ratio
                }
                return 0.5
            },
            set: { newRatio in
                if case .split(let direction, let first, let second, _) = wrappedValue {
                    wrappedValue = .split(
                        direction: direction,
                        first: first,
                        second: second,
                        ratio: newRatio
                    )
                }
            }
        )
    }

    /// 获取 split 节点的 first 子树 binding
    var splitFirst: Binding<LayoutTree> {
        Binding<LayoutTree>(
            get: {
                if case .split(_, let first, _, _) = wrappedValue {
                    return first
                }
                return wrappedValue
            },
            set: { newFirst in
                if case .split(let direction, _, let second, let ratio) = wrappedValue {
                    wrappedValue = .split(
                        direction: direction,
                        first: newFirst,
                        second: second,
                        ratio: ratio
                    )
                }
            }
        )
    }

    /// 获取 split 节点的 second 子树 binding
    var splitSecond: Binding<LayoutTree> {
        Binding<LayoutTree>(
            get: {
                if case .split(_, _, let second, _) = wrappedValue {
                    return second
                }
                return wrappedValue
            },
            set: { newSecond in
                if case .split(let direction, let first, _, let ratio) = wrappedValue {
                    wrappedValue = .split(
                        direction: direction,
                        first: first,
                        second: newSecond,
                        ratio: ratio
                    )
                }
            }
        )
    }
}
