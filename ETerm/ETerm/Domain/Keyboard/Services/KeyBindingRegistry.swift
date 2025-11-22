//
//  KeyBindingRegistry.swift
//  ETerm
//
//  领域层 - 按键绑定注册表

/// 按键绑定
struct KeyBinding {
    let keyStroke: KeyStroke
    let event: KeyboardEvent
    let modes: Set<KeyboardMode>

    init(_ keyStroke: KeyStroke, event: KeyboardEvent, modes: Set<KeyboardMode> = [.normal]) {
        self.keyStroke = keyStroke
        self.event = event
        self.modes = modes
    }
}

/// 按键绑定注册表 - 领域服务
///
/// 管理所有按键到事件的映射
final class KeyBindingRegistry {
    private var bindings: [KeyBinding] = []

    init() {
        registerDefaultBindings()
    }

    // MARK: - 默认绑定

    private func registerDefaultBindings() {
        // ─────────────────────────────────────────
        // Window 级别 (Cmd+Shift)
        // ─────────────────────────────────────────
        register(.cmdShift("1"), event: .switchToPage(index: 0))
        register(.cmdShift("2"), event: .switchToPage(index: 1))
        register(.cmdShift("3"), event: .switchToPage(index: 2))
        register(.cmdShift("4"), event: .switchToPage(index: 3))
        register(.cmdShift("5"), event: .switchToPage(index: 4))
        register(.cmdShift("6"), event: .switchToPage(index: 5))
        register(.cmdShift("7"), event: .switchToPage(index: 6))
        register(.cmdShift("8"), event: .switchToPage(index: 7))
        register(.cmdShift("9"), event: .switchToPage(index: 8))
        register(.cmdShift("["), event: .previousPage)
        register(.cmdShift("]"), event: .nextPage)
        register(.cmdShift("t"), event: .createPage)
        register(.cmdShift("w"), event: .closePage)

        // ─────────────────────────────────────────
        // Panel 级别 (Cmd)
        // ─────────────────────────────────────────
        register(.cmd("1"), event: .switchToTab(index: 0))
        register(.cmd("2"), event: .switchToTab(index: 1))
        register(.cmd("3"), event: .switchToTab(index: 2))
        register(.cmd("4"), event: .switchToTab(index: 3))
        register(.cmd("5"), event: .switchToTab(index: 4))
        register(.cmd("6"), event: .switchToTab(index: 5))
        register(.cmd("7"), event: .switchToTab(index: 6))
        register(.cmd("8"), event: .switchToTab(index: 7))
        register(.cmd("9"), event: .switchToTab(index: 8))
        register(.cmd("["), event: .previousTab)
        register(.cmd("]"), event: .nextTab)
        register(.cmd("t"), event: .createTab)
        register(.cmd("w"), event: .closeTab)
        register(.cmd("d"), event: .splitHorizontal)
        register(.cmdShift("d"), event: .splitVertical)

        // ─────────────────────────────────────────
        // 编辑 (在 normal 和 selection 模式都生效)
        // ─────────────────────────────────────────
        register(.cmd("c"), event: .copy, modes: [.normal, .selection])
        register(.cmd("v"), event: .paste, modes: [.normal, .selection])
        register(.cmd("a"), event: .selectAll)

        // Escape 清除选中（仅在 selection 模式）
        register(.escape, event: .clearSelection, modes: [.selection])
    }

    // MARK: - 注册

    func register(_ keyStroke: KeyStroke, event: KeyboardEvent, modes: Set<KeyboardMode> = [.normal]) {
        bindings.append(KeyBinding(keyStroke, event: event, modes: modes))
    }

    // MARK: - 查找

    /// 查找匹配的绑定
    func find(keyStroke: KeyStroke, mode: KeyboardMode) -> KeyboardEvent? {
        for binding in bindings {
            if binding.keyStroke.matches(keyStroke) && binding.modes.contains(mode) {
                return binding.event
            }
        }
        return nil
    }
}
