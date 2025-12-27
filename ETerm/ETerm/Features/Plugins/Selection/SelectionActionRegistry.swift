//
//  SelectionActionRegistry.swift
//  ETerm
//
//  选中操作注册表

import Foundation
import ETermKit

/// 选中操作注册表
///
/// 管理插件注册的选中文本操作。
/// 当用户在终端选中文本时，显示 Popover 菜单，包含所有注册的 Action。
@MainActor
final class SelectionActionRegistry {

    static let shared = SelectionActionRegistry()

    // MARK: - Storage

    /// 已注册的 Action（按优先级排序）
    private var actions: [SelectionAction] = []

    /// 模式 -> Action 映射（用于快速查找自动触发）
    private var modeMap: [String: SelectionAction] = [:]

    private init() {}

    // MARK: - Registration

    /// 注册 Action
    ///
    /// - Parameter action: Action 配置
    func register(_ action: SelectionAction) {
        // 检查是否已存在
        guard !actions.contains(where: { $0.id == action.id }) else { return }

        // 添加并按优先级排序（高优先级在前）
        actions.append(action)
        actions.sort { $0.priority > $1.priority }

        // 构建模式映射
        if let mode = action.autoTriggerOnMode {
            modeMap[mode] = action
        }
    }

    /// 取消注册
    ///
    /// - Parameter actionId: Action ID
    func unregister(actionId: String) {
        if let index = actions.firstIndex(where: { $0.id == actionId }) {
            let action = actions.remove(at: index)
            if let mode = action.autoTriggerOnMode {
                modeMap.removeValue(forKey: mode)
            }
        }
    }

    // MARK: - Query

    /// 获取所有可用 Action（按优先级排序）
    func getAllActions() -> [SelectionAction] {
        return actions
    }

    /// 获取排除指定 Action 后的列表
    ///
    /// 用于自动触发后，显示剩余的 Actions。
    ///
    /// - Parameter excludeIds: 要排除的 Action ID 列表
    /// - Returns: 过滤后的 Actions
    func getActions(excluding excludeIds: Set<String>) -> [SelectionAction] {
        return actions.filter { !excludeIds.contains($0.id) }
    }

    /// 根据模式获取自动触发的 Action
    ///
    /// - Parameter mode: 模式名称（如 "translation"）
    /// - Returns: 需要自动触发的 Action（如果存在）
    func getActionForMode(_ mode: String) -> SelectionAction? {
        return modeMap[mode]
    }

    /// 根据 ID 查找 Action
    func getAction(id: String) -> SelectionAction? {
        return actions.first { $0.id == id }
    }

    /// 是否有注册的 Action
    var hasActions: Bool {
        return !actions.isEmpty
    }
}
