//
//  WindowCommand.swift
//  ETerm
//
//  领域命令 - 窗口操作命令
//

import Foundation

// MARK: - 顶层命令

/// 窗口命令
///
/// 所有 UI 操作的统一入口，按操作对象分层组织
enum WindowCommand {
    /// Tab 操作
    case tab(TabCommand)

    /// Panel 操作
    case panel(PanelCommand)

    /// Page 操作
    case page(PageCommand)

    /// Window 级别操作
    case window(WindowOnlyCommand)
}

// MARK: - Tab 命令

/// Tab 操作命令
enum TabCommand {
    /// 切换到指定 Tab
    case `switch`(panelId: UUID, tabId: UUID)

    /// 添加新 Tab（CWD 由领域层自动继承）
    case add(panelId: UUID)

    /// 添加新 Tab（带配置）
    ///
    /// - Parameters:
    ///   - panelId: 目标 Panel ID
    ///   - config: 终端配置（CWD、命令、环境变量）
    case addWithConfig(panelId: UUID, config: TabConfig)

    /// 关闭 Tab
    case close(panelId: UUID, scope: CloseScope)

    /// 强制移除 Tab（用于跨窗口移动等场景）
    ///
    /// 与 `close` 不同：
    /// - 如果是最后一个 Tab，整个 Panel 会被移除
    /// - `closeTerminal` 决定是否返回 terminalsToClose
    ///
    /// - Parameters:
    ///   - tabId: 要移除的 Tab ID
    ///   - panelId: 所在的 Panel ID
    ///   - closeTerminal: 是否关闭终端（跨窗口移动时为 false）
    case remove(tabId: UUID, panelId: UUID, closeTerminal: Bool)

    /// 重排 Tab 顺序
    case reorder(panelId: UUID, order: [UUID])

    /// 移动 Tab
    case move(tabId: UUID, from: UUID, to: MoveTarget)
}

/// Tab 创建配置
struct TabConfig {
    /// 工作目录
    let cwd: String?

    /// 启动命令
    let command: String?

    /// 命令执行延迟（秒）
    let commandDelay: TimeInterval

    /// 环境变量
    let env: [String: String]?

    /// 跳过终端创建（用于外部 fd 注入场景，调用方自行创建终端）
    let skipTerminalCreation: Bool

    init(cwd: String? = nil, command: String? = nil, commandDelay: TimeInterval = 0.3, env: [String: String]? = nil, skipTerminalCreation: Bool = false) {
        self.cwd = cwd
        self.command = command
        self.commandDelay = commandDelay
        self.env = env
        self.skipTerminalCreation = skipTerminalCreation
    }
}

// MARK: - Panel 命令

/// Panel 操作命令
///
/// 注意：navigate 不在此处，因为它需要 containerBounds（UI 层坐标计算）
/// 使用 TerminalWindow.navigatePanel(direction:containerBounds:) 代替
enum PanelCommand {
    /// 分割 Panel
    ///
    /// - Parameters:
    ///   - panelId: 要分割的 Panel ID
    ///   - direction: 分割方向
    ///   - cwd: 新终端的工作目录（nil 表示继承当前目录）
    case split(panelId: UUID, direction: SplitDirection, cwd: String?)

    /// 关闭 Panel
    case close(panelId: UUID)

    /// 设置活动 Panel
    case setActive(panelId: UUID)
}

// MARK: - Page 命令

/// Page 操作命令
enum PageCommand {
    /// 切换 Page
    case `switch`(to: PageTarget)

    /// 创建新 Page
    ///
    /// - Parameters:
    ///   - title: 页面标题（nil 表示使用默认标题）
    ///   - cwd: 新终端的工作目录（nil 表示继承当前目录）
    case create(title: String?, cwd: String?)

    /// 关闭 Page
    case close(scope: CloseScope)

    /// 重排 Page 顺序（给定完整顺序）
    case reorder(order: [UUID])

    /// 移动 Page 到指定位置之前
    case move(pageId: UUID, before: UUID)

    /// 移动 Page 到末尾
    case moveToEnd(pageId: UUID)
}

// MARK: - Window 命令

/// Window 级别操作命令
enum WindowOnlyCommand {
    /// 智能关闭（Tab → Panel → Page → Window 层层递进）
    case smartClose
}

// MARK: - 值对象

/// 关闭范围
///
/// Tab 和 Page 共用，指定关闭哪些项目
enum CloseScope {
    /// 关闭单个
    case single(UUID)

    /// 关闭其他，保留指定的
    case others(keep: UUID)

    /// 关闭左侧所有
    case left(of: UUID)

    /// 关闭右侧所有
    case right(of: UUID)
}

/// Page 切换目标
enum PageTarget {
    /// 切换到指定 Page
    case specific(UUID)

    /// 切换到下一个 Page
    case next

    /// 切换到上一个 Page
    case previous
}

/// Tab 移动目标
enum MoveTarget {
    /// 移动到已有 Panel
    case existingPanel(UUID)

    /// 拖拽分割创建新 Panel
    case splitNew(targetPanelId: UUID, edge: EdgeDirection)
}
