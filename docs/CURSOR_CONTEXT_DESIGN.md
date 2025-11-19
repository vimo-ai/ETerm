# 光标上下文设计文档

> ETerm 终端模拟器 - 光标、选中、IME 输入的完整业务逻辑设计

## 📋 目录

- [1. 业务背景](#1-业务背景)
- [2. 核心问题](#2-核心问题)
- [3. 业务规则](#3-业务规则)
- [4. 领域模型设计](#4-领域模型设计)
- [5. 技术方案](#5-技术方案)
- [6. 实现路径](#6-实现路径)
- [7. 关键决策记录](#7-关键决策记录)

---

## 1. 业务背景

### 1.1 为什么需要光标上下文？

光标上下文是终端模拟器的核心功能，也是 **IME 中文输入的前置依赖**：

```
IME 功能依赖光标上下文：
┌─────────────────────────────────────┐
│ 1. 候选框位置                        │
│    需要：光标的屏幕坐标 (NSRect)      │
│    ↓                                │
│ 2. Preedit 文本显示                  │
│    需要：光标的网格坐标 (col, row)    │
│    ↓                                │
│ 3. 输入焦点判断                      │
│    需要：哪个 Tab 的光标是激活的      │
│    ↓                                │
│ 4. 输入替换逻辑                      │
│    需要：选中状态（是否替换选中文本）  │
└─────────────────────────────────────┘
```

### 1.2 光标上下文的完整范围

光标上下文不仅仅是"光标位置"，还包括：

```
光标上下文（CursorContext）包含：
┌──────────────────────────────────────────┐
│ 1️⃣ 光标管理                              │
│    - 光标位置（col, row）                 │
│    - 光标样式（block/underline/beam）     │
│    - 光标可见性、闪烁状态                 │
│    - 光标移动（上下左右、Home/End）        │
│                                          │
│ 2️⃣ 文本选中 ⭐                            │
│    - 鼠标拖拽选中                         │
│    - Shift + 方向键选中                   │
│    - 选中范围（支持历史缓冲区）            │
│    - 获取选中的文本内容                    │
│                                          │
│ 3️⃣ 选中与输入的交互 ⭐                     │
│    - 判断选中是否在当前输入行              │
│    - 在输入行 → 输入时替换选中             │
│    - 在历史区 → 输入不影响选中             │
│                                          │
│ 4️⃣ IME 输入支持                          │
│    - Preedit 文本状态                     │
│    - 候选框位置（基于光标）                │
│    - 与选中的协同                         │
│                                          │
│ 5️⃣ 焦点状态                              │
│    - Tab 激活/失焦                        │
│    - 失焦时选中变灰、光标隐藏              │
└──────────────────────────────────────────┘
```

---

## 2. 核心问题

### 2.1 问题：文本选中的两种语义

**易混淆的概念**：

1. **文本选中（Text Selection）** - 终端核心功能
   - 用途：选中终端中**已有的文本**，用于复制
   - 特点：与光标位置独立，只读，纯视觉高亮

2. **输入选中（Input Selection）** - 编辑器概念
   - 用途：选中**当前输入行的文字**，用于替换/删除
   - 特点：与光标位置相关，可编辑

**关键理解**：两者是**同一个选中对象**，但根据**选中位置**行为不同。

### 2.2 问题：选中与输入的交互逻辑

```
场景A：选中在历史输出
┌────────────────────────────────────┐
│ $ git status                       │
│ On [branch main] ← 选中（历史）     │
│ $ hello|         ← 光标（输入行）   │
└────────────────────────────────────┘

用户输入 "你好"：
→ 选中不清除（选中在历史，不在输入行）
→ 在光标位置插入 "你好"
→ 结果：$ hello你好|

场景B：选中在当前输入行
┌────────────────────────────────────┐
│ $ git status                       │
│ On branch main                     │
│ $ [hello]| ← 选中+光标在输入行      │
└────────────────────────────────────┘

用户输入 "你好"：
→ 删除选中的 "hello"（因为在输入行）✅
→ 插入 "你好"
→ 清除选中
→ 结果：$ 你好|
```

---

## 3. 业务规则

### 3.1 选中的创建和清除

#### 创建选中
```
方式 1：鼠标拖拽选中（必做）
  mouseDown → mouseDragged → mouseUp

方式 2：Shift + 方向键选中（必做）
  用户操作：Shift + ←←←← → 向左扩展选中

方式 3：双击/三击选中（下个阶段）
  双击选中单词
  三击选中行
```

#### 清除选中
```
触发条件：
A. 鼠标单击（点击任意位置）
B. 纯方向键（不按 Shift）✅
C. 输入文字（如果选中在输入行，替换后清除）
D. Esc 键（可选）

不清除的情况：
- Tab 切换（选中保留，可能变灰）
- 窗口失焦（选中保留）
- 输入文字（如果选中在历史区，不清除）
```

### 3.2 输入与选中的交互规则

**核心业务逻辑**：

```swift
// 伪代码
func insertText(_ text: String) {
    if hasSelection() {
        if isSelectionInInputLine() {
            // 规则1：选中在输入行 → 替换（编辑器行为）✅
            deleteSelection()      // 直接删除选中的文字
            insert(text)           // 插入新文字
            clearSelection()       // 清除选中
        } else {
            // 规则2：选中在历史区 → 不影响（终端行为）✅
            insert(text)           // 在光标位置插入
            // 选中保留
        }
    } else {
        insert(text)  // 正常插入
    }
}
```

### 3.3 选中范围的边界

```
历史缓冲区大小：10000 行（可扩展为无限）

边界规则：
✅ 可以选中任意历史输出（包括滚动区域）
✅ 可以跨行选中（支持换行符）
✅ 支持 UTF-8、emoji、中文

限制（可选，性能优化）：
⭕ 单次选中最大行数：1000 行（防止 Cmd+C 卡顿）
```

### 3.4 复制功能的职责划分

```
光标上下文（CursorContext）负责：
✅ 判断是否有选中：hasSelection() -> Bool
✅ 获取选中文本：getSelectedText() -> String?
✅ 获取选中范围：getSelectionRange() -> Range

应用层协调器负责：
✅ 监听 Cmd+C 快捷键
✅ 调用 tab.getSelectedText()
✅ 写入系统剪贴板（NSPasteboard）

基础设施层负责：
✅ Rust FFI：terminal_get_text_range()
```

---

## 4. 领域模型设计

### 4.1 值对象（Value Objects）

#### CursorPosition
```swift
/// 光标位置（终端网格坐标）
struct CursorPosition: Equatable {
    let col: UInt16
    let row: UInt16
}
```

#### CursorState
```swift
/// 光标状态（不可变）
struct CursorState: Equatable {
    let position: CursorPosition
    let style: CursorStyle        // block/underline/beam
    let isVisible: Bool
    let isBlinking: Bool

    // 工厂方法
    static func initial() -> CursorState

    // 转换方法（不可变）
    func moveTo(col: UInt16, row: UInt16) -> CursorState
    func hide() -> CursorState
    func show() -> CursorState
}

enum CursorStyle: Equatable {
    case block      // 方块（默认）
    case underline  // 下划线（IME 时常用）
    case beam       // 竖线（类似 VSCode）
}
```

#### TextSelection
```swift
/// 文本选中（不可变）
struct TextSelection: Equatable {
    let anchor: CursorPosition    // 起点（固定，mouseDown 位置）
    let active: CursorPosition    // 终点（移动，当前光标/鼠标位置）
    let isActive: Bool            // 是否高亮显示（Tab 切换时变灰）

    // 计算属性
    var isEmpty: Bool {
        anchor == active
    }

    // 业务方法
    func normalized() -> (start: CursorPosition, end: CursorPosition) {
        // 确保 start <= end（处理反向选中）
    }

    func isInCurrentInputLine(inputRow: UInt16) -> Bool {
        // 判断选中是否在当前输入行
        let (start, end) = normalized()
        return start.row == inputRow && end.row == inputRow
    }
}
```

#### InputState
```swift
/// IME 输入状态（不可变）
struct InputState: Equatable {
    let preeditText: String        // 预编辑文本（拼音）
    let preeditCursor: Int         // preedit 内光标位置
    let isComposing: Bool          // 是否在输入法组合中

    static func empty() -> InputState

    func withPreedit(text: String, cursor: Int) -> InputState
    func clearPreedit() -> InputState
}
```

### 4.2 聚合根（Aggregate Root）

#### TerminalTab AR

```swift
/// 终端 Tab（聚合根）
///
/// 职责：
/// - 封装光标/选中/输入的所有业务规则
/// - 保证状态一致性
/// - 发布领域事件
final class TerminalTab {
    let tabId: UUID
    private(set) var metadata: TabMetadata
    private(set) var state: TabState  // active/inactive

    // === 光标上下文的状态 ===
    private(set) var cursorState: CursorState
    private(set) var textSelection: TextSelection?
    private(set) var inputState: InputState
    private var currentInputRow: UInt16?  // 🎯 当前输入行号（从 Rust 同步）

    // MARK: - 光标管理

    /// 移动光标（方向键）
    func moveCursor(direction: Direction)

    /// 移动光标到指定位置
    func moveCursorTo(col: UInt16, row: UInt16)

    /// 更新光标位置（从 Rust 同步）
    func updateCursorPosition(col: UInt16, row: UInt16)

    /// 隐藏/显示光标
    func hideCursor()
    func showCursor()

    // MARK: - 文本选中管理

    /// 开始选中（鼠标按下 或 Shift + 方向键第一次）
    func startSelection(at: CursorPosition)

    /// 更新选中（鼠标拖拽 或 Shift + 方向键继续）
    func updateSelection(to: CursorPosition)

    /// 清除选中
    func clearSelection()

    /// 是否有选中
    func hasSelection() -> Bool

    /// 获取选中的文本（调用 Rust FFI）
    func getSelectedText() -> String?

    /// 判断选中是否在当前输入行
    func isSelectionInInputLine() -> Bool {
        guard let selection = textSelection,
              let inputRow = currentInputRow else {
            return false
        }
        return selection.isInCurrentInputLine(inputRow: inputRow)
    }

    // MARK: - 输入管理

    /// 插入文本（核心业务逻辑）
    func insertText(_ text: String) {
        // 🎯 业务规则：检查选中
        if hasSelection() && isSelectionInInputLine() {
            deleteSelection()  // 删除选中（如果在输入行）
        }
        // 插入文本（调用 Infrastructure 层）
    }

    /// 删除选中的文本（直接删除，调用 Rust FFI）
    func deleteSelection()

    // MARK: - IME 管理

    /// 更新预编辑文本（Preedit）
    func updatePreedit(text: String, cursor: Int)

    /// 确认输入（Commit）
    func commitInput(text: String) {
        // 🎯 内部调用 insertText（会处理选中替换）
        insertText(text)
        clearPreedit()
    }

    /// 取消预编辑
    func cancelPreedit()

    // MARK: - 状态同步（从 Rust）

    /// 从 Rust 同步状态
    func syncFromRust(
        cursorPos: CursorPosition,
        inputRow: UInt16?
    ) {
        updateCursorPosition(col: cursorPos.col, row: cursorPos.row)
        currentInputRow = inputRow
    }
}
```

---

## 5. 技术方案

### 5.1 Rust FFI 接口需求

#### 已有接口
```rust
✅ terminal_get_cursor(handle, out_row, out_col) -> bool
   // 获取光标位置
```

#### 需要新增的接口

```rust
/// 1️⃣ 获取选中范围的文本
#[no_mangle]
pub extern "C" fn terminal_get_text_range(
    handle: *mut TerminalHandle,
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
    out_buffer: *mut c_char,
    buffer_size: usize,
) -> bool;

/// 功能：
/// - 获取指定范围的文本（支持多行）
/// - 正确处理：换行符、UTF-8、emoji、中文
/// - 支持历史缓冲区（10000 行）

/// 2️⃣ 直接删除选中范围
#[no_mangle]
pub extern "C" fn terminal_delete_range(
    handle: *mut TerminalHandle,
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
) -> bool;

/// 功能：
/// - 直接删除指定范围的文字
/// - 只对当前输入行有效（历史区只读）
/// - 删除后更新光标位置

/// 3️⃣ 获取当前输入行号
#[no_mangle]
pub extern "C" fn terminal_get_input_row(
    handle: *mut TerminalHandle,
    out_row: *mut u16,
) -> bool;

/// 功能：
/// - 返回当前输入行的行号
/// - 如果不在输入模式（vim/less），返回 false

/// 4️⃣ 设置选中范围（用于高亮渲染）
#[no_mangle]
pub extern "C" fn terminal_set_selection(
    handle: *mut TerminalHandle,
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
) -> bool;

/// 功能：
/// - 告诉 Rust 当前的选中范围
/// - Rust 负责渲染高亮背景

/// 5️⃣ 清除选中高亮
#[no_mangle]
pub extern "C" fn terminal_clear_selection(
    handle: *mut TerminalHandle,
) -> bool;
```

### 5.2 应用层协调器

#### 状态同步与渲染调度 (State Sync & Render Scheduling)

系统的状态同步和渲染并非通过简单的定时器轮询，而是采用一个更高效的“后台拉取 + 前台按需渲染”模型，以确保低延迟和高性能。此设计的核心由 `TerminalManagerNSView` 负责。

**核心职责**:
1.  **PTY 读取循环**: 在后台线程上，持续地调用 Rust FFI 的 `tab_manager_read_all_tabs()`，以近乎实时地检查 PTY 输出。
2.  **渲染回调注册**: 向 Rust FFI 注册一个回调函数。当 `read_all_tabs()` 检测到数据更新时，Rust 会调用此回调。
3.  **按需渲染调度**: Swift 端的回调被触发后，它仅设置一个 `needsRender` 标记，并由与屏幕刷新率同步的 `CVDisplayLink` 在下一帧执行实际渲染。

```swift
/// 终端视图管理器（简化伪代码）
///
/// 职责：协调状态同步与渲染
final class TerminalManagerNSView: NSView {

    private var tabManager: TabManagerWrapper?
    private var displayLink: CVDisplayLink?   // 与屏幕刷新同步
    private var needsRender = false          // 渲染标记（线程安全）
    private var ptyReadQueue: DispatchQueue?  // PTY 读取的后台队列

    func initialize() {
        // ... 初始化 tabManager ...

        // 1. 设置渲染回调
        tabManager.setRenderCallback { [weak self] in
            // Rust 在后台线程调用此回调
            // 仅标记需要渲染，不做实际工作
            self?.requestRender()
        }

        // 2. 启动后台 PTY 读取循环
        startPTYReadLoop()

        // 3. 启动渲染循环
        setupDisplayLink()
    }

    /// 在后台线程上持续读取 PTY 输出
    private func startPTYReadLoop() {
        ptyReadQueue.async { [weak self] in
            while !self.shouldStopReading {
                // 调用 Rust FFI，检查 PTY 更新。
                // 如果有更新，Rust 内部会触发上面设置的 setRenderCallback
                self?.tabManager?.readAllTabs()

                // 短暂休眠，防止 CPU 100% 占用
                usleep(1000) // 1ms
            }
        }
    }

    /// 设置与屏幕刷新率同步的渲染循环
    private func setupDisplayLink() {
        // ... 创建 CVDisplayLink ...
        // CVDisplayLink 的回调每一帧都会执行
        let callback: CVDisplayLinkOutputCallback = { (_, _, _, _, _, context) -> CVReturn in
            let view = Unmanaged<TerminalManagerNSView>.fromOpaque(context).takeUnretainedValue()
            
            // 检查渲染标记
            if view.needsRender {
                view.needsRender = false // 重置标记
                
                // 在主线程执行真正的渲染
                DispatchQueue.main.async {
                    view.performRender()
                }
            }
            return kCVReturnSuccess
        }
        // ... 启动 CVDisplayLink ...
    }

    /// 标记需要渲染 (线程安全)
    private func requestRender() {
        // lock()
        self.needsRender = true
        // unlock()
    }

    /// 执行实际渲染
    private func performRender() {
        self.tabManager?.renderActiveTab()
    }
}
```

#### TextSelectionCoordinator
```swift
/// 文本选中协调器
///
/// 职责：处理鼠标拖拽选中和 Shift + 方向键选中
final class TextSelectionCoordinator {
    private let windowController: WindowController

    // MARK: - 鼠标选中

    func handleMouseDown(at screenPoint: CGPoint, panelId: UUID) {
        let gridPos = convertToGrid(screenPoint, panelId: panelId)

        guard let panel = windowController.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 🎯 调用领域方法
        activeTab.startSelection(at: gridPos)

        // 通知 Rust 渲染高亮
        updateRustSelection(tab: activeTab)
    }

    func handleMouseDragged(to screenPoint: CGPoint, panelId: UUID) {
        let gridPos = convertToGrid(screenPoint, panelId: panelId)

        guard let panel = windowController.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        activeTab.updateSelection(to: gridPos)
        updateRustSelection(tab: activeTab)
    }

    // MARK: - Shift + 方向键选中

    func handleShiftArrowKey(direction: Direction, panelId: UUID) {
        guard let panel = windowController.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 如果没有选中，从当前光标位置开始
        if !activeTab.hasSelection() {
            let currentPos = activeTab.cursorState.position
            activeTab.startSelection(at: currentPos)
        }

        // 移动光标并更新选中
        let newCursorPos = activeTab.moveCursor(direction: direction)
        activeTab.updateSelection(to: newCursorPos)
        updateRustSelection(tab: activeTab)
    }

    // MARK: - Helper

    private func updateRustSelection(tab: TerminalTab) {
        guard let selection = tab.textSelection else {
            // 清除 Rust 的选中高亮
            terminalSession.clearSelection()
            return
        }

        let (start, end) = selection.normalized()
        terminalSession.setSelection(
            start: start,
            end: end
        )
    }
}
```

#### InputCoordinator
```swift
/// 输入协调器
///
/// 职责：处理 NSTextInputClient 事件，协调 IME 输入
final class InputCoordinator {
    private let windowController: WindowController

    /// 处理预编辑文本（从 NSTextInputClient 调用）
    func handlePreedit(text: String, cursorPosition: Int, panelId: UUID) {
        guard let panel = windowController.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 🎯 调用领域方法
        activeTab.updatePreedit(text, cursorPosition: cursorPosition)
    }

    /// 处理确认输入（从 NSTextInputClient 调用）
    func handleCommit(text: String, panelId: UUID) {
        guard let panel = windowController.getPanel(panelId),
              let activeTab = panel.activeTab else {
            return
        }

        // 🎯 调用领域方法（会自动处理选中替换）
        activeTab.commitInput(text)
    }
}
```

#### KeyboardCoordinator
```swift
/// 键盘协调器
///
/// 职责：处理快捷键和键盘事件
final class KeyboardCoordinator {
    private let windowController: WindowController
    private let selectionCoordinator: TextSelectionCoordinator

    func handleKeyDown(event: NSEvent, panelId: UUID) {
        // Cmd+C 复制
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            handleCopy(panelId: panelId)
            return
        }

        // Shift + 方向键 选中
        if event.modifierFlags.contains(.shift) && event.isArrowKey {
            let direction = getDirection(from: event)
            selectionCoordinator.handleShiftArrowKey(
                direction: direction,
                panelId: panelId
            )
            return
        }

        // 纯方向键 清除选中
        if event.isArrowKey {
            guard let panel = windowController.getPanel(panelId),
                  let activeTab = panel.activeTab else {
                return
            }
            activeTab.clearSelection()
        }
    }

    private func handleCopy(panelId: UUID) {
        guard let panel = windowController.getPanel(panelId),
              let activeTab = panel.activeTab,
              activeTab.hasSelection() else {
            return
        }

        // 🎯 调用领域方法获取选中文本
        guard let text = activeTab.getSelectedText() else {
            return
        }

        // 写入剪贴板
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
```

### 5.3 坐标转换（CoordinateMapper 增强）

```swift
extension CoordinateMapper {
    /// 终端网格坐标 → 屏幕坐标（用于候选框定位）
    func gridToScreen(
        col: UInt16,
        row: UInt16,
        panelOrigin: CGPoint,
        panelHeight: CGFloat,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        padding: CGFloat = 10.0
    ) -> NSRect {
        // 1. 计算光标在 Panel 内的相对位置（逻辑坐标）
        let x = panelOrigin.x + padding + CGFloat(col) * cellWidth

        // 2. Y 轴翻转（终端 row=0 在顶部，Swift row=0 在底部）
        let yFromBottom = panelHeight - padding - CGFloat(row + 1) * cellHeight
        let y = panelOrigin.y + yFromBottom

        // 3. 构建矩形
        return NSRect(
            x: x,
            y: y,
            width: cellWidth,
            height: cellHeight
        )
    }

    /// 屏幕坐标 → 终端网格坐标（用于鼠标选中）
    func screenToGrid(
        screenPoint: CGPoint,
        panelOrigin: CGPoint,
        panelHeight: CGFloat,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        padding: CGFloat = 10.0
    ) -> CursorPosition {
        // 1. 转换为 Panel 内的相对坐标
        let relativeX = screenPoint.x - panelOrigin.x - padding
        let relativeY = screenPoint.y - panelOrigin.y

        // 2. Y 轴翻转
        let contentHeight = panelHeight - 2 * padding
        let yFromTop = contentHeight - relativeY

        // 3. 转换为网格坐标
        let col = UInt16(max(0, relativeX / cellWidth))
        let row = UInt16(max(0, yFromTop / cellHeight))

        return CursorPosition(col: col, row: row)
    }
}
```

---

## 6. 实现路径

### 6.1 阶段划分

```
阶段 0：Rust FFI 接口准备（1-2 天）
├─ 检查现有接口
├─ 实现 terminal_get_text_range()
├─ 实现 terminal_delete_range()
├─ 实现 terminal_get_input_row()
├─ 实现 terminal_set_selection()
├─ 实现 terminal_clear_selection()
└─ 测试 FFI 接口

阶段 1：领域层实现（2 天）
├─ CursorPosition VO
├─ CursorState VO
├─ TextSelection VO
├─ InputState VO
├─ TerminalTab AR（核心业务方法）
└─ 单元测试（纯逻辑，不依赖 Rust）

阶段 2：基础设施层（1 天）
├─ TerminalSession 封装 FFI
├─ CoordinateMapper 增强（grid ↔ screen）
└─ 测试坐标转换

阶段 3：应用层协调器（2-3 天）
├─ 在 TerminalManagerNSView 中实现状态同步与渲染调度
├─ TextSelectionCoordinator（鼠标拖拽）
├─ KeyboardCoordinator（Shift + 方向键）
└─ 集成测试

阶段 4：表示层（1 天）
├─ 修改 TerminalManagerNSView
├─ 添加鼠标事件处理
├─ 添加键盘事件处理
└─ 测试选中高亮

阶段 5：IME 集成（3 天）
├─ InputCoordinator
├─ NSTextInputClient 实现
├─ 候选框位置计算
└─ 测试中文输入

总计：约 10-12 天
```

### 6.2 验收标准

#### 阶段 0 验收
```
✅ Rust FFI 接口全部实现并通过测试
✅ 能正确获取光标位置
✅ 能正确获取选中范围的文本（包括多行、UTF-8）
✅ 能正确删除选中范围（仅输入行）
✅ 能正确识别当前输入行
```

#### 阶段 1 验收
```
✅ 所有值对象和聚合根类实现完成
✅ 单元测试覆盖核心业务逻辑
✅ 测试：选中在输入行 → 输入替换
✅ 测试：选中在历史 → 输入不影响
✅ 测试：Shift + 方向键扩展选中
```

#### 阶段 2-5 验收
```
✅ 能用鼠标拖拽选中终端文本
✅ 选中高亮正确显示（由 Rust 渲染）
✅ Cmd+C 能复制选中的文本
✅ Shift + 方向键能扩展选中
✅ 方向键清除选中
✅ 输入中文时，选中在输入行 → 替换
✅ 输入中文时，选中在历史 → 不影响
✅ IME 候选框位置正确
```

---

## 7. 关键决策记录

### 决策 1：选中与输入的交互行为
```
问题：用户选中文本后输入中文，如何处理？

决策：采用编辑器行为（而非纯终端行为）
- 选中在输入行 → 删除选中并替换
- 选中在历史区 → 不影响选中

理由：
✅ 符合现代用户习惯（VSCode、Sublime）
✅ 提升编辑体验
✅ 与 IME 输入逻辑一致

记录日期：2025-11-20
```

### 决策 2：Shift + 方向键行为
```
问题：Shift + 方向键应该创建选中还是只移动光标？

决策：创建/扩展选中（编辑器行为）

理由：
✅ 符合现代用户习惯
✅ 提供更丰富的选中方式
✅ 与鼠标选中互补

记录日期：2025-11-20
```

### 决策 3：选中范围的边界
```
问题：选中范围是否支持历史缓冲区？

决策：支持任意历史输出（包括滚动区域）

理由：
✅ 用户需要复制历史输出
✅ iTerm2、VSCode 都支持
✅ 暂定 10000 行（可扩展为无限）

记录日期：2025-11-20
```

### 决策 4：删除选中的实现方式
```
问题：删除选中是模拟退格还是直接删除？

决策：直接删除（通过 Rust FFI）

理由：
✅ 更高效
✅ 行为更可控
✅ 避免退格键的副作用

记录日期：2025-11-20
```

### 决策 5：选中高亮的渲染方式
```
问题：选中高亮由谁负责渲染？

决策：Rust 端渲染（Swift 传递选中范围）

理由：
✅ Rust 知道字符的精确位置
✅ 性能更好（Metal 渲染）
✅ 避免坐标转换误差

记录日期：2025-11-20
```

### 决策 6：历史缓冲区大小
```
问题：历史缓冲区应该多大？

决策：暂定 10000 行，偏向无限

理由：
✅ 10000 行足够日常使用
✅ 先测试性能，再决定是否改为无限
✅ 留有扩展空间

记录日期：2025-11-20
```

---

## 8. 待解决的问题

### 问题 1：双击/三击选中
```
状态：推迟到下个阶段

复杂度：
- 双击选中单词：需要定义"单词"的边界
- 三击选中行：需要处理行尾换行

决策：先实现基础选中，后续优化
```

### 问题 2：滚动时选中保留
```
状态：需要进一步设计

问题：
- 用户选中后滚动，选中是否保留？
- 选中范围如何随滚动更新？

决策：暂不处理，后续根据用户反馈决定
```

### 问题 3：性能优化
```
状态：第一阶段不优化，实际测试后再决定

潜在优化：
- 选中范围限制（最大 1000 行）
- 文本缓存（LRU）
- 懒加载（只加载可见区域）
```

---

**文档版本**: v1.0
**创建日期**: 2025-11-20
**作者**: ETerm Team
**状态**: Draft（待 Review）
