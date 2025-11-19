# 新架构使用指南

## 架构概述

### 简化后的架构

```
Swift 层（完全控制布局）          Rust 层（纯粹渲染）
====================          =================
PageManager                   TerminalPool
  └─ Page                       └─ Terminal (id + PTY)
      └─ Panel (PanelView)
          └─ Tab (Swift)
              └─ rustTerminalId ─┐
                                 │
                                 └─> 绑定到 Rust Terminal
```

**职责分离：**
- **Swift**：管理 Page/Panel/Tab 层级，计算布局，决定渲染什么
- **Rust**：管理终端实例（PTY），渲染指定位置的终端

---

## 核心组件

### 1. TerminalPoolWrapper（Swift）

```swift
class TerminalPoolWrapper {
    // 创建终端
    func createTerminal(cols: UInt16, rows: UInt16, shell: String) -> Int

    // 读取所有终端的 PTY 输出
    func readAllOutputs() -> Bool

    // 渲染指定终端到指定位置
    func render(
        terminalId: Int,
        x: Float, y: Float,
        width: Float, height: Float,
        cols: UInt16, rows: UInt16
    ) -> Bool

    // 写入输入
    func writeInput(terminalId: Int, data: String) -> Bool

    // 滚动终端
    func scroll(terminalId: Int, deltaLines: Int32) -> Bool
}
```

### 2. TabNode（PanelLayoutKit）

```swift
public struct TabNode {
    public let id: UUID
    public var title: String
    public var rustTerminalId: Int  // 🎯 绑定 Rust 终端
}
```

---

## 使用流程

### Step 1: 初始化

```swift
// 1. 创建 Sugarloaf 和 TerminalPool
let sugarloaf = SugarloafWrapper(...)
let terminalPool = TerminalPoolWrapper(sugarloaf: sugarloaf)

// 2. 设置渲染回调
terminalPool?.setRenderCallback { [weak self] in
    self?.setNeedsDisplay = true
}

// 3. 启动后台 PTY 读取定时器
Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
    terminalPool?.readAllOutputs()
}
```

### Step 2: 创建 Tab 时绑定 Rust 终端

```swift
func createNewTab() -> TabNode {
    // 1. 在 Rust 侧创建终端
    let rustTerminalId = terminalPool.createTerminal(
        cols: 80,
        rows: 24,
        shell: "/bin/zsh"
    )

    // 2. 创建 Swift Tab，绑定 Rust 终端 ID
    let tab = TabNode(
        id: UUID(),
        title: "新终端",
        rustTerminalId: rustTerminalId
    )

    return tab
}
```

### Step 3: 渲染时遍历可见 Tab

```swift
func render() {
    // 1. 清空画布
    sugarloaf?.clear()

    // 2. 获取当前 Page 的所有可见 Tab
    let currentPage = pageManager.currentPage

    for panel in currentPage.panels {
        for tab in panel.tabs {
            // 3. 计算每个 Tab 的渲染区域（Swift 坐标系）
            let swiftBounds = calculateTabBounds(panel, tab)

            // 4. 转换为 Rust 坐标系
            let rustBounds = coordinateMapper.toRust(swiftBounds)

            // 5. 调用 Rust 渲染该终端
            terminalPool?.render(
                terminalId: tab.rustTerminalId,
                x: rustBounds.x,
                y: rustBounds.y,
                width: rustBounds.width,
                height: rustBounds.height,
                cols: calculateCols(rustBounds.width),
                rows: calculateRows(rustBounds.height)
            )
        }
    }

    // 6. 提交渲染
    sugarloaf?.render()
}
```

### Step 4: 处理用户输入

```swift
func handleKeyPress(_ key: String) {
    // 1. 获取当前激活的 Tab
    guard let activeTab = getCurrentActiveTab() else { return }

    // 2. 写入到对应的 Rust 终端
    terminalPool?.writeInput(
        terminalId: activeTab.rustTerminalId,
        data: key
    )
}
```

### Step 5: 关闭 Tab 时清理

```swift
func closeTab(_ tab: TabNode) {
    // 1. 关闭 Rust 侧的终端
    terminalPool?.closeTerminal(tab.rustTerminalId)

    // 2. 从 Swift 数据结构中移除
    currentPage.removeTab(tab)
}
```

---

## 完整示例

