//
//  KeyboardEventPipeline.swift
//  ETerm
//
//  应用层 - 键盘事件管道

/// 管道处理结果
enum PipelineResult {
    case handled(by: String)
    case intercepted(InterceptAction)
    case unhandled
}

/// 键盘事件管道
///
/// 分层责任链，按阶段和优先级处理按键
final class KeyboardEventPipeline {
    private var handlers: [KeyboardEventHandler] = []

    /// 注册处理器
    func register(_ handler: KeyboardEventHandler) {
        handlers.append(handler)
        sortHandlers()
    }

    /// 移除处理器
    func unregister(_ identifier: String) {
        handlers.removeAll { $0.identifier == identifier }
    }

    /// 处理按键
    func process(_ keyStroke: KeyStroke, context: KeyboardContext) -> PipelineResult {
        for handler in handlers {
            let result = handler.handle(keyStroke, context: context)

            switch result {
            case .consumed:
                return .handled(by: handler.identifier)

            case .ignored:
                continue

            case .intercepted(let action):
                return .intercepted(action)
            }
        }

        return .unhandled
    }

    private func sortHandlers() {
        handlers.sort { a, b in
            if a.phase != b.phase {
                return a.phase < b.phase
            }
            return a.priority > b.priority
        }
    }
}
