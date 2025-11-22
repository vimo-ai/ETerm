//
//  KeyboardEventHandler.swift
//  ETerm
//
//  应用层 - 键盘事件处理器协议

/// 事件处理结果
enum EventHandleResult {
    /// 已处理，停止传播
    case consumed

    /// 未处理，继续传播
    case ignored

    /// 劫持：完全接管（用于 IME）
    case intercepted(InterceptAction)
}

/// 劫持动作
enum InterceptAction {
    case passToIME
}

/// 事件处理阶段
enum EventPhase: Int, Comparable {
    case intercept = 0       // 劫持层（IME）
    case globalShortcut = 1  // 全局快捷键（Page）
    case panelShortcut = 2   // Panel 快捷键（Tab）
    case edit = 3            // 编辑（复制粘贴）
    case terminalInput = 4   // 终端输入（兜底）

    static func < (lhs: EventPhase, rhs: EventPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 键盘事件处理器协议
protocol KeyboardEventHandler: AnyObject {
    /// 处理器标识
    var identifier: String { get }

    /// 所属阶段
    var phase: EventPhase { get }

    /// 优先级（同阶段内，数字越大越先）
    var priority: Int { get }

    /// 处理按键
    func handle(_ keyStroke: KeyStroke, context: KeyboardContext) -> EventHandleResult
}
