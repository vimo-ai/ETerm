# Panel/Tab UI 组件说明

本目录包含 ETerm 的 Panel/Tab UI 层实现，采用充血模型设计，参考 Golden Layout 的架构。

## 架构概览

```
Page (主项目代码里的 "Tab")
└── Panel Layout Tree (二叉树布局)
    ├── Panel 1 (Stack - 容器，有 Header)
    │   ├── Tab 1 (终端会话) ◄─── Rust 渲染
    │   ├── Tab 2 (终端会话) ◄─── Rust 渲染
    │   └── Tab 3 (终端会话) ◄─── Rust 渲染
    │
    └── Split (分割节点)
        ├── Panel 2 (Stack)
        │   └── Tab 4
        └── Panel 3 (Stack)
            └── Tab 6
```

## 组件说明

### 1. TabItemView.swift

单个 Tab 的视图组件。

**功能**：
- 显示 Tab 标题和关闭按钮
- 支持点击切换激活状态
- 支持拖拽移动
- 鼠标悬停高亮

**回调**：
```swift
var onTap: (() -> Void)?        // Tab 点击
var onDragStart: (() -> Void)?  // 开始拖拽
var onClose: (() -> Void)?      // 关闭 Tab
```

### 2. PanelHeaderView.swift

Panel 的 Header 视图（Tab 栏）。

**功能**：
- 管理和显示所有 Tab
- 横向布局 Tab
- 提供添加 Tab 按钮
- 提供 Tab 边界信息（用于 Drop Zone 计算）

**主要方法**：
```swift
func setTabs(_ tabs: [UUID: String])           // 设置 Tab 列表
func getTabBounds() -> [UUID: CGRect]          // 获取 Tab 边界
func setActiveTab(_ tabId: UUID)               // 设置激活的 Tab
static func recommendedHeight() -> CGFloat     // 推荐的 Header 高度
```

### 3. PanelView.swift

Panel 容器视图（充血模型）。

**充血模型设计**：
- 持有 UI 元素（headerView, contentView, highlightLayer）
- 自己计算 Drop Zone（可以访问 subviews 的 frame）
- 自己处理高亮显示

**主要方法**：
```swift
func updatePanel(_ panel: PanelNode)                    // 更新 Panel 数据
func calculateDropZone(mousePosition: CGPoint) -> DropZone?  // 计算 Drop Zone
func highlightDropZone(_ zone: DropZone)                // 高亮 Drop Zone
func clearHighlight()                                   // 清除高亮
func setActiveTab(_ tabId: UUID)                        // 设置激活的 Tab
```

**结构**：
```
┌─────────────────────────────────┐
│ PanelView                       │
├─────────────────────────────────┤
│ HeaderView (Tab 栏)             │
│ ┌───┬───┬───┐  [+]             │
│ │ T1│ T2│ T3│                   │
│ └───┴───┴───┘                   │
├─────────────────────────────────┤
│                                 │
│ ContentView                     │
│ (Rust 渲染 Term 的区域)         │
│                                 │
│                                 │
└─────────────────────────────────┘
```

## 使用示例

### 创建 PanelView

```swift
import PanelLayoutKit

// 1. 创建 Panel 节点
let panel = PanelNode(
    id: UUID(),
    tabs: [
        TabNode(id: UUID(), title: "Shell"),
        TabNode(id: UUID(), title: "Logs")
    ],
    activeTabIndex: 0
)

// 2. 创建 PanelLayoutKit 实例
let layoutKit = PanelLayoutKit()

// 3. 创建 PanelView
let panelView = PanelView(
    panel: panel,
    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
    layoutKit: layoutKit
)

// 4. 设置回调
panelView.onTabClick = { tabId in
    print("Tab clicked: \(tabId)")
}

panelView.onTabDragStart = { tabId in
    print("Tab drag started: \(tabId)")
}

panelView.onTabClose = { tabId in
    print("Tab closed: \(tabId)")
}

panelView.onAddTab = {
    print("Add tab clicked")
}
```

### 拖拽流程

```swift
// 1. 创建 DragCoordinator
let dragCoordinator = DragCoordinator(
    windowController: windowController,
    layoutKit: layoutKit
)

// 2. 注册 PanelView
dragCoordinator.registerPanelView(panel.id, panelView: panelView)

// 3. 设置 PanelView 的拖拽回调
panelView.onTabDragStart = { tabId in
    guard let tab = panel.tabs.first(where: { $0.id == tabId }) else { return }
    dragCoordinator.startDrag(tab: tab, fromPanel: panel.id)
}

// 4. 监听鼠标移动（在拖拽手势的 .changed 状态）
func onMouseMove(event: NSEvent) {
    let globalPosition = event.locationInWindow
    dragCoordinator.onMouseMove(position: globalPosition)
}

// 5. 结束拖拽（在拖拽手势的 .ended 状态）
func onDragEnd() {
    dragCoordinator.endDrag()
}
```

## Drop Zone 计算

PanelView 使用充血模型，自己负责 Drop Zone 计算：

```swift
// PanelView 内部实现
func calculateDropZone(mousePosition: CGPoint) -> DropZone? {
    // 1. 收集 UI 边界
    let panelBounds = bounds
    let headerBounds = headerView.frame
    let tabBounds = headerView.getTabBounds()

    // 2. 调用 PanelLayoutKit 的算法
    return layoutKit.dropZoneCalculator.calculateDropZoneWithTabBounds(
        panel: panel,
        panelBounds: panelBounds,
        headerBounds: headerBounds,
        tabBounds: tabBounds,
        mousePosition: mousePosition
    )
}
```

## 与 Rust 层的集成

PanelView 的 `contentView` 是透明的，Rust 在这个区域渲染 Term：

```swift
// 在 WindowController 中
func updateRustConfigs() {
    let configs = panelRenderConfigs

    for (panelId, config) in configs {
        let rustPanelId = registerPanel(panelId)

        tab_manager_update_panel_config(
            tabManager.handle,
            size_t(rustPanelId),
            config.x,
            config.y,
            config.width,
            config.height,
            config.cols,
            config.rows
        )
    }
}
```

## 测试

PanelLayoutKit 包含完整的单元测试：

```bash
cd Packages/PanelLayoutKit
swift test
```

测试覆盖：
- DropZoneCalculator：10 个测试用例
- 所有核心算法（Body/Header Drop Zone 计算）
- Tab 边界精确计算

## 参考

- Golden Layout: `/golden-layout/src/ts/items/stack.ts`
- PanelLayoutKit: `/Packages/PanelLayoutKit/`
- DDD 架构文档: 项目根目录的设计文档
