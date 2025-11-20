# 光标上下文实现文档

> ETerm 终端模拟器 - 光标、选中、IME 输入的实现总结

## 实现概览

已完成所有 5 个阶段的实现：

### 阶段 2：基础设施层 ✅

**TerminalSession**（FFI 封装层）
- 位置：`ETerm/Infrastructure/FFI/TerminalSession.swift`
- 功能：
  - 封装所有 Terminal 相关的 FFI 调用
  - 提供类型安全的 Swift 接口
  - 支持光标位置、文本选中、文本范围操作
  - 支持终端控制（滚动、调整尺寸等）

**CoordinateMapper**（坐标转换工具）
- 位置：`ETerm/Infrastructure/Coordination/CoordinateMapper.swift`
- 增强功能：
  - 终端网格坐标 ↔ 屏幕坐标转换
  - 支持 IME 候选框位置计算
  - 支持鼠标选中的坐标转换

### 阶段 3：应用层协调器 ✅

**TextSelectionCoordinator**（文本选中协调器）
- 位置：`ETerm/Application/Coordinators/TextSelectionCoordinator.swift`
- 功能：
  - 处理鼠标拖拽选中
  - 处理 Shift + 方向键选中
  - 协调 Swift 层和 Rust 层的选中状态

**KeyboardCoordinator**（键盘协调器）
- 位置：`ETerm/Application/Coordinators/KeyboardCoordinator.swift`
- 功能：
  - 处理快捷键（Cmd+C 复制、Cmd+V 粘贴）
  - 处理方向键（清除选中）
  - 处理 Shift + 方向键（扩展选中）

**InputCoordinator**（IME 输入协调器）
- 位置：`ETerm/Application/Coordinators/InputCoordinator.swift`
- 功能：
  - 处理 IME 预编辑文本（Preedit）
  - 处理确认输入（Commit）
  - 计算候选框位置
  - 处理普通文本输入

### 阶段 4：表示层 ✅

**TerminalEventHandlerView**（统一事件处理视图）
- 位置：`ETerm/Presentation/Views/TerminalEventHandlerView.swift`
- 功能：
  - 统一处理鼠标事件（点击、拖拽、滚动）
  - 统一处理键盘事件
  - 实现 NSTextInputClient 协议
  - 将事件转发给对应的协调器

**TerminalInputView**（IME 输入视图）
- 位置：`ETerm/Presentation/Views/TerminalInputView.swift`
- 功能：
  - 专门的 NSTextInputClient 实现
  - 可以作为独立的输入视图使用
  - 或作为 TerminalEventHandlerView 的参考实现

### 阶段 5：IME 集成 ✅

已在 TerminalEventHandlerView 中完整实现：
- NSTextInputClient 协议的所有必需方法
- 预编辑文本处理
- 候选框位置计算
- 输入确认和取消

### WindowController 集成 ✅

**协调器集成**
- 位置：`ETerm/Application/Controllers/WindowController.swift`
- 功能：
  - 自动创建并初始化所有协调器
  - 提供协调器的公开访问接口
  - 协调器之间的依赖注入

## 核心架构

