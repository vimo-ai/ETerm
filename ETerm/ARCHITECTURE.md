# DDD 架构重构总结

## 概述

成功将终端渲染和布局管理从 MVVM 回调模式重构为 DDD 架构，实现了单向数据流和清晰的职责分离。

## 核心改进

### 1. 聚合根增强

#### TerminalTab (Domain/Aggregates/TerminalTab.swift)
- **新增属性**: `rustTerminalId: UInt32?` - 持有终端 ID 用于渲染
- **新增方法**: `setRustTerminalId(_ terminalId: UInt32)` - 设置终端 ID

#### EditorPanel (Domain/Aggregates/EditorPanel.swift)
- **新增属性**: `bounds: CGRect` - 持有 Panel 的位置和尺寸
- **新增方法**:
  - `updateBounds(_ newBounds: CGRect)` - 更新位置
  - `getActiveTabForRendering(headerHeight:)` - 获取激活的 Tab 用于渲染
  - `setActiveTab(_ tabId: UUID)` - 切换激活的 Tab

#### TerminalWindow (Domain/Aggregates/TerminalWindow.swift)
- **核心方法**:
  - `getActiveTabsForRendering(containerBounds:headerHeight:) -> [(UInt32, CGRect)]`
    - 从所有 Panel 收集需要渲染的 Tab
    - 计算每个 Panel 的 bounds
    - 返回 `(terminalId, contentBounds)` 数组
- **内部方法**:
  - `updatePanelBounds(containerBounds:)` - 更新所有 Panel 的 bounds
  - `calculatePanelBounds(layout:availableBounds:)` - 递归计算布局树中每个 Panel 的 bounds

### 2. 新建协调器

#### TerminalWindowCoordinator (Infrastructure/Coordination/TerminalWindowCoordinator.swift)
**职责**：
- 连接 Domain AR 和基础设施层
- 管理终端生命周期（创建、销毁）
- 协调渲染流程

**核心方法**：

##### 终端管理
```swift
func setTerminalPool(_ pool: TerminalPoolProtocol)
func updateCoordinateMapper(scale: CGFloat, containerBounds: CGRect)
func updateFontMetrics(_ metrics: SugarloafFontMetrics)
```

##### 用户交互（从 UI 层调用）
```swift
func handleTabClick(panelId: UUID, tabId: UUID)
func handleTabClose(panelId: UUID, tabId: UUID)
func handleAddTab(panelId: UUID)
func handleSplitPanel(panelId: UUID, direction: SplitDirection)
```

##### 渲染流程（核心）
```swift
func renderAllPanels(containerBounds: CGRect)
```

**数据流示例**：
```
用户点击 Tab → handleTabClick(panelId, tabId)
                ↓
            panel.setActiveTab(tabId)  // 调用 AR 方法
                ↓
            objectWillChange.send()    // 通知 SwiftUI
                ↓
            renderView.requestRender()  // 触发渲染
                ↓
            renderAllPanels(containerBounds)
                ↓
            terminalWindow.getActiveTabsForRendering()  // 从 AR 读取数据
                ↓
            terminalPool.render(...)    // 调用 Rust 渲染
```

### 3. 新建视图层

#### DomainPanelView (Presentation/Views/DomainPanelView.swift)
- **架构原则**：
  - 从 EditorPanel AR 读取数据
  - 不持有状态，只负责显示
  - 用户操作直接调用 Coordinator 方法

#### DDDTerminalView (Presentation/Views/DDDTerminalView.swift)
- **完整的 DDD 架构视图**：
  - `DDDTerminalView` (SwiftUI 入口)
  - `DDDRenderView` (NSViewRepresentable)
  - `DDDPanelRenderView` (渲染视图，管理 Metal 层和 CVDisplayLink)

**关键特性**：
- 从 AR 拉取数据进行渲染
- 不使用回调，通过 Coordinator 调用 AR 方法
- 单向数据流：AR → UI

## 架构对比

### 旧架构（MVVM 回调模式）
```
❌ 问题：
- 三套模型并存（Domain AR + PanelLayoutKit + UI 层回调）
- 状态分散，数据流双向
- 回调满天飞（onTabClick, onDragStart, onTabClose 等）
- UI 层持有状态，难以追踪变化

数据流：
TabItemView.onTap → PanelView.onTabClick → Coordinator.handleTabClick
                                              ↓
                                          layoutTree.updatePanel()
                                              ↓
                                          updatePanelViews()
                                              ↓
                                          panelView.updatePanel()
```

### 新架构（DDD 单向数据流）
```
✅ 优势：
- Domain AR 是唯一的状态来源
- UI 层无状态，只负责显示和捕获输入
- 数据流单向：AR → Coordinator → UI
- 清晰的职责分离

数据流：
用户操作 → Coordinator.handleXXX()
             ↓
         AR.method()  // 修改状态
             ↓
         objectWillChange.send()
             ↓
         renderView.requestRender()
             ↓
         AR.getActiveTabsForRendering()  // 读取数据
             ↓
         Rust 渲染
```

