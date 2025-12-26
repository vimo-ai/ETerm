//
//  BottomOverlayRegistry.swift
//  ETerm
//
//  窗口底部 Overlay 注册表 - 管理 Composer 等底部覆盖层
//

import SwiftUI
import Combine

/// 底部 Overlay 注册表 - 单例模式
///
/// 管理窗口底部 Overlay 的显示状态：
/// - 插件调用 show/hide 控制各自的 overlay
/// - 任意一个 overlay 显示时，区域可见
/// - 全部隐藏时，区域关闭
@MainActor
final class BottomOverlayRegistry: ObservableObject {

    // MARK: - Singleton

    static let shared = BottomOverlayRegistry()

    // MARK: - Properties

    /// 当前显示的 overlay id 列表（按显示顺序）
    @Published private(set) var visibleIds: [String] = []

    /// 是否有任何 overlay 显示
    var isVisible: Bool {
        !visibleIds.isEmpty
    }

    private init() {}

    // MARK: - Public API

    /// 显示 overlay
    func show(_ id: String) {
        guard !visibleIds.contains(id) else { return }
        visibleIds.append(id)
        print("[BottomOverlayRegistry] show: \(id), visible: \(visibleIds)")
    }

    /// 隐藏 overlay
    func hide(_ id: String) {
        guard let index = visibleIds.firstIndex(of: id) else { return }
        visibleIds.remove(at: index)
        print("[BottomOverlayRegistry] hide: \(id), visible: \(visibleIds)")
    }

    /// 切换 overlay 显示状态
    func toggle(_ id: String) {
        if visibleIds.contains(id) {
            hide(id)
        } else {
            show(id)
        }
    }

    /// 隐藏所有 overlay
    func hideAll() {
        visibleIds.removeAll()
        print("[BottomOverlayRegistry] hideAll")
    }
}
