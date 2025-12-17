//
//  NavigationDirection.swift
//  ETerm
//
//  领域值对象 - 导航方向

import Foundation

/// 导航方向
///
/// 用于 Panel 焦点导航（Cmd+Option+方向键）
enum NavigationDirection {
    /// 向上导航
    case up

    /// 向下导航
    case down

    /// 向左导航
    case left

    /// 向右导航
    case right
}
