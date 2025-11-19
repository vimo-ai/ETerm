# TerminalPoolWrapper 集成指南

本文档说明如何在主应用中集成真实的 `TerminalPoolWrapper`。

## 📋 架构概述

### 1. 协议设计

```swift
protocol TerminalPoolProtocol: AnyObject {
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int
    func closeTerminal(_ terminalId: Int) -> Bool
    func getTerminalCount() -> Int
}
```

### 2. 实现类

**MockTerminalPool** - 测试环境
- 模拟终端创建和销毁
- 跟踪终端生命周期
- 检测内存泄露

**TerminalPoolWrapper** - 生产环境
- 真实的 Rust 终端池封装
- 需要 SugarloafWrapper 实例
- 支持完整的终端功能（PTY、渲染等）

## 🚀 集成步骤

### 方案 A：在测试环境中使用真实终端池

#### 1. 创建 Sugarloaf 实例

```swift
// 在 PanelTestView 或专门的测试窗口中
@State private var sugarloaf: SugarloafWrapper? = nil

func initializeSugarloaf(in view: NSView) {
    let scale = Float(NSScreen.main?.backingScaleFactor ?? 2.0)
    let width = Float(view.bounds.width) * scale
    let height = Float(view.bounds.height) * scale

    sugarloaf = SugarloafWrapper(
        windowHandle: ...,
        displayHandle: ...,
        width: width,
        height: height,
        scale: scale,
        fontSize: 14.0
    )
}
```

#### 2. 创建 TerminalPoolWrapper

```swift
func initializeTerminalPool() {
    guard let sugarloaf = sugarloaf else { return }

    let realTerminalPool = TerminalPoolWrapper(sugarloaf: sugarloaf)
    self.terminalPool = realTerminalPool
}
```

#### 3. 传递给 PanelTestView

```swift
PanelTestContainerView(
    layoutTree: layoutTree,
    containerSize: geometry.size,
    onDragInfo: { ... },
    onTabClick: { ... },
    onLayoutChange: { ... },
    terminalPool: realTerminalPool  // 传递真实的终端池
)
```

### 方案 B：在主应用中集成（推荐）

#### 1. 修改 ContentView 或 TabTerminalView

当前主应用使用 `TabManagerWrapper`，需要逐步迁移到 `TerminalPoolWrapper` + `PanelLayoutKit`。

**步骤：**

1. **创建全局的 TerminalPoolWrapper**

```swift
// 在 WindowController 或 AppDelegate 中
class WindowController {
    private let sugarloaf: SugarloafWrapper
    private let terminalPool: TerminalPoolWrapper

    init(...) {
        self.sugarloaf = SugarloafWrapper(...)
        self.terminalPool = TerminalPoolWrapper(sugarloaf: sugarloaf)
    }
}
```

2. **替换旧的布局系统**

```swift
// 从：TabManagerWrapper + PanelLayout
// 到：TerminalPoolWrapper + PanelLayoutKit

// 旧代码
let tabManager = TabManagerWrapper(...)
tabManager.createTab()

// 新代码
let terminalId = terminalPool.createTerminal(cols: 80, rows: 24, shell: "/bin/zsh")
let newTab = TabNode(id: UUID(), title: "终端 1", rustTerminalId: terminalId)
layoutTree = layoutTree.updatingPanel(panelId) { panel in
    panel.addingTab(newTab)
}
```

3. **实现终端生命周期管理**

```swift
class LayoutManager {
    private let terminalPool: TerminalPoolProtocol
    private var tabTerminalMapping: [UUID: Int] = [:]

    func addTab(to panelId: UUID) {
        // 1. 创建终端
        let terminalId = terminalPool.createTerminal(...)

        // 2. 创建 Tab
        let newTab = TabNode(..., rustTerminalId: terminalId)
        tabTerminalMapping[newTab.id] = terminalId

        // 3. 更新布局树
        layoutTree = layoutTree.updatingPanel(panelId) { ... }
    }

    func closeTab(_ tabId: UUID) {
        // 1. 销毁终端
        if let terminalId = tabTerminalMapping[tabId] {
            terminalPool.closeTerminal(terminalId)
            tabTerminalMapping.removeValue(forKey: tabId)
        }

        // 2. 更新布局树
        layoutTree = layoutTree.removingTab(tabId)
    }
}
```

#### 2. 渲染终端

```swift
// 在布局更新后，渲染每个 Panel 的激活 Tab
func renderPanels() {
    for panel in layoutTree.allPanels() {
        guard let activeTab = panel.activeTab,
              let bounds = panelBounds[panel.id] else { continue }

        terminalPool.render(
            terminalId: activeTab.rustTerminalId,
            x: Float(bounds.x),
            y: Float(bounds.y),
            width: Float(bounds.width),
            height: Float(bounds.height),
            cols: UInt16(bounds.cols),
            rows: UInt16(bounds.rows)
        )
    }
}
```

## 🧪 测试清单

在集成 TerminalPoolWrapper 后，测试以下场景：

### 终端生命周期
- [ ] 添加 Tab - 终端正确创建
- [ ] 关闭 Tab - 终端正确销毁
- [ ] 拖拽 Tab - 终端不被销毁
- [ ] 关闭最后一个 Tab - 旧终端销毁，新终端创建

### 渲染
- [ ] 单 Panel 渲染正常
- [ ] 分割布局渲染正常
- [ ] 窗口调整大小后渲染正常
- [ ] 切换 Tab 后渲染正常

### 交互
- [ ] 键盘输入正确发送到激活的终端
- [ ] 滚动功能正常
- [ ] 文本选择和复制正常

### 内存
- [ ] 关闭窗口后终端全部销毁
- [ ] 长时间运行无内存泄露
- [ ] 终端数量与 Tab 数量一致

## 📝 注意事项

1. **终端 ID 管理**
   - 每个 Tab 必须绑定唯一的终端 ID
   - Tab 移除时必须销毁对应的终端
   - 使用 `tabTerminalMapping` 跟踪映射关系

2. **渲染协调**
   - 只渲染激活的 Tab
   - 布局变化后重新计算渲染区域
   - 避免重复渲染同一终端

3. **错误处理**
   - 终端创建失败时的回退逻辑
   - 终端销毁失败时的日志记录
   - 渲染错误的容错处理

4. **性能优化**
   - 批量创建终端时的性能
   - 大量 Tab 的内存占用
   - 渲染性能优化

## 🔗 相关文件

- `TerminalPoolProtocol.swift` - 终端池协议定义
- `TerminalPoolWrapper.swift` - 真实终端池实现
- `MockTerminalPool.swift` - 模拟终端池实现
- `PanelTestView.swift` - 测试环境集成示例

## 🎯 迁移路线图

1. ✅ 创建 TerminalPoolProtocol 协议
2. ✅ 实现 MockTerminalPool（测试）
3. ✅ 实现 TerminalPoolWrapper（生产）
4. ✅ 在 PanelTestView 中支持切换
5. ⏳ 创建带 Sugarloaf 的完整测试环境
6. ⏳ 在主应用中集成 TerminalPoolWrapper
7. ⏳ 迁移现有的 TabManagerWrapper 逻辑
8. ⏳ 删除旧的布局系统代码
