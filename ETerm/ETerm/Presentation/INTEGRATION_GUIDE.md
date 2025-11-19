# Panel/Tab UI 组件集成指南

本文档说明如何将新的 Panel/Tab UI 组件集成到 ETerm 主项目中。

## 集成步骤

### 步骤 1: 在 Xcode 中添加文件

1. 打开 ETerm.xcodeproj
2. 右键点击 `ETerm/Presentation` 组
3. 选择 "Add Files to ETerm..."
4. 添加以下文件：
   - `Presentation/Views/TabItemView.swift`
   - `Presentation/Views/PanelHeaderView.swift`
   - `Presentation/Views/PanelView.swift`
   - `Application/Coordinators/DragCoordinator.swift`

### 步骤 2: 修改 WindowController

在 `WindowController.swift` 中添加 PanelLayoutKit 支持：

```swift
import PanelLayoutKit

@Observable
final class WindowController {
    // 添加 PanelLayoutKit 实例
    private let layoutKit: PanelLayoutKit

    // 添加 DragCoordinator
    private var dragCoordinator: DragCoordinator?

    init(containerSize: CGSize, scale: CGFloat) {
        // ... 现有初始化代码 ...

        // 初始化 PanelLayoutKit
        self.layoutKit = PanelLayoutKit()

        // 初始化 DragCoordinator
        self.dragCoordinator = DragCoordinator(
            windowController: self,
            layoutKit: layoutKit
        )
    }

    // 添加 Tab 拖拽处理方法（已在 DragCoordinator.swift 中声明）
    func handleTabDrop(
        tab: TabNode,
        sourcePanel: UUID,
        dropZone: DropZone,
        targetPanel: UUID
    ) {
        // TODO: 实现布局树重构逻辑
        // 1. 从 sourcePanel 移除 tab
        // 2. 根据 dropZone 类型决定如何添加到 targetPanel
        // 3. 更新 window.rootLayout
        // 4. 触发 UI 重新渲染
    }
}
```

### 步骤 3: 创建 PanelContainerView

创建一个新的 SwiftUI 视图来管理 PanelView：

```swift
//
//  PanelContainerView.swift
//  ETerm
//

import SwiftUI
import PanelLayoutKit

struct PanelContainerView: NSViewRepresentable {
    let panel: PanelNode
    let layoutKit: PanelLayoutKit
    let onTabClick: (UUID) -> Void
    let onTabDragStart: (UUID) -> Void
    let onTabClose: (UUID) -> Void
    let onAddTab: () -> Void

    func makeNSView(context: Context) -> PanelView {
        let panelView = PanelView(
            panel: panel,
            frame: .zero,
            layoutKit: layoutKit
        )

        panelView.onTabClick = onTabClick
        panelView.onTabDragStart = onTabDragStart
        panelView.onTabClose = onTabClose
        panelView.onAddTab = onAddTab

        return panelView
    }

    func updateNSView(_ nsView: PanelView, context: Context) {
        nsView.updatePanel(panel)
    }
}
```

### 步骤 4: 修改 TabTerminalView

替换现有的简单 Tab 实现：

```swift
struct TabTerminalView: View {
    @Bindable var controller: WindowController

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏（保持不变）
            HStack {
                // ... 现有工具栏代码 ...
            }

            // 终端内容
            ZStack {
                // 背景图片层
                GeometryReader { geometry in
                    Image("night")
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .opacity(0.3)
                }
                .ignoresSafeArea()

                // Panel 层
                ForEach(controller.allPanelIds, id: \.self) { panelId in
                    if let panel = controller.getPanel(panelId),
                       let bounds = controller.panelBounds[panelId] {
                        PanelContainerView(
                            panel: convertToPanelNode(panel),
                            layoutKit: controller.layoutKit,
                            onTabClick: { tabId in
                                handleTabClick(panelId: panelId, tabId: tabId)
                            },
                            onTabDragStart: { tabId in
                                handleTabDragStart(panelId: panelId, tabId: tabId)
                            },
                            onTabClose: { tabId in
                                handleTabClose(panelId: panelId, tabId: tabId)
                            },
                            onAddTab: {
                                handleAddTab(panelId: panelId)
                            }
                        )
                        .frame(
                            width: bounds.width,
                            height: bounds.height
                        )
                        .position(
                            x: bounds.origin.x + bounds.width / 2,
                            y: bounds.origin.y + bounds.height / 2
                        )
                    }
                }

                // 终端管理器视图（在 Panel 之下）
                GeometryReader { geometry in
                    TerminalManagerView(controller: controller)
                        .padding(10)
                }
            }
        }
    }

    // 辅助方法：将 EditorPanel 转换为 PanelNode
    private func convertToPanelNode(_ panel: EditorPanel) -> PanelNode {
        // TODO: 实现转换逻辑
        // 从 EditorPanel 提取 Tab 信息，构造 PanelNode
        return PanelNode(id: panel.panelId, tabs: [], activeTabIndex: 0)
    }

    private func handleTabClick(panelId: UUID, tabId: UUID) {
        // 切换激活的 Tab
        // 通知 Rust 渲染对应的 Term
    }

    private func handleTabDragStart(panelId: UUID, tabId: UUID) {
        // 开始拖拽
        // controller.dragCoordinator?.startDrag(...)
    }

    private func handleTabClose(panelId: UUID, tabId: UUID) {
        // 关闭 Tab
    }

    private func handleAddTab(panelId: UUID) {
        // 添加新 Tab
    }
}
```

