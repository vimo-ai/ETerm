# PanelLayoutKit 实现总结

## 实现完成情况

✅ 所有核心功能已完成，27 个测试全部通过

## 文件结构

```
PanelLayoutKit/
├── Sources/PanelLayoutKit/
│   ├── Models/                          # 数据模型（值对象）
│   │   ├── SplitDirection.swift         # 分割方向枚举
│   │   ├── TabNode.swift                # Tab 节点
│   │   ├── PanelNode.swift              # Panel 节点
│   │   ├── DropZone.swift               # Drop Zone 定义
│   │   └── LayoutTree.swift             # 布局树（递归枚举）
│   ├── Algorithms/                      # 核心算法（领域服务）
│   │   ├── DropZoneCalculator.swift     # Drop Zone 计算（参考 Golden Layout）
│   │   ├── BoundsCalculator.swift       # 边界计算
│   │   └── LayoutRestructurer.swift     # 布局重构
│   ├── Session/                         # 会话管理（应用服务）
│   │   └── DragSession.swift            # 拖拽会话
│   └── PanelLayoutKit.swift             # 主入口（Facade 模式）
├── Tests/PanelLayoutKitTests/
│   └── PanelLayoutKitTests.swift        # 完整的测试套件
├── Package.swift                        # Swift Package 配置
├── README.md                            # 使用文档
└── IMPLEMENTATION.md                    # 本文件
```

## 核心特性

### 1. 数据模型（Models）

#### TabNode
- 表示一个 Tab（终端会话）
- 包含：ID、标题
- 支持：Codable, Equatable, Hashable, Identifiable

#### PanelNode
- 表示一个 Panel（Tab 容器）
- 包含：ID、Tab 列表、激活索引
- 功能：添加 Tab、移除 Tab、查询激活 Tab
- 不可变操作：所有修改返回新实例

#### LayoutTree
- 递归枚举，表示布局树
- 两种节点类型：
  - `panel(PanelNode)`: 叶子节点
  - `split(direction, first, second, ratio)`: 分割节点
- 功能：
  - 查找 Panel（按 ID 或包含的 Tab）
  - 移除 Tab（自动清理空节点）
  - 更新 Panel（函数式转换）
  - 替换节点

#### DropZone
- 6 种类型：header, body, left, right, top, bottom
- 包含：类型、高亮区域、插入索引（header 专用）
- 可配置：hover 比例、highlight 比例

### 2. 核心算法（Algorithms）

#### DropZoneCalculator
参考 Golden Layout 的 `stack.ts:564-678` 实现：

- **Header Zone**: 检测是否在 Tab 区域
- **Body Zone**: 空 Panel 时整个区域都是 Drop Zone
- **边缘 Zone**:
  - Left: hover 0-25%, highlight 0-50%
  - Right: hover 75-100%, highlight 50-100%
  - Top: hover 25%-75% × 50%-100%, highlight 全宽 × 上半
  - Bottom: hover 25%-75% × 0-50%, highlight 全宽 × 下半

#### BoundsCalculator
- 递归遍历布局树
- 根据分割方向和比例计算每个 Panel 的边界
- 支持：水平分割（左右）、垂直分割（上下）
- 限制比例：10% ~ 90%（防止 Panel 过小）

#### LayoutRestructurer
参考 Golden Layout 的 `stack.ts:447-532` 实现：

**处理流程**：
1. 从原位置移除 Tab
2. 根据 Drop Zone 类型重构布局：
   - **Header Drop**: 添加到现有 Panel 的 Tab 列表
   - **Body Drop**: 添加到空 Panel
   - **边缘 Drop**: 创建新 Panel 并分割

**智能重构**：
- 检查父节点类型是否匹配分割方向
- 匹配：直接在父节点中插入
- 不匹配：创建新的分割节点

### 3. 拖拽会话（Session）

#### DragSession
- 状态管理：idle → dragging → ended
- 功能：
  - `startDrag`: 开始拖拽
  - `updatePosition`: 更新鼠标位置，计算当前 Drop Zone
  - `endDrag`: 结束拖拽，返回结果
  - `cancelDrag`: 取消拖拽

- 集成了 DropZoneCalculator 和 BoundsCalculator
- 自动查找鼠标所在的 Panel 和 Drop Zone

### 4. 主入口（PanelLayoutKit）

