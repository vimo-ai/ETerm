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
    let category: String      // 分类（如 "系统"、"AI翻译"）
    let description: String   // 描述（如 "复制"、"打开对话"）

    init(
        _ keyStroke: KeyStroke,
        event: KeyboardEvent,
        modes: Set<KeyboardMode> = [.normal],
        category: String,
        description: String
    ) {
        self.keyStroke = keyStroke
        self.event = event
        self.modes = modes
        self.category = category
        self.description = description
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
        register(.cmdShift("1"), event: .switchToPage(index: 0), category: "窗口管理", description: "切换到 Page 1")
        register(.cmdShift("2"), event: .switchToPage(index: 1), category: "窗口管理", description: "切换到 Page 2")
        register(.cmdShift("3"), event: .switchToPage(index: 2), category: "窗口管理", description: "切换到 Page 3")
        register(.cmdShift("4"), event: .switchToPage(index: 3), category: "窗口管理", description: "切换到 Page 4")
        register(.cmdShift("5"), event: .switchToPage(index: 4), category: "窗口管理", description: "切换到 Page 5")
        register(.cmdShift("6"), event: .switchToPage(index: 5), category: "窗口管理", description: "切换到 Page 6")
        register(.cmdShift("7"), event: .switchToPage(index: 6), category: "窗口管理", description: "切换到 Page 7")
        register(.cmdShift("8"), event: .switchToPage(index: 7), category: "窗口管理", description: "切换到 Page 8")
        register(.cmdShift("9"), event: .switchToPage(index: 8), category: "窗口管理", description: "切换到 Page 9")
        register(.cmdShift("["), event: .previousPage, category: "窗口管理", description: "上一个 Page")
        register(.cmdShift("]"), event: .nextPage, category: "窗口管理", description: "下一个 Page")
        register(.cmdShift("t"), event: .createPage, category: "窗口管理", description: "新建 Page")
        register(.cmdShift("w"), event: .closePage, category: "窗口管理", description: "关闭当前 Page")

        // ─────────────────────────────────────────
        // Panel 级别 (Cmd)
        // ─────────────────────────────────────────
        register(.cmd("1"), event: .switchToTab(index: 0), category: "面板管理", description: "切换到 Tab 1")
        register(.cmd("2"), event: .switchToTab(index: 1), category: "面板管理", description: "切换到 Tab 2")
        register(.cmd("3"), event: .switchToTab(index: 2), category: "面板管理", description: "切换到 Tab 3")
        register(.cmd("4"), event: .switchToTab(index: 3), category: "面板管理", description: "切换到 Tab 4")
        register(.cmd("5"), event: .switchToTab(index: 4), category: "面板管理", description: "切换到 Tab 5")
        register(.cmd("6"), event: .switchToTab(index: 5), category: "面板管理", description: "切换到 Tab 6")
        register(.cmd("7"), event: .switchToTab(index: 6), category: "面板管理", description: "切换到 Tab 7")
        register(.cmd("8"), event: .switchToTab(index: 7), category: "面板管理", description: "切换到 Tab 8")
        register(.cmd("9"), event: .switchToTab(index: 8), category: "面板管理", description: "切换到 Tab 9")
        register(.cmd("["), event: .previousTab, category: "面板管理", description: "上一个 Tab")
        register(.cmd("]"), event: .nextTab, category: "面板管理", description: "下一个 Tab")
        register(.cmd("t"), event: .createTab, category: "面板管理", description: "新建 Tab")
        register(.cmd("w"), event: .closeTab, category: "面板管理", description: "关闭当前 Tab")
        register(.cmd("d"), event: .splitHorizontal, category: "面板管理", description: "水平分屏")
        register(.cmdShift("d"), event: .splitVertical, category: "面板管理", description: "垂直分屏")

        // ─────────────────────────────────────────
        // 编辑 (在 normal 和 selection 模式都生效)
        // ─────────────────────────────────────────
        register(.cmd("c"), event: .copy, modes: [.normal, .selection], category: "编辑", description: "复制")
        register(.cmd("v"), event: .paste, modes: [.normal, .selection], category: "编辑", description: "粘贴")
        register(.cmd("a"), event: .selectAll, category: "编辑", description: "全选")

        // Escape 清除选中（仅在 selection 模式）
        register(.escape, event: .clearSelection, modes: [.selection], category: "编辑", description: "清除选中")

        // ─────────────────────────────────────────
        // 字体大小 (Cmd+= 放大, Cmd+- 缩小, Cmd+0 重置)
        // 在所有模式下都生效
        // ─────────────────────────────────────────
        register(.cmd("="), event: .increaseFontSize, modes: [.normal, .selection], category: "字体", description: "放大字体")
        register(.cmd("+"), event: .increaseFontSize, modes: [.normal, .selection], category: "字体", description: "放大字体")  // Shift+= 产生 +
        register(.cmd("-"), event: .decreaseFontSize, modes: [.normal, .selection], category: "字体", description: "缩小字体")
        register(.cmd("0"), event: .resetFontSize, modes: [.normal, .selection], category: "字体", description: "重置字体大小")

        // ─────────────────────────────────────────
        // 辅助功能
        // ─────────────────────────────────────────
        register(.cmdShift("y"), event: .toggleTranslationMode, category: "AI翻译", description: "切换翻译模式")
        register(.cmd(","), event: .toggleSidebar, modes: [.normal, .selection], category: "系统", description: "打开侧边栏")
    }

    // MARK: - 注册

    func register(_ keyStroke: KeyStroke, event: KeyboardEvent, modes: Set<KeyboardMode> = [.normal], category: String, description: String) {
        bindings.append(KeyBinding(keyStroke, event: event, modes: modes, category: category, description: description))
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

    /// 获取所有绑定（用于 UI 显示）
    func allBindings() -> [KeyBinding] {
        return bindings
    }
}