```
┌─────────────────────────────────────────────────────────────┐
│                      表示层（Presentation）                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ TerminalEventHandlerView                             │   │
│  │ - 鼠标事件：mouseDown/mouseDragged/scrollWheel      │   │
│  │ - 键盘事件：keyDown/doCommand                        │   │
│  │ - IME 事件：NSTextInputClient                        │   │
│  └─────────────────┬────────────────────────────────────┘   │
└────────────────────┼────────────────────────────────────────┘
                     │
┌────────────────────┼────────────────────────────────────────┐
│                    │      应用层（Application）               │
│  ┌─────────────────▼────────────────────────────────────┐   │
│  │ WindowController                                     │   │
│  │ - textSelectionCoordinator                           │   │
│  │ - keyboardCoordinator                                │   │
│  │ - inputCoordinator                                   │   │
│  └──────────┬──────────────┬──────────────┬─────────────┘   │
│             │              │              │                 │
│  ┌──────────▼───┐ ┌────────▼──────┐ ┌─────▼─────────────┐  │
│  │TextSelection │ │Keyboard       │ │Input              │  │
│  │Coordinator   │ │Coordinator    │ │Coordinator        │  │
│  └──────┬───────┘ └───────┬───────┘ └────────┬──────────┘  │
└─────────┼─────────────────┼──────────────────┼─────────────┘
          │                 │                  │
┌─────────┼─────────────────┼──────────────────┼─────────────┐
│         │           领域层（Domain）          │               │
│  ┌──────▼──────────────────────────────────▼─────────┐     │
│  │ TerminalTab（聚合根）                               │     │
│  │ - cursorState: CursorState                        │     │
│  │ - textSelection: TextSelection?                   │     │
│  │ - inputState: InputState                          │     │
│  │ - terminalSession: TerminalSession                │     │
│  └──────────────────────┬────────────────────────────┘     │
└─────────────────────────┼──────────────────────────────────┘
                          │
┌─────────────────────────┼──────────────────────────────────┐
│                         │  基础设施层（Infrastructure）      │
│  ┌──────────────────────▼────────────────────────────┐     │
│  │ TerminalSession                                   │     │
│  │ - getCursorPosition()                             │     │
│  │ - getTextRange()                                  │     │
│  │ - deleteRange()                                   │     │
│  │ - setSelection()                                  │     │
│  │ - clearSelection()                                │     │
│  └──────────────────────┬────────────────────────────┘     │
│                         │                                  │
│  ┌──────────────────────▼────────────────────────────┐     │
│  │ CoordinateMapper                                  │     │
│  │ - gridToScreen()                                  │     │
│  │ - screenToGrid()                                  │     │
│  └───────────────────────────────────────────────────┘     │
└───────────────────────────────────────────────────────────┘
                          │
                          ▼
                    Rust FFI Layer
```

## 使用方式

### 1. 在视图中使用 TerminalEventHandlerView

```swift
import SwiftUI

struct TerminalContentView: View {
    @State private var windowController: WindowController

    var body: some View {
        TerminalEventHandlerViewWrapper(
            windowController: windowController,
            currentPanelId: selectedPanelId
        )
    }
}

// NSViewRepresentable 包装
struct TerminalEventHandlerViewWrapper: NSViewRepresentable {
    let windowController: WindowController
    let currentPanelId: UUID?

    func makeNSView(context: Context) -> TerminalEventHandlerView {
        let view = TerminalEventHandlerView()
        view.windowController = windowController
        view.currentPanelId = currentPanelId
        return view
    }

    func updateNSView(_ nsView: TerminalEventHandlerView, context: Context) {
        nsView.currentPanelId = currentPanelId
    }
}
```

### 2. 为 TerminalTab 注入 TerminalSession

```swift
// 创建 TerminalSession
let session = TerminalSession(cols: 80, rows: 24)

// 注入到 Tab
tab.setTerminalSession(session)

// 现在 Tab 的所有操作都会调用 FFI
tab.insertText("hello")  // 会调用 session.writeInput()
let text = tab.getSelectedText()  // 会调用 session.getTextRange()
```

### 3. 使用协调器

协调器已经在 WindowController 中自动创建，无需手动初始化：

```swift
// 通过 WindowController 访问协调器
let selectionCoordinator = windowController.textSelectionCoordinator
let keyboardCoordinator = windowController.keyboardCoordinator
let inputCoordinator = windowController.inputCoordinator

// 事件会自动由 TerminalEventHandlerView 转发给协调器
```

## 业务流程

### 文本选中流程

```
1. 用户鼠标按下
   ↓
2. TerminalEventHandlerView.mouseDown()
   ↓
3. TextSelectionCoordinator.handleMouseDown()
   ↓
4. Tab.startSelection(at: position)
   ↓
5. TerminalSession.setSelection() → Rust 渲染高亮
```

### 复制流程