### 步骤 5: 集成拖拽手势

在 PanelView 或 TabItemView 中添加拖拽手势处理：

```swift
// 在 TabItemView 的 handlePan 方法中
@objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
    switch gesture.state {
    case .began:
        onDragStart?()

    case .changed:
        // 获取全局鼠标位置
        let globalPosition = gesture.location(in: nil)
        // 通知 DragCoordinator
        // coordinator.onMouseMove(position: globalPosition)

    case .ended:
        // 结束拖拽
        // coordinator.endDrag()

    default:
        break
    }
}
```

## 数据流

```
用户操作
    ↓
TabItemView (UI)
    ↓
PanelView (回调)
    ↓
DragCoordinator (协调)
    ↓
WindowController (更新状态)
    ↓
PanelLayoutKit (重构布局)
    ↓
SwiftUI 重新渲染
    ↓
Rust 更新配置并渲染
```

## 需要实现的 TODO

### 1. EditorPanel → PanelNode 转换

在 `Domain/Models/` 中添加转换逻辑：

```swift
extension EditorPanel {
    func toPanelNode() -> PanelNode {
        let tabs = self.tabs.map { tab in
            TabNode(id: tab.id, title: tab.metadata.title)
        }
        return PanelNode(
            id: self.panelId,
            tabs: tabs,
            activeTabIndex: self.activeTabIndex
        )
    }
}
```

### 2. WindowController.handleTabDrop 实现

```swift
func handleTabDrop(
    tab: TabNode,
    sourcePanel: UUID,
    dropZone: DropZone,
    targetPanel: UUID
) {
    // 1. 获取当前布局树（需要先转换）
    // let currentLayout = window.rootLayout.toLayoutTree()

    // 2. 调用 PanelLayoutKit 重构布局
    // let newLayout = layoutKit.handleDrop(
    //     layout: currentLayout,
    //     tab: tab,
    //     dropZone: dropZone,
    //     targetPanelId: targetPanel
    // )

    // 3. 更新 window.rootLayout（需要转换回 PanelLayout）
    // window.rootLayout = newLayout.toPanelLayout()

    // 4. 触发 UI 重新渲染
    // updateRustConfigs()
}
```

### 3. LayoutTree ↔ PanelLayout 转换

在 `Domain/Models/` 中添加双向转换：

```swift
extension PanelLayout {
    func toLayoutTree() -> LayoutTree {
        switch self {
        case .leaf(let panel):
            return .panel(panel.toPanelNode())
        case .split(let direction, let first, let second, let ratio):
            return .split(
                direction: direction,
                first: first.toLayoutTree(),
                second: second.toLayoutTree(),
                ratio: ratio
            )
        }
    }
}

extension LayoutTree {
    func toPanelLayout() -> PanelLayout {
        // 反向转换
    }
}
```

## 测试计划

### 单元测试
- ✅ DropZoneCalculator 测试（已完成）
- ⏳ PanelView 单元测试
- ⏳ DragCoordinator 单元测试

### 集成测试
- ⏳ 完整的拖拽流程测试
- ⏳ Panel 分割测试
- ⏳ Tab 添加/删除测试

### UI 测试
- ⏳ 拖拽交互测试
- ⏳ 高亮显示测试
- ⏳ Rust 渲染集成测试

## 注意事项

1. **坐标系转换**：注意 macOS 坐标系（左下角原点，Y 向上）和 Rust 坐标系（左上角原点，Y 向下）的转换。

2. **性能优化**：拖拽时的 Drop Zone 计算频率很高，注意性能优化。

3. **内存管理**：确保 DragCoordinator 和 PanelView 之间的 weak 引用，避免循环引用。

4. **测试覆盖**：所有核心逻辑都应有单元测试。

## 参考资料

- [README.md](./Views/README.md) - 组件使用说明
- [IMPLEMENTATION_SUMMARY.md](./IMPLEMENTATION_SUMMARY.md) - 实现总结
- Golden Layout: `/golden-layout/src/ts/items/stack.ts`
- PanelLayoutKit: `/Packages/PanelLayoutKit/`
