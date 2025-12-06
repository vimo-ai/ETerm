//
//  IMEInterceptHandler.swift
//  ETerm
//
//  应用层 - IME 劫持处理器

/// IME 劫持处理器
///
/// 在 IME 预编辑状态下劫持大部分按键
final class IMEInterceptHandler {
    private let imeCoordinator: IMECoordinator

    init(imeCoordinator: IMECoordinator) {
        self.imeCoordinator = imeCoordinator
    }

    func handle(_ keyStroke: KeyStroke, context: KeyboardContext) -> EventHandleResult {
        guard imeCoordinator.isComposing else {
            return .unhandled
        }

        // 允许穿透的全局快捷键
        let allowedGlobalShortcuts: [KeyStroke] = [
            .cmdShift("w"),  // 关闭
            .cmd("q"),       // 退出
        ]

        if allowedGlobalShortcuts.contains(where: { $0.matches(keyStroke) }) {
            imeCoordinator.cancelComposition()
            return .unhandled
        }

        // 其他按键交给 IME
        return .intercepted(.passToIME)
    }
}