```
1. 用户按下 Cmd+C
   ↓
2. TerminalEventHandlerView.keyDown()
   ↓
3. KeyboardCoordinator.handleCopy()
   ↓
4. Tab.getSelectedText()
   ↓
5. TerminalSession.getTextRange() → FFI 调用
   ↓
6. 写入系统剪贴板
```

### IME 输入流程

```
1. 用户输入拼音 "nihao"
   ↓
2. TerminalEventHandlerView.setMarkedText()
   ↓
3. InputCoordinator.handlePreedit()
   ↓
4. Tab.updatePreedit(text: "nihao")
   ↓
5. 用户选择候选词 "你好"
   ↓
6. TerminalEventHandlerView.insertText()
   ↓
7. InputCoordinator.handleCommit()
   ↓
8. Tab.commitInput(text: "你好")
   ↓
9. Tab.insertText("你好") → 自动处理选中替换
   ↓
10. TerminalSession.writeInput("你好") → FFI 调用
```

## 关键设计决策

### 1. 选中与输入的交互

- **决策**：选中在输入行时，输入替换选中；选中在历史区时，输入不影响选中
- **实现**：`Tab.isSelectionInInputLine()` 判断选中位置
- **位置**：`TerminalTab.insertText()` 方法

### 2. 协调器的职责划分

- **TextSelectionCoordinator**：只负责鼠标/键盘选中操作
- **KeyboardCoordinator**：只负责快捷键和方向键
- **InputCoordinator**：只负责 IME 输入
- **好处**：职责单一，易于测试和维护

### 3. 坐标转换的统一处理

- **决策**：所有坐标转换都通过 CoordinateMapper
- **好处**：避免坐标系混乱，统一处理 Y 轴翻转

### 4. 领域层的纯粹性

- **决策**：TerminalTab 不依赖任何 UI 框架（AppKit/SwiftUI）
- **实现**：通过依赖注入 TerminalSession
- **好处**：可以单独测试业务逻辑

## 测试建议

### 单元测试

```swift
// 测试 TerminalTab 的业务逻辑
func testSelectionInInputLine() {
    let tab = TerminalTab()
    tab.currentInputRow = 10

    tab.startSelection(at: CursorPosition(col: 0, row: 10))
    tab.updateSelection(to: CursorPosition(col: 5, row: 10))

    XCTAssertTrue(tab.isSelectionInInputLine())
}

// 测试选中替换逻辑
func testInsertTextReplacesSelection() {
    let tab = TerminalTab()
    let mockSession = MockTerminalSession()
    tab.setTerminalSession(mockSession)

    tab.currentInputRow = 10
    tab.startSelection(at: CursorPosition(col: 0, row: 10))
    tab.updateSelection(to: CursorPosition(col: 5, row: 10))

    tab.insertText("hello")

    XCTAssertTrue(mockSession.deleteRangeCalled)
    XCTAssertTrue(mockSession.writeInputCalled)
    XCTAssertNil(tab.textSelection)
}
```

### 集成测试

1. 测试鼠标选中高亮是否正确
2. 测试 Cmd+C 复制是否正确
3. 测试 IME 输入是否正确
4. 测试候选框位置是否正确

## 后续优化

### 性能优化

1. 选中范围限制（最大 1000 行）
2. 文本缓存（LRU）
3. 懒加载（只加载可见区域）

### 功能扩展

1. 双击选中单词
2. 三击选中行
3. 滚动时选中保留
4. 多光标支持（未来）

## 总结

已完成：
- ✅ 阶段 2：基础设施层（TerminalSession + CoordinateMapper）
- ✅ 阶段 3：应用层协调器（TextSelection + Keyboard + Input）
- ✅ 阶段 4：表示层（TerminalEventHandlerView）
- ✅ 阶段 5：IME 集成（NSTextInputClient）
- ✅ WindowController 集成

所有代码已实现，架构清晰，职责分明，易于测试和维护。

---

**文档版本**: v1.0
**创建日期**: 2025-11-20
**作者**: ETerm Team
**状态**: 完成（Ready for Testing）