## 渲染流程（DDD 版本）

```swift
// 1. 用户输入 → Coordinator 调用 AR 方法
coordinator.handleTabClick(panelId: panelId, tabId: tabId)

// 2. AR 修改状态
panel.setActiveTab(tabId)

// 3. 触发渲染
renderView.requestRender()

// 4. 从 AR 拉取数据
func performRender() {
    // 从 AR 收集所有需要渲染的 Tab
    let tabsToRender = terminalWindow.getActiveTabsForRendering(
        containerBounds: bounds,
        headerHeight: 30
    )

    // 统一调用 Rust 渲染
    for (terminalId, contentBounds) in tabsToRender {
        let rustRect = coordinateMapper.swiftToRust(rect: contentBounds)
        let cols = calculateCols(...)
        let rows = calculateRows(...)

        terminalPool.render(
            terminalId: terminalId,
            x: rustRect.origin.x,
            y: rustRect.origin.y,
            width: rustRect.width,
            height: rustRect.height,
            cols: cols,
            rows: rows
        )
    }

    // Sugarloaf 最终渲染
    sugarloaf.render()
}
```

## 关键设计决策

### 1. 为什么 AR 持有 bounds？
- **原因**：AR 是布局状态的唯一来源，bounds 是布局的一部分
- **好处**：
  - 简化布局计算逻辑
  - 避免 UI 层持有状态
  - AR 可以根据 bounds 计算渲染位置

### 2. 为什么 Tab 持有 rustTerminalId？
- **原因**：Tab 和终端是一对一映射，这是业务规则
- **好处**：
  - 清晰的生命周期管理
  - 避免额外的映射表
  - AR 可以直接提供渲染所需的 terminalId

### 3. 为什么需要 Coordinator？
- **原因**：连接 Domain 层和基础设施层
- **职责**：
  - 管理终端生命周期（Infrastructure）
  - 调用 AR 方法（Domain）
  - 协调渲染流程（Infrastructure）
- **不做**：持有业务状态（状态在 AR 中）

## 兼容性说明

### 保留的组件
- **PanelLayoutKit**: 仍然可以用于辅助布局计算（可选）
- **CoordinateMapper**: 用于坐标系转换（Swift ↔ Rust）
- **TerminalPoolWrapper**: 终端池基础设施
- **SugarloafWrapper**: 渲染引擎

### 新旧视图共存
- **旧视图**: `TabTerminalView` (使用 LayoutTree + 回调模式)
- **新视图**: `DDDTerminalView` (使用 Domain AR + 单向数据流)
- **可以共存**：互不干扰，便于逐步迁移

## 测试建议

### 1. 单元测试（Domain 层）
```swift
func testGetActiveTabsForRendering() {
    // 创建 TerminalWindow
    let tab1 = TerminalTab(tabId: UUID(), title: "Tab 1", rustTerminalId: 1)
    let panel = EditorPanel(initialTab: tab1)
    let window = TerminalWindow(initialPanel: panel)

    // 测试渲染数据收集
    let tabs = window.getActiveTabsForRendering(
        containerBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
        headerHeight: 30
    )

    XCTAssertEqual(tabs.count, 1)
    XCTAssertEqual(tabs[0].0, 1)  // terminalId
}
```

### 2. 集成测试
- 测试 split 操作：创建新 Panel，验证终端创建
- 测试 Tab 切换：验证渲染位置正确
- 测试 Tab 关闭：验证终端销毁

### 3. UI 测试
- 使用 `DDDTerminalView` 启动应用
- 验证：split、tab 切换、拖拽等功能正常
- 验证：终端输入输出正常

## 下一步优化

### 1. 完全移除回调模式
- 删除 `TabTerminalView` 中的旧 `TerminalCoordinator`
- 统一使用 `TerminalWindowCoordinator`

### 2. 增强 AR 方法
- `TerminalWindow.removeTab(tabId:)` - 删除 Tab
- `TerminalWindow.moveTab(from:to:)` - 移动 Tab
- `TerminalWindow.removeSplit(panelId:)` - 删除分割

### 3. 事件溯源（可选）
- 记录所有 AR 方法调用
- 用于调试和重放
- 实现 undo/redo

## 总结

通过这次重构，我们成功实现了：

✅ **单一数据源**: Domain AR 是唯一的状态来源
✅ **单向数据流**: AR → UI，无回调
✅ **清晰的职责**: AR 管理状态，Coordinator 协调，UI 只显示
✅ **易于测试**: Domain 层可以独立测试
✅ **易于维护**: 数据流清晰，变化容易追踪

这是一个**真正的 DDD 架构**，符合领域驱动设计的核心原则。
