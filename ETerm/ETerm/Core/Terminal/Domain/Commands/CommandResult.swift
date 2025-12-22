//
//  CommandResult.swift
//  ETerm
//
//  领域命令 - 命令执行结果
//

import Foundation

// MARK: - 命令结果

/// 命令执行结果
///
/// 领域层执行命令后返回此结构，Coordinator 负责：
/// 1. 根据 terminalsToActivate/terminalsToDeactivate 调用 ActivationService
/// 2. 根据 terminalsToCreate/terminalsToClose 管理终端生命周期
/// 3. 根据 effects 执行副作用（渲染、保存等）
struct CommandResult {
    /// 是否成功
    var success: Bool = true

    /// 失败原因
    var error: CommandError?

    // MARK: - 终端激活

    /// 需要激活的终端 ID 列表（设为 .active 模式，触发渲染）
    var terminalsToActivate: [Int] = []

    /// 需要停用的终端 ID 列表
    var terminalsToDeactivate: [Int] = []

    /// 用户实际 focus 的终端 ID（用于通知插件清除装饰）
    /// 区别于 terminalsToActivate：Page 切换时所有 Panel 的 activeTab 都需要激活渲染，
    /// 但只有当前激活 Panel 的 Tab 才是用户真正 focus 的
    var focusedTerminalId: Int?

    // MARK: - 终端生命周期

    /// 需要创建的终端
    var terminalsToCreate: [TerminalSpec] = []

    /// 需要关闭的终端 ID 列表
    var terminalsToClose: [Int] = []

    // MARK: - 结构变更（冒泡清理）

    /// 被移除的 Panel ID（用于清理 Coordinator 级别的状态，如搜索绑定）
    var removedPanelId: UUID?

    /// 被移除的 Page ID（冒泡：Panel 移除后 Page 变空）
    /// Coordinator 需要执行 removePage，并检查 Window 是否变空
    var removedPageId: UUID?

    /// 新创建的 Tab ID（用于 addWithConfig 场景，Coordinator 需要返回给调用方）
    var createdTabId: UUID?

    // MARK: - 副作用

    /// 副作用声明
    var effects: CommandEffects = CommandEffects()

    // MARK: - 便捷构造

    /// 创建失败结果
    static func failure(_ error: CommandError) -> CommandResult {
        CommandResult(success: false, error: error)
    }

    /// 创建成功结果（视图切换）
    static func viewChanged() -> CommandResult {
        var result = CommandResult()
        result.effects = .viewChange
        return result
    }

    /// 创建成功结果（状态变更）
    static func stateChanged() -> CommandResult {
        var result = CommandResult()
        result.effects = .stateChange
        return result
    }

    /// 创建成功结果（布局变更）
    static func layoutChanged() -> CommandResult {
        var result = CommandResult()
        result.effects = .layoutChange
        return result
    }
}

// MARK: - 终端创建规格

/// 终端创建规格
///
/// 描述需要创建的终端参数
struct TerminalSpec {
    /// 关联的 Tab ID
    let tabId: UUID

    /// 工作目录（nil 表示使用默认）
    let cwd: String?

    /// 启动命令（nil 表示使用默认 shell）
    let command: String?

    /// 环境变量
    let env: [String: String]?

    init(tabId: UUID, cwd: String? = nil, command: String? = nil, env: [String: String]? = nil) {
        self.tabId = tabId
        self.cwd = cwd
        self.command = command
        self.env = env
    }
}

// MARK: - 命令错误

/// 命令错误
enum CommandError {
    /// 不能关闭最后一个 Tab
    case cannotCloseLastTab

    /// 不能关闭最后一个 Panel
    case cannotCloseLastPanel

    /// 不能关闭最后一个 Page
    case cannotCloseLastPage

    /// Tab 未找到
    case tabNotFound(UUID)

    /// Panel 未找到
    case panelNotFound(UUID)

    /// Page 未找到
    case pageNotFound(UUID)

    /// 无激活的 Page
    case noActivePage

    /// 无激活的 Panel
    case noActivePanel
}

// MARK: - 副作用声明

/// 副作用声明
///
/// 声明命令执行后需要触发的副作用，由 Coordinator 统一执行
///
/// 使用语义化工厂方法，而非手动设置布尔值：
/// - `.viewChange` - 视图切换（Tab/Panel 激活切换）
/// - `.stateChange` - 状态变更（添加/删除/重排 Tab/Panel/Page）
/// - `.layoutChange` - 布局变更（Panel 分割等需要同步到 Rust 的操作）
struct CommandEffects {
    /// 同步布局到 Rust
    var syncLayout: Bool = false

    /// 触发渲染
    var render: Bool = false

    /// 保存 Session
    var saveSession: Bool = false

    /// 触发 UI 更新
    var updateTrigger: Bool = false

    // MARK: - 语义化工厂方法

    /// 视图切换（Tab/Panel 激活切换，渲染并更新 UI，不保存）
    static var viewChange: CommandEffects {
        CommandEffects(render: true, updateTrigger: true)
    }

    /// 状态变更（添加/删除/重排 Tab/Panel/Page）
    static var stateChange: CommandEffects {
        CommandEffects(render: true, saveSession: true, updateTrigger: true)
    }

    /// 布局变更（Panel 分割等需要同步到 Rust 的操作）
    static var layoutChange: CommandEffects {
        CommandEffects(syncLayout: true, render: true, saveSession: true, updateTrigger: true)
    }

    /// 无副作用
    static var none: CommandEffects {
        CommandEffects()
    }
}