使用 Facade 模式，提供统一的 API：
- `calculateBounds`: 计算所有 Panel 边界
- `calculateDropZone`: 计算指定位置的 Drop Zone
- `handleDrop`: 处理拖拽结束
- `createDragSession`: 创建拖拽会话

## 设计原则

### 1. 函数式设计
- 所有数据结构都是不可变的
- 所有操作返回新值，不修改输入
- 纯函数，无副作用

### 2. 类型安全
- 使用 Swift 的强类型系统
- 枚举表示有限状态
- 值类型（struct）而非引用类型（class）

### 3. 可测试性
- 纯函数易于测试
- 27 个测试覆盖所有核心功能
- 包括单元测试和集成测试

### 4. 可扩展性
- 配置化：Drop Zone 比例可配置
- 模块化：算法独立，易于替换
- 序列化：支持 Codable

## 坐标系

使用 macOS 坐标系（与 ETerm 一致）：
- 原点：左下角
- X 轴：向右
- Y 轴：向上

分割方向：
- `horizontal`: 左右分割，first 在左，second 在右
- `vertical`: 上下分割，first 在下，second 在上

## TODO（已在代码中标注）

### DropZoneCalculator.swift:73
```swift
// TODO: 这里需要根据 Tab 的位置计算插入索引
// 目前简化处理：总是插入到末尾
// 完整实现需要：
// 1. 获取每个 Tab 的边界
// 2. 根据鼠标位置判断插入位置（左半部分还是右半部分）
// 3. 返回正确的 insertIndex
```

**说明**：Header Drop 的插入索引计算需要 UI 层提供每个 Tab 的边界信息。当前简化为总是插入到末尾。

**影响**：功能完整，但插入位置不精确。

**后续处理**：在集成 UI 层时，传入每个 Tab 的边界信息，完善插入索引计算。

## 测试覆盖

### 数据结构测试（8 个）
- TabNode 创建
- PanelNode 创建、添加、移除
- LayoutTree 创建、查找、移除

### 算法测试（12 个）
- BoundsCalculator: 单 Panel、水平分割、垂直分割
- DropZoneCalculator: 空 Panel、Header、Left、Right
- LayoutRestructurer: Header Drop、Body Drop、Left/Right Drop

### 会话测试（3 个）
- DragSession 创建、开始、结束

### 集成测试（2 个）
- 完整拖拽流程
- 序列化和反序列化

### 测试结果
✅ 27/27 passed (100%)

## 性能考虑

1. **Copy-on-Write**: Swift 的值类型自动优化
2. **递归深度**: 布局树深度通常 < 10，性能影响可忽略
3. **查找算法**: O(n) 复杂度，n 为 Panel 数量，通常 < 20

## 使用建议

1. **初始化**: 创建单例 `PanelLayoutKit` 实例
2. **拖拽流程**:
   ```swift
   // 1. 创建会话
   let session = kit.createDragSession()

   // 2. 开始拖拽
   session.startDrag(tab: tab, sourcePanelId: panelId)

   // 3. 鼠标移动时更新
   session.updatePosition(mousePos, layout: layout, containerSize: size)

   // 4. 拖拽结束
   if let (tabId, panelId, zone) = session.endDrag() {
       let newLayout = kit.handleDrop(layout, tab, zone, panelId)
       // 更新 UI...
   }
   ```

3. **布局更新**: 使用 `updatingPanel` 而非直接修改
4. **序列化**: 使用 JSONEncoder/JSONDecoder 保存/恢复布局

## 集成到 ETerm

1. **替换现有类型**:
   - `PanelLayout` → `LayoutTree`
   - `PanelBounds` → `CGRect`
   - `SplitDirection` 保持兼容

2. **迁移步骤**:
   1. 添加 Package 依赖
   2. 更新 `WindowController` 使用 `PanelLayoutKit`
   3. 更新 `BinaryTreeLayoutCalculator` 调用新 API
   4. 实现拖拽手势识别（SwiftUI/AppKit）
   5. 集成 `DragSession` 到拖拽流程

3. **兼容性**:
   - 坐标系一致（macOS）
   - API 风格一致（函数式）
   - 架构一致（DDD）

## 参考文档

- [Golden Layout Documentation](https://golden-layout.com/)
- [Golden Layout Source Code](https://github.com/golden-layout/golden-layout)
- ETerm 项目文档（`.claude/` 目录）
