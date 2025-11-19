# PanelLayoutKit

PanelLayoutKit 是一个独立的 Swift Package，提供类似 VS Code/Golden Layout 的多 Panel + Tab 布局系统的拖拽重排功能。

## 特性

- 纯算法库（无 UI 依赖）
- 函数式 API 设计（不可变、纯函数）
- DDD 架构风格
- 完整的单元测试覆盖
- 支持序列化（Codable）

## 核心概念

### 数据结构

- **TabNode**: 表示一个 Tab（终端会话）
- **PanelNode**: 表示一个 Panel（Tab 容器）
- **LayoutTree**: 递归枚举，表示布局树结构
- **DropZone**: 拖拽目标区域

### 算法

- **DropZoneCalculator**: 计算 Drop Zone（参考 Golden Layout）
- **BoundsCalculator**: 计算 Panel 边界
- **LayoutRestructurer**: 处理拖拽结束后的布局重构
- **DragSession**: 管理拖拽会话状态

## 使用示例

### 1. 创建布局树

```swift
import PanelLayoutKit

// 创建 Tab
let tab1 = TabNode(title: "Terminal 1")
let tab2 = TabNode(title: "Terminal 2")

// 创建 Panel
let panel = PanelNode(tabs: [tab1], activeTabIndex: 0)

// 创建布局树（单个 Panel）
let layout = LayoutTree.panel(panel)
```

### 2. 计算 Panel 边界

```swift
let kit = PanelLayoutKit()

let containerSize = CGSize(width: 800, height: 600)
let bounds = kit.calculateBounds(layout: layout, containerSize: containerSize)

// bounds[panel.id] 包含该 Panel 的边界
```

### 3. 处理拖拽

```swift
// 创建拖拽会话
let session = kit.createDragSession(headerHeight: 30.0)

// 开始拖拽
session.startDrag(tab: tab2, sourcePanelId: sourcePanelId)

// 更新鼠标位置
session.updatePosition(
    mousePosition,
    layout: layout,
    containerSize: containerSize
)

// 结束拖拽
if let (tabId, targetPanelId, dropZone) = session.endDrag() {
    // 获取被拖拽的 Tab
    let tab = layout.findPanel(containingTab: tabId)?.tabs.first { $0.id == tabId }

    // 重构布局
    let newLayout = kit.handleDrop(
        layout: layout,
        tab: tab!,
        dropZone: dropZone,
        targetPanelId: targetPanelId
    )

    // 更新布局...
}
```

### 4. Drop Zone 类型

- **header**: 拖到 Tab 区域，添加为新 Tab
- **body**: 拖到空 Panel，填充 Panel
- **left**: 拖到左侧边缘，在左侧创建新 Panel
- **right**: 拖到右侧边缘，在右侧创建新 Panel
- **top**: 拖到顶部边缘，在顶部创建新 Panel
- **bottom**: 拖到底部边缘，在底部创建新 Panel

### 5. 布局树操作

```swift
// 查找 Panel
let panel = layout.findPanel(byId: panelId)

// 查找包含指定 Tab 的 Panel
let panel = layout.findPanel(containingTab: tabId)

// 移除 Tab
let newLayout = layout.removingTab(tabId)

// 更新 Panel
let newLayout = layout.updatingPanel(panelId) { panel in
    panel.addingTab(newTab)
}

// 获取所有 Panel
let panels = layout.allPanels()

// 获取所有 Tab
let tabs = layout.allTabs()
```

## 坐标系

PanelLayoutKit 使用 macOS 坐标系：
- 原点在左下角
- X 轴向右
- Y 轴向上

## Drop Zone 配置

默认配置：
- Hover 区域：25%（用于检测鼠标是否在该区域）
- Highlight 区域：50%（用于 UI 反馈）

可以自定义配置：

```swift
let config = DropZoneAreaConfig(
    hoverRatio: 0.3,      // hover 占 30%
    highlightRatio: 0.6   // highlight 占 60%
)

let kit = PanelLayoutKit(dropZoneConfig: config)
```

## 序列化

LayoutTree 支持 Codable，可以轻松序列化和反序列化：

```swift
// 编码
let encoder = JSONEncoder()
let data = try encoder.encode(layout)

// 解码
let decoder = JSONDecoder()
let layout = try decoder.decode(LayoutTree.self, from: data)
```

## 架构设计

PanelLayoutKit 遵循 DDD（领域驱动设计）架构：

- **Models/**: 值对象（Value Objects）
  - `TabNode`, `PanelNode`, `LayoutTree`, `DropZone`, `SplitDirection`

- **Algorithms/**: 领域服务（Domain Services）
  - `DropZoneCalculator`, `BoundsCalculator`, `LayoutRestructurer`

- **Session/**: 应用服务（Application Services）
  - `DragSession`

所有操作都是纯函数，返回新的不可变值，不修改输入。

## 测试

运行测试：

```bash
cd Packages/PanelLayoutKit
swift test
```

测试覆盖：
- 数据结构测试（TabNode, PanelNode, LayoutTree）
- 边界计算测试（水平分割、垂直分割）
- Drop Zone 计算测试（5 种区域类型）
- 布局重构测试（Header Drop, Body Drop, 边缘 Drop）
- 拖拽会话测试
- 集成测试
- 序列化测试

## 参考

- [Golden Layout](https://golden-layout.com/) - 核心算法参考
- ETerm 项目的 `BinaryTreeLayoutCalculator.swift` - 二叉树布局计算

## License

此库是 ETerm 项目的一部分，使用与主项目相同的许可证。
