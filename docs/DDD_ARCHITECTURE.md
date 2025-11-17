# ETerm DDD 架构设计文档

> 领域驱动设计（Domain-Driven Design）架构重构方案

## 📋 目录

- [1. 项目背景](#1-项目背景)
- [2. 当前架构问题](#2-当前架构问题)
- [3. 目标架构](#3-目标架构)
- [4. 领域建模](#4-领域建模)
- [5. 核心设计](#5-核心设计)
- [6. 坐标映射系统](#6-坐标映射系统)
- [7. 渲染流程](#7-渲染流程)
- [8. 关键用例](#8-关键用例)
- [9. 实现计划](#9-实现计划)

---

## 1. 项目背景

ETerm 是一个 macOS 终端模拟器，使用：
- **前端**: Swift + SwiftUI
- **后端**: Rust (Sugarloaf 渲染引擎)

### 1.1 核心需求

- ✅ 支持多 Tab 终端
- ✅ 支持分割布局（水平/垂直分割）
- 🎯 **新需求**: Panel Header（显示多个 Tab，可拖拽重新布局）
- 🎯 **新需求**: 拖拽 Header 重新排列 Panel（类似 VSCode）

---

## 2. 当前架构问题

### 2.1 问题分析

**现状**: Rust 主导布局，Swift 被动查询

```
Rust (ContextGrid)
  ├─ 维护 pane 布局树（链表：right/down/parent）
  ├─ 计算每个 pane 的位置和尺寸
  ├─ 处理 split_right/split_down
  └─ 通过 FFI 暴露位置查询 API

Swift (UI 层)
  └─ 调用 get_pane_info() 查询位置
  └─ 根据返回的位置放置 UI 元素
```

**三大痛点**:

1. **Swift 不掌控布局** → 拖拽重新布局很难实现
2. **频繁 FFI 查询位置** → 性能和复杂度问题
3. **布局逻辑分散** → Rust 和 Swift 两边都有布局逻辑，难以维护

### 2.2 现有代码问题

- 坐标转换逻辑散落在各处（`TabTerminalView.swift` line 378, 605 等）
- Rust 维护复杂的链表结构（`ContextGrid`）
- Swift 需要频繁调用 `tab_manager_get_pane_info` 查询位置
- 光标显示存在偏移问题（padding 计算不正确）

---

## 3. 目标架构

### 3.1 核心思想

**反转职责**: Swift 主导布局，Rust 被动渲染

```
Swift (UI 层) - 主导布局 ✅
  ├─ 维护 Panel 布局状态（frame: CGRect）
  ├─ 计算每个 Panel 的位置和尺寸
  ├─ 处理分割、拖拽、重新布局
  └─ 把计算好的位置和尺寸传给 Rust

Rust (渲染层) - 被动接收 ✅
  └─ 接收 Swift 传来的 (panel_id, x, y, width, height, rows, cols)
  └─ 在指定位置渲染终端内容
  └─ 不需要维护布局树
```

### 3.2 分层架构

```
┌─────────────────────────────────────────────┐
│       Presentation Layer (SwiftUI)          │
│  - TerminalWindowView                       │
│  - EditorPanelView                          │
│  - TabHeaderView                            │
│  - TerminalView (Rust 渲染视图)              │
└─────────────────────────────────────────────┘
                    ↓ 调用
┌─────────────────────────────────────────────┐
│      Application Layer (协调层)             │
│  - WindowController (@Observable)           │
│  - PanelController                          │
│  - TabController                            │
│  - EventBus (领域事件 → 应用事件)            │
└─────────────────────────────────────────────┘
                    ↓ 调用
┌─────────────────────────────────────────────┐
│         Domain Layer (核心业务)              │
│  Aggregates:                                │
│  - TerminalWindow (聚合根)                  │
│  - EditorPanel (聚合根)                     │
│  - TerminalTab (聚合根)                     │
│                                             │
│  Value Objects:                             │
│  - PanelLayout (布局树)                     │
│  - TabMetadata                              │
│  - PanelBounds                              │
│                                             │
│  Domain Services:                           │
│  - LayoutCalculator (布局算法)              │
│  - CoordinateMapper (坐标映射)              │
└─────────────────────────────────────────────┘
                    ↓ FFI
┌─────────────────────────────────────────────┐
│    Infrastructure Layer (Rust FFI)          │
│  - TerminalSession (Swift 封装)             │
│  - Rust Sugarloaf 渲染引擎                  │
└─────────────────────────────────────────────┘
```

---

## 4. 领域建模

### 4.1 聚合根设计

#### TerminalWindow AR (聚合根)

**职责**:
- 管理窗口级别的面板树
- 协调面板的创建、分割、合并
- 维护整体布局状态
- 处理窗口级别的拖拽重组

**核心属性**:
```swift
class TerminalWindow {
    let windowId: UUID
    private(set) var rootLayout: PanelLayout  // 布局树（值对象）
    private var panelRegistry: [UUID: EditorPanel]
}
```

**核心行为**:
- `splitPanel(panelId, direction)` - 分割面板
- `rearrangePanels(draggedPanelId, dropTarget)` - 拖拽重新布局
- `closePanel(panelId)` - 关闭面板

#### EditorPanel AR (聚合根)

**职责**:
- 管理该面板内的所有 Tab
- 维护 Tab 的激活状态
- 管理 Header 的显示和交互
- 控制面板级别的生命周期

**核心属性**:
```swift
class EditorPanel {
    let panelId: UUID
    private(set) var tabs: [TerminalTab]
    private(set) var activeTabId: UUID?
    private(set) var bounds: PanelBounds
    private(set) var header: PanelHeader
}
```

**核心行为**:
- `addTab(tab)` - 添加新 Tab
- `removeTab(tabId)` - 移除 Tab
- `activateTab(tabId)` - 激活 Tab
- `moveTabTo(tabId, targetPanel)` - 移动 Tab 到其他 Panel
- `prepareForDrag()` - 准备拖拽数据

#### TerminalTab AR (聚合根)

**职责**:
- 管理单个终端会话的完整生命周期
- 维护终端状态和元数据
- 处理终端输入输出
- 与 Rust 后端的终端实例对接

**核心属性**:
```swift
class TerminalTab {
    let tabId: UUID
    private(set) var metadata: TabMetadata
    private(set) var state: TabState
    private let terminalSession: TerminalSession
}
```

**核心行为**:
- `activate()` / `deactivate()` - 激活/停用
- `sendInput(data)` - 发送输入
- `handleOutput(data)` - 处理输出
- `resize(size)` - 调整终端尺寸
- `close()` - 关闭

### 4.2 值对象设计

#### PanelLayout (递归布局树)

```swift
indirect enum PanelLayout: Equatable {
    /// 叶子节点（单个面板）
    case leaf(panelId: UUID)

    /// 分割节点（包含两个子布局）
    case split(
        direction: SplitDirection,
        first: PanelLayout,
        second: PanelLayout,
        ratio: CGFloat  // 分割比例 (0.0 ~ 1.0)
    )
}

enum SplitDirection {
    case horizontal  // 水平分割（左右）
    case vertical    // 垂直分割（上下）
}
```

**优势**:
- 不可变（Immutable）
- 函数式风格，易于推理
- 支持任意复杂的布局结构

#### PanelBounds (面板位置和尺寸)

```swift
struct PanelBounds: Equatable {
    let x: CGFloat      // 左下角 x（Swift 坐标系）
    let y: CGFloat      // 左下角 y（Swift 坐标系）
    let width: CGFloat  // 宽度（逻辑坐标）
    let height: CGFloat // 高度（逻辑坐标）
}
```

---

## 5. 核心设计

### 5.1 布局计算服务

```swift
protocol LayoutCalculator {
    /// 计算分割后的布局
    func calculateSplitLayout(
        currentLayout: PanelLayout,
        targetPanelId: UUID,
        direction: SplitDirection
    ) -> PanelLayout

    /// 计算拖拽重组后的布局
    func calculateRearrangedLayout(
        currentLayout: PanelLayout,
        draggedPanelId: UUID,
        dropTarget: DropTarget
    ) -> PanelLayout

    /// 计算面板边界
    func calculatePanelBounds(
        layout: PanelLayout,
        containerSize: CGSize
    ) -> [UUID: PanelBounds]
}
```

**实现**: `BinaryTreeLayoutCalculator`（二叉树布局算法）

**优势**:
- 布局算法独立，可以单独测试
- 可以轻松替换不同的布局算法
- 聚合根不关心具体算法，只关心业务规则

---

## 6. 坐标映射系统

### 6.1 为什么需要坐标映射？

**问题**: 坐标系混乱
- Rust: 左上角原点，Y 向下
- Swift (AppKit): 左下角原点，Y 向上
- 物理坐标（像素）vs 逻辑坐标（点）
- 终端网格坐标 (col, row)

**现状**: 坐标转换逻辑散落在各处，容易出错

**解决方案**: 统一的 `CoordinateMapper` 服务

### 6.2 CoordinateMapper 设计

```swift
final class CoordinateMapper {
    private let scale: CGFloat
    private let containerBounds: CGRect

    // === Swift (AppKit) ↔ Rust (左上原点) ===

    /// Swift 坐标 → Rust 坐标
    func swiftToRust(point: CGPoint) -> CGPoint

    /// Rust 坐标 → Swift 坐标
    func rustToSwift(point: CGPoint) -> CGPoint

    // === 逻辑坐标 ↔ 物理坐标 ===

    /// 逻辑坐标 → 物理坐标（像素）
    func logicalToPhysical(value: CGFloat) -> CGFloat

    /// 物理坐标 → 逻辑坐标（点）
    func physicalToLogical(value: CGFloat) -> CGFloat

    // === 像素坐标 ↔ 终端网格坐标 ===

    /// 像素坐标 → 终端网格坐标
    func pixelToGrid(
        point: CGPoint,
        paneOrigin: CGPoint,
        paneHeight: CGFloat,
        cellSize: CGSize,
        padding: CGFloat = 10.0
    ) -> (col: UInt16, row: UInt16)

    /// 组合转换：SwiftUI 鼠标位置 → Rust 终端网格（一步到位）
    func mouseToTerminalGrid(
        mouseLocation: CGPoint,
        paneInfo: PaneInfo,
        cellSize: CGSize
    ) -> (col: UInt16, row: UInt16)
}
```

### 6.3 优势

1. **单一职责** - 所有坐标转换逻辑集中在一个地方
2. **易于测试** - 纯函数，无副作用
3. **避免重复计算** - 可以缓存常用转换结果
4. **清晰的语义** - 方法名明确表达转换意图

---

## 7. 渲染流程

### 7.1 从布局到渲染

```
1. Swift 计算布局
   LayoutCalculator.calculatePanelBounds(layout, containerSize)
   ↓
2. 得到 PanelBounds (Swift 坐标系)
   [UUID: PanelBounds]
   ↓
3. 转换为 Rust 渲染参数
   TerminalRenderConfig.from(bounds, mapper, fontMetrics)
   ↓
4. 传给 Rust
   tab_manager_update_panel_config(id, x, y, width, height, rows, cols)
   ↓
5. Rust 渲染
   tab_manager_render_all_panels()
```

### 7.2 TerminalRenderConfig

```swift
struct TerminalRenderConfig {
    // Rust 坐标系的位置（物理像素）
    let x: Float
    let y: Float
    let width: Float
    let height: Float

    // 终端网格尺寸
    let cols: UInt16
    let rows: UInt16

    // 工厂方法：从 PanelBounds 创建
    static func from(
        bounds: PanelBounds,
        mapper: CoordinateMapper,
        fontMetrics: FontMetrics,
        padding: CGFloat = 10.0
    ) -> TerminalRenderConfig {
        // 1. 扣除 padding
        let contentWidth = bounds.width - 2 * padding
        let contentHeight = bounds.height - 2 * padding

        // 2. 计算 rows 和 cols
        let cols = UInt16(max(2, contentWidth / fontMetrics.cellWidth))
        let rows = UInt16(max(1, contentHeight / fontMetrics.lineHeight))

        // 3. Swift 坐标 → Rust 坐标
        let rustOrigin = mapper.swiftToRust(...)

        // 4. 逻辑坐标 → 物理坐标（像素）
        let physicalX = mapper.logicalToPhysical(rustOrigin.x)
        // ...

        return TerminalRenderConfig(...)
    }
}
```

### 7.3 Rust 侧简化

```rust
// 之前：复杂的布局树
pub struct ContextGrid {
    root: Option<usize>,
    inner: HashMap<usize, ContextGridItem>,
    // right/down/parent 链表关系
}

// 之后：简单的配置存储
pub struct Panel {
    pane_id: usize,
    terminal: Box<TerminalHandle>,
    rich_text_id: usize,

    // 渲染配置（由 Swift 传入）
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    cols: u16,
    rows: u16,
}
```

---

## 8. 关键用例

### 8.1 Split Panel（分割面板）

**流程**:

```
1. 用户点击 "Split Right"
   ↓
2. WindowController.splitPanel(panelId, .horizontal)
   ↓
3. WindowAR.splitPanel(panelId, direction, layoutCalculator)
   ├─ 验证业务规则（Panel 是否可以分割）
   ├─ 创建新 EditorPanel（包含默认 Tab）
   ├─ 调用 LayoutCalculator.calculateSplitLayout()
   ├─ 更新 rootLayout
   └─ 发布领域事件: PanelSplitted
   ↓
4. WindowController.updateLayout()
   ├─ 计算所有 Panel 的 PanelBounds
   ├─ 转换为 TerminalRenderConfig
   └─ 调用 Rust FFI 更新配置
   ↓
5. Rust 渲染所有 Panel
```

### 8.2 拖拽重新布局

**流程**:

```
1. 用户拖动 Panel Header
   ↓
2. PanelHeaderView.onDrag
   └─ panel.prepareForDrag() 获取拖拽数据
   ↓
3. 用户拖到目标位置
   └─ UI 计算 Drop Target
   ↓
4. 用户释放鼠标（Drop）
   ↓
5. WindowController.rearrangePanels(draggedId, dropTarget)
   ↓
6. WindowAR.rearrangePanels(...)
   ├─ 验证拖拽有效性
   ├─ 调用 LayoutCalculator.calculateRearrangedLayout()
   ├─ 更新 rootLayout
   └─ 发布领域事件: LayoutChanged
   ↓
7. WindowController.updateLayout()
   └─ 重新计算并更新所有 Panel 配置
   ↓
8. UI 动画更新布局
```

### 8.3 窗口 Resize

**流程**:

```
1. 窗口尺寸变化
   ↓
2. WindowController 更新 containerSize
   ↓
3. LayoutCalculator.calculatePanelBounds(layout, newSize)
   └─ 按比例重新计算所有 PanelBounds
   ↓
4. 转换为 TerminalRenderConfig（包含新的 rows/cols）
   ↓
5. Rust FFI 更新配置
   ├─ 如果 cols/rows 变化 → 调用 terminal_resize()
   └─ 更新渲染位置
   ↓
6. 重新渲染
```

---

## 9. 实现计划

### 9.1 阶段 1: 搭建领域层骨架（第 1-2 天）

**目标**: 建立核心领域模型和基础设施

**任务**:
1. [ ] 定义值对象
   - `PanelLayout` (递归布局树)
   - `PanelBounds`
   - `TabMetadata`
   - `SplitDirection`

2. [ ] 实现三个聚合根的基础结构
   - `TerminalWindow`（基础属性和构造函数）
   - `EditorPanel`（基础属性和构造函数）
   - `TerminalTab`（基础属性和构造函数）

3. [ ] 实现领域事件基础设施
   - `DomainEvent` 协议
   - 常用事件类型（`PanelSplitted`, `TabCreated`, `LayoutChanged`）
   - `EventBus`（简单实现）

4. [ ] 单元测试
   - 测试值对象的不可变性
   - 测试聚合根的基础行为

**验收标准**:
- 能创建 `TerminalWindow` 并添加 `EditorPanel`
- 能创建 `EditorPanel` 并添加 `TerminalTab`
- 领域事件能正常发布和收集

---

### 9.2 阶段 2: 实现布局算法（第 3-4 天）

**目标**: 实现布局计算的核心逻辑

**任务**:
1. [ ] 实现 `LayoutCalculator` 协议

2. [ ] 实现 `BinaryTreeLayoutCalculator`
   - `calculateSplitLayout()` - 分割布局
   - `calculatePanelBounds()` - 计算面板位置
   - `calculateRearrangedLayout()` - 重新布局（基础版）

3. [ ] 实现布局树的辅助算法
   - `findNode()` - 查找节点
   - `replaceNode()` - 替换节点
   - `traverseLayout()` - 遍历布局树

4. [ ] 单元测试
   - 测试分割算法（垂直/水平）
   - 测试边界计算
   - 测试各种布局场景

**验收标准**:
- 给定 `PanelLayout` 和 `containerSize`，能正确计算所有 Panel 的 `PanelBounds`
- 分割后的布局比例正确（默认 50:50）
- 边界情况处理正确（最小尺寸限制）

---

### 9.3 阶段 3: 实现坐标映射系统（第 5 天）

**目标**: 统一坐标转换逻辑

**任务**:
1. [ ] 实现 `CoordinateMapper` 类
   - Swift ↔ Rust 坐标转换
   - 逻辑 ↔ 物理坐标转换
   - 像素 ↔ 终端网格坐标转换

2. [ ] 实现 `TerminalRenderConfig`
   - `from()` 工厂方法
   - 自动计算 rows/cols

3. [ ] 单元测试
   - 测试坐标转换的正确性
   - 测试边界条件
   - 测试 padding 计算

**验收标准**:
- Swift 左下角 (0, 0) 能正确转换为 Rust 左上角坐标
- 鼠标点击位置能正确转换为终端网格坐标
- rows/cols 计算正确

---

### 9.4 阶段 4: 实现 Application Layer（第 6-7 天）

**目标**: 连接领域层和表示层

**任务**:
1. [ ] 实现 `WindowController`
   - 管理 `TerminalWindow` 聚合根
   - 提供 SwiftUI 友好的 API
   - 处理领域事件

2. [ ] 实现渲染协调逻辑
   - `updateLayout()` - 更新所有 Panel 配置
   - 生成 `TerminalRenderConfig`
   - 调用 Rust FFI

3. [ ] 实现事件转换
   - 领域事件 → 应用事件
   - 发布给 Presentation Layer

**验收标准**:
- SwiftUI View 能观察 `WindowController` 的状态变化
- 布局变化能自动触发 Rust 渲染更新
- 事件流转正常

---

### 9.5 阶段 5: 重构 Presentation Layer（第 8-9 天）

**目标**: 重构 UI 层使用新的架构

**任务**:
1. [ ] 重构 `TabTerminalView`
   - 使用 `WindowController` 替代直接调用 FFI
   - 移除旧的坐标转换逻辑
   - 使用 `CoordinateMapper`

2. [ ] 实现 `EditorPanelView`
   - 显示 Panel Header
   - 显示 Tab 列表
   - 处理 Tab 切换

3. [ ] 实现 `PanelHeaderView`
   - 显示所有 Tab
   - 支持拖拽手势

4. [ ] 修复光标偏移问题
   - 使用 `CoordinateMapper` 统一处理坐标
   - 正确计算 padding

**验收标准**:
- UI 显示正常
- 光标位置正确
- 能看到 Panel Header

---

### 9.6 阶段 6: 简化 Rust 层（第 10 天）

**目标**: 移除 Rust 的布局逻辑

**任务**:
1. [ ] 简化 `ContextGrid`
   - 移除 right/down/parent 链表
   - 移除 `calculate_positions_recursive()`
   - 保留简单的 Panel 存储

2. [ ] 修改 FFI 接口
   - 添加 `tab_manager_update_panel_config()`
   - 移除 `tab_manager_get_pane_info()`（不再需要查询位置）

3. [ ] 实现新的渲染逻辑
   - Panel 根据配置渲染
   - 不需要自己计算位置

**验收标准**:
- Rust 代码大幅简化
- FFI 接口更清晰
- 渲染功能正常

---

### 9.7 阶段 7: 实现拖拽重新布局（第 11-12 天）

**目标**: 实现核心新需求

**任务**:
1. [ ] 实现拖拽手势识别
   - `PanelHeaderView` 支持拖拽
   - 计算 Drop Target

2. [ ] 实现 Drop Zone 预览
   - 显示可放置区域
   - 高亮目标位置

3. [ ] 实现 `calculateRearrangedLayout()` 完整版
   - 支持各种拖拽场景
   - 优化布局算法

4. [ ] 添加动画效果
   - Panel 移动动画
   - 平滑过渡

**验收标准**:
- 能拖动 Panel Header 到其他位置
- 布局重新排列正确
- 动画流畅

---

### 9.8 阶段 8: 测试和优化（第 13-14 天）

**目标**: 确保稳定性和性能

**任务**:
1. [ ] 集成测试
   - 测试完整的用例流程
   - 测试边界情况

2. [ ] 性能优化
   - 减少不必要的布局计算
   - 优化 FFI 调用频率
   - 缓存常用数据

3. [ ] Bug 修复
   - 修复发现的问题
   - 改进用户体验

4. [ ] 文档完善
   - 更新代码注释
   - 编写使用文档

**验收标准**:
- 所有核心功能正常
- 性能满足要求
- 无明显 Bug

---

## 10. 已知问题和技术债务

### 10.1 当前已知问题

1. **光标显示偏移** (已标记)
   - 原因: `pixelToGridCoords` 中 padding 设置为 0.0
   - 修复: 改为 10.0 并使用 `CoordinateMapper`

2. **坐标转换逻辑分散**
   - 原因: 没有统一的坐标映射服务
   - 修复: 实现 `CoordinateMapper`

3. **Rust 布局逻辑复杂**
   - 原因: 维护链表结构
   - 修复: 简化为配置存储

### 10.2 技术债务清理

重构后将移除的代码：
- `ContextGrid` 的链表逻辑
- `calculate_positions_recursive()`
- `resize_pane_recursive()`
- 散落在 `TabTerminalView.swift` 中的坐标转换代码

---

## 11. 总结

### 11.1 架构优势

1. **职责清晰**
   - Swift: 管理布局和状态
   - Rust: 渲染终端内容
   - 边界明确，易于维护

2. **易于扩展**
   - 新增布局算法：只需实现 `LayoutCalculator`
   - 新增拖拽方式：只需修改 UI 层
   - Rust 完全不需要改动

3. **易于测试**
   - 领域层无 UI 依赖，可纯逻辑测试
   - 布局算法可单独测试
   - 坐标映射可单独测试

4. **DDD 原则**
   - 充血模型：业务逻辑在 AR 内部
   - 聚合边界清晰：Window → Panel → Tab
   - 领域事件驱动：解耦业务和 UI

### 11.2 与现有架构对比

| 方面 | 现有架构 | DDD 架构 |
|------|---------|---------|
| 布局管理 | Rust 链表 | Swift 布局树 |
| 职责划分 | 模糊 | 清晰 |
| FFI 调用 | 频繁查询 | 单向传递配置 |
| 扩展性 | 困难 | 容易 |
| 测试性 | 差 | 好 |
| 坐标转换 | 分散 | 统一 |

### 11.3 风险和挑战

**低风险**:
- 项目才开发 3 天，重构成本极低
- 核心功能已验证可行
- 技术栈不变

**挑战**:
- 需要 2 周开发时间
- 需要理解 DDD 思想
- 需要重新设计 FFI 接口

**缓解措施**:
- 分阶段实施，每个阶段都有验收标准
- 先实现核心功能，再优化细节
- 保持频繁测试和反馈

---

## 附录

### A. 参考资料

- [Domain-Driven Design (Eric Evans)](https://www.domainlanguage.com/ddd/)
- [Clean Architecture (Robert C. Martin)](https://blog.cleancoder.com/uncle-bob/2012/08/13/the-clean-architecture.html)
- [VSCode 布局系统](https://github.com/microsoft/vscode)
- [Rio Terminal (参考)](https://github.com/raphamorim/rio)

### B. 术语表

| 术语 | 说明 |
|------|------|
| AR | Aggregate Root（聚合根） |
| DDD | Domain-Driven Design（领域驱动设计） |
| Panel | 面板（包含多个 Tab 的容器） |
| Pane | 窗格（Rust 侧的概念，等同于 Panel） |
| Tab | 标签页（对应一个终端会话） |
| Layout Tree | 布局树（递归的 Panel 结构） |
| FFI | Foreign Function Interface（外部函数接口） |

---

**文档版本**: v1.0
**更新日期**: 2025-11-18
**作者**: ETerm Team
**状态**: Draft
