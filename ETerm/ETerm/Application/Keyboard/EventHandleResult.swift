//
//  EventHandleResult.swift
//  ETerm
//
//  应用层 - 事件处理结果

/// 事件处理结果
enum EventHandleResult {
    /// 已处理，停止传播
    case handled

    /// 未处理，继续传播
    case unhandled

    /// 劫持：完全接管（用于 IME）
    case intercepted(InterceptAction)
}

/// 劫持动作
enum InterceptAction {
    case passToIME
}