```swift
class PageRenderer {
    let terminalPool: TerminalPoolWrapper
    let sugarloaf: SugarloafWrapper
    let coordinateMapper: CoordinateMapper
    let pageManager: PageManager

    // MARK: - 初始化

    init() {
        self.sugarloaf = SugarloafWrapper(...)
        self.terminalPool = TerminalPoolWrapper(sugarloaf: sugarloaf)
        self.coordinateMapper = CoordinateMapper(windowHeight: ...)
        self.pageManager = PageManager()

        setupRenderCallback()
        startPTYReadTimer()
    }

    private func setupRenderCallback() {
        terminalPool.setRenderCallback { [weak self] in
            self?.needsDisplay = true
        }
    }

    private func startPTYReadTimer() {
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.terminalPool.readAllOutputs()
        }
    }

    // MARK: - Tab 管理

    func createNewTab(in panel: PanelNode) {
        // 1. 创建 Rust 终端
        let rustTerminalId = terminalPool.createTerminal(
            cols: 80,
            rows: 24,
            shell: "/bin/zsh"
        )

        guard rustTerminalId >= 0 else {
            print("创建终端失败")
            return
        }

        // 2. 创建 Swift Tab
        let tab = TabNode(
            id: UUID(),
            title: "终端 \\(rustTerminalId)",
            rustTerminalId: rustTerminalId
        )

        // 3. 添加到 Panel
        panel.addTab(tab)
    }

    func closeTab(_ tab: TabNode) {
        // 1. 关闭 Rust 终端
        terminalPool.closeTerminal(tab.rustTerminalId)

        // 2. 从 Panel 移除
        pageManager.currentPage.removeTab(tab)
    }

    // MARK: - 渲染

    func renderCurrentPage() {
        sugarloaf.clear()

        let currentPage = pageManager.currentPage

        for panel in currentPage.panels {
            for tab in panel.tabs {
                renderTab(tab, in: panel)
            }
        }

        sugarloaf.render()
    }

    private func renderTab(_ tab: TabNode, in panel: PanelNode) {
        // 1. 计算 Tab 的渲染区域
        let swiftBounds = calculateTabBounds(panel, tab)
        let rustBounds = coordinateMapper.toRust(swiftBounds)

        // 2. 计算终端网格大小
        let cols = UInt16(rustBounds.width / fontMetrics.cellWidth)
        let rows = UInt16(rustBounds.height / fontMetrics.lineHeight)

        // 3. 渲染
        terminalPool.render(
            terminalId: tab.rustTerminalId,
            x: rustBounds.x,
            y: rustBounds.y,
            width: rustBounds.width,
            height: rustBounds.height,
            cols: cols,
            rows: rows
        )
    }

    // MARK: - 输入处理

    func handleKeyPress(_ key: String) {
        guard let activeTab = pageManager.currentPage.activeTab else { return }

        terminalPool.writeInput(
            terminalId: activeTab.rustTerminalId,
            data: key
        )
    }

    func handleScroll(_ delta: Int32) {
        guard let activeTab = pageManager.currentPage.activeTab else { return }

        terminalPool.scroll(
            terminalId: activeTab.rustTerminalId,
            deltaLines: delta
        )
    }
}
```

---

## 坐标系转换

**重要**：Swift 和 Rust 使用不同的坐标系！

```
Swift (macOS):         Rust:
+----> x               +----> x
|                      |
v y (bottom-left)      v y (top-left)
```

**CoordinateMapper 使用：**

```swift
class CoordinateMapper {
    let windowHeight: CGFloat

    func toRust(_ swiftRect: CGRect) -> RustRect {
        return RustRect(
            x: Float(swiftRect.origin.x),
            y: Float(windowHeight - swiftRect.origin.y - swiftRect.height),
            width: Float(swiftRect.width),
            height: Float(swiftRect.height)
        )
    }
}
```

---

## 与旧架构的对比

| 方面 | 旧架构（TabManager） | 新架构（TerminalPool） |
|------|---------------------|---------------------|
| **Rust 职责** | 管理 Tab/Pane 层级 + 渲染 | 只管理终端 + 渲染 |
| **Swift 职责** | 只调用 Rust API | 完全控制布局 + 调用 Rust |
| **布局灵活性** | 受 Rust 限制 | Swift 完全自由 |
| **代码复杂度** | ~1500 行（Rust） | ~500 行（Rust） + ~200 行（Swift） |
| **渲染方式** | `render_active_tab()` | `render(id, x, y, w, h)` |
| **概念层级** | Tab → ContextGrid → Pane | Terminal (扁平) |

---

## 迁移建议

如果你有旧代码使用 TabManagerWrapper，迁移步骤：

1. **保留旧代码**：先不删除，新旧并存
2. **创建新的渲染分支**：在渲染逻辑中添加开关，支持新旧两套
3. **逐步迁移功能**：一次迁移一个 Page 的渲染
4. **测试验证**：确保新架构功能完整后再删除旧代码

---

## 常见问题

### Q: 为什么要简化 Rust 层？

**A:**
- 布局逻辑在 Swift 更灵活，可以使用 PanelLayoutKit
- Rust 只需要做好终端模拟（PTY）和渲染
- 降低跨语言边界的复杂度

### Q: 如何处理多个 Page？

**A:**
- Rust 不需要知道 Page 概念
- 所有 Page 的终端都在同一个 TerminalPool 中
- Swift 决定当前渲染哪个 Page 的 Tab

### Q: PTY 读取会影响性能吗？

**A:**
- 必须持续读取所有终端（不管是否可见），否则 PTY 缓冲区会满
- 使用 16ms 定时器（60 FPS），性能足够
- 只有有数据更新的终端才会触发渲染回调

### Q: 如何支持 Tab 拖拽？

**A:**
- Swift 侧管理拖拽逻辑
- 拖拽只改变 Swift 的 Panel/Tab 数据结构
- Rust 侧的 terminalId 不变，只是渲染位置改变

---

## 下一步

- [ ] 在测试窗口验证新架构
- [ ] 集成到主项目的 TabTerminalView
- [ ] 实现 Page 切换功能
- [ ] 支持 Split Panel 布局
- [ ] 完整的 Drop Zone 和拖拽功能
