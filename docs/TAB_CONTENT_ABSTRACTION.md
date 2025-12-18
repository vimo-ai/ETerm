# Tab 内容抽象重构设计

## 1. 设计目标

将 Tab 从"终端专用聚合根"改为"通用容器 + 可插拔内容"，支持多种内容类型：
- Terminal（现有）
- View（SwiftUI 视图，如插件面板）
- 未来扩展（文件编辑器、日志查看器等）

## 2. 核心设计

### 2.1 类型定义

```
┌─────────────────────────────────────────────────────────────┐
│                         Tab（容器壳）                        │
│  - id: UUID                                                 │
│  - title: String                                            │
│  - isActive: Bool                                           │
│  - content: TabContent                                      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    TabContent（内容枚举）                    │
│  case terminal(TerminalTabContent)                          │
│  case view(ViewTabContent)                                  │
└─────────────────────────────────────────────────────────────┘
                    │                    │
                    ▼                    ▼
        ┌──────────────────┐  ┌──────────────────┐
        │TerminalTabContent│  │  ViewTabContent  │
        │ - rustTerminalId │  │  - viewId        │
        │ - cursorState    │  │  - pluginId      │
        │ - textSelection  │  │  - viewProvider  │
        │ - inputState     │  │                  │
        │ - searchInfo     │  │                  │
        │ - ...            │  │                  │
        └──────────────────┘  └──────────────────┘
```

### 2.2 新文件结构

```
Core/Layout/Domain/
├── Aggregates/
│   └── Tab.swift                    # 新：Tab 容器壳
├── ValueObjects/
│   ├── TabContent.swift             # 新：内容枚举
│   └── ViewTabContent.swift         # 新：View 内容
│
Core/Terminal/Domain/
├── Aggregates/
│   └── TerminalTab.swift            # 改名：TerminalTabContent
```

## 3. 改造清单（按顺序）

### Phase 1: 定义新类型（不破坏现有代码）

| 文件 | 操作 | 说明 |
|-----|------|------|
| `Core/Layout/Domain/Aggregates/Tab.swift` | 新建 | Tab 容器壳 |
| `Core/Layout/Domain/ValueObjects/TabContent.swift` | 新建 | 内容枚举 |
| `Core/Layout/Domain/ValueObjects/ViewTabContent.swift` | 新建 | View 内容类型 |
| `Core/Terminal/Domain/Aggregates/TerminalTabContent.swift` | 重命名 | 从 TerminalTab 改名 |

### Phase 2: 改造 EditorPanel

| 文件 | 改动 |
|-----|------|
| `EditorPanel.swift` | `tabs: [TerminalTab]` → `tabs: [Tab]` |
| `EditorPanel.swift` | 添加 `activeTerminalContent` 便捷访问器 |
| `EditorPanel.swift` | `getActiveTabForRendering` 返回 `TabRenderable` |

### Phase 3: 改造渲染管线

| 文件 | 改动 |
|-----|------|
| `Page.swift` | `getActiveTabsForRendering` 返回 `[TabRenderable]` |
| `TerminalWindow.swift` | 同步更新 |
| `TerminalWindowCoordinator.swift` | 过滤 terminal 类型进行渲染 |

### Phase 4: 改造 Session 持久化

| 文件 | 改动 |
|-----|------|
| `SessionManager.swift` | `TabState` 添加 `contentType` 字段 |
| `WindowManager.swift` | 恢复时按 contentType 创建对应内容 |

### Phase 5: 改造视图层

| 文件 | 改动 |
|-----|------|
| `PanelView.swift` | 支持渲染非 terminal 内容 |
| `TabItemView.swift` | 通用化，不强依赖 rustTerminalId |
| `PanelHeaderView.swift` | 适配新的 Tab 数据结构 |

## 4. 向后兼容策略

### 4.1 Session 兼容
- 旧 session 无 `contentType` 字段 → 默认为 `"terminal"`
- 新 session 始终写入 `contentType`

### 4.2 API 兼容（过渡期）
保留以下便捷方法，内部转发到新结构：
```swift
extension EditorPanel {
    // 过渡期 API，方便现有代码迁移
    var activeTerminalContent: TerminalTabContent? {
        guard let tab = activeTab,
              case .terminal(let content) = tab.content else {
            return nil
        }
        return content
    }
}
```

### 4.3 渲染兼容
```swift
enum TabRenderable {
    case terminal(terminalId: Int, bounds: CGRect)
    case view(viewId: String, bounds: CGRect)

    // 便捷方法：只取 terminal
    static func filterTerminals(_ items: [TabRenderable]) -> [(Int, CGRect)] {
        items.compactMap {
            if case .terminal(let id, let bounds) = $0 {
                return (id, bounds)
            }
            return nil
        }
    }
}
```

## 5. 关键接口定义

### 5.1 Tab（容器壳）

```swift
final class Tab {
    let tabId: UUID
    private(set) var title: String
    private(set) var isActive: Bool
    private(set) var content: TabContent

    init(tabId: UUID, title: String, content: TabContent)

    func activate()
    func deactivate()
    func setTitle(_ newTitle: String)
}
```

### 5.2 TabContent（内容枚举）

```swift
enum TabContent {
    case terminal(TerminalTabContent)
    case view(ViewTabContent)

    var id: UUID {
        switch self {
        case .terminal(let c): return c.contentId
        case .view(let c): return c.contentId
        }
    }
}
```

### 5.3 TerminalTabContent（原 TerminalTab 核心）

```swift
final class TerminalTabContent {
    let contentId: UUID

    // 终端特有属性
    private(set) var cursorState: CursorState
    private(set) var textSelection: TextSelection?
    private(set) var inputState: InputState
    private(set) var rustTerminalId: Int?
    private(set) var currentInputRow: UInt16?
    private(set) var displayOffset: Int
    private(set) var pendingCwd: String?
    private(set) var searchInfo: TabSearchInfo?

    // 所有原 TerminalTab 的方法迁移到这里
}
```

### 5.4 ViewTabContent

```swift
final class ViewTabContent {
    let contentId: UUID
    let viewId: String           // 视图标识符
    let pluginId: String?        // 关联的插件 ID（可选）

    // View 内容不需要复杂状态，主要是标识
}
```

## 6. 实施状态（2025/12）

### ✅ Phase 1: 定义新类型（已完成）

- [x] `Tab.swift` - 新建 Tab 容器壳
- [x] `TabContent.swift` - 新建内容枚举和 TabRenderable
- [x] `ViewTabContent.swift` - 新建 View 内容类型
- [x] `TerminalTab.swift` - 添加 TabContent 适配（typealias TerminalTabContent = TerminalTab）

### ✅ Phase 2: 改造 EditorPanel（已完成）

- [x] 添加 `getActiveTabRenderable(headerHeight:)` 方法
- [x] 添加 `activeTerminalContent` 便捷访问器
- [x] 添加 `wrapActiveTabAsContainer()` 桥接方法
- [x] 保留 `tabs: [TerminalTab]`（向后兼容）
- [x] 添加 `@available(*, deprecated)` 警告到旧 API

### ✅ Phase 3: 改造渲染管线（已完成）

- [x] `Page.swift` - 添加 `getActiveTabRenderables()` 返回 `[TabRenderable]`
- [x] `TerminalWindow.swift` - 同步更新
- [x] 保留旧 API 并标记 deprecated

### ✅ Phase 4: 改造 Session 持久化（已完成）

- [x] `SessionManager.swift` - 添加 `TabContentType` 枚举
- [x] `TabState` 添加 `contentType`、`viewId`、`pluginId` 字段
- [x] 添加 View Tab 专用初始化器
- [x] `resolvedContentType` 处理向后兼容
- [x] `WindowManager.swift` - 恢复时检查 contentType

### ✅ Phase 5: 彻底迁移到 [Tab]（已完成）

- [x] `EditorPanel.tabs` 从 `[TerminalTab]` 改为 `[Tab]`
- [x] `Tab` 类添加完整的便捷属性（透传到 TerminalTabContent）
- [x] 更新 `TerminalWindow.createTab` 返回 `Tab`
- [x] 更新 `TerminalWindowCoordinator` 所有相关方法
- [x] 更新 `WindowManager` 跨窗口拖拽方法
- [x] 更新 `RioTerminalView` 选择相关代码
- [x] `DomainPanelView.swift` - 根据 Tab 内容类型切换渲染
- [x] 插件系统集成 - `createViewTab` API 实现

## 7. 当前架构状态（已完成彻底迁移）

```
EditorPanel.tabs: [Tab]               ← 已改为 [Tab]
                       │
                       ▼
                     Tab（容器壳）
                       │
                       ▼
                  TabContent（枚举）
                    /        \
                   /          \
    .terminal(TerminalTab)   .view(ViewTabContent)
                   │
                   ▼
              TabRenderable ← getActiveTabRenderable()
               .terminal()
               .view()
```

**架构特点**：
- `EditorPanel.tabs` 已改为 `[Tab]`，完全支持多内容类型
- `Tab` 提供丰富的便捷属性，透传到 `TerminalTabContent`
- `TabRenderable` 统一渲染接口
- Session 支持保存/恢复多种 Tab 类型
- 便捷初始化器保持现有代码兼容

## 8. 实施注意事项

1. **保持编译通过**：每个 Phase 完成后确保编译通过
2. **不删除旧代码**：先 deprecate，确认无问题后再删除
3. **测试终端功能**：每个 Phase 后验证终端基本操作（输入、选择、滚动）
4. **Session 迁移测试**：Phase 4 后测试旧 session 能正常加载

## 9. 插件 View Tab API 设计

### 9.1 放置方式枚举

```swift
/// View Tab 的放置方式
enum ViewTabPlacement {
    /// 分栏创建新 Panel（默认，类似 Ctrl+D）
    case split(SplitDirection)
    /// 在当前 Panel 新增 Tab（类似 Ctrl+T）
    case tab
    /// 创建独立 Page
    case page
}
```

### 9.2 PluginContext API

```swift
/// 创建 View Tab
///
/// - Parameters:
///   - viewId: 视图标识符（用于 Session 恢复）
///   - title: Tab 标题
///   - placement: 放置方式，默认分栏
///   - view: SwiftUI 视图提供者
/// - Returns: 创建的 Tab，失败返回 nil
func createViewTab(
    viewId: String,
    title: String,
    placement: ViewTabPlacement = .split(.horizontal),
    view: @escaping () -> AnyView
) -> Tab?
```

### 9.3 实现状态

| 放置方式 | 实现状态 | 说明 |
|---------|---------|------|
| `.split()` | ✅ 已完成 | 默认方案，分栏创建新 Panel |
| `.tab` | ⏳ Fallback | 暂时 fallback 到 split |
| `.page` | ✅ 已完成 | 创建独立 Page |

### 9.4 核心能力

- **打开或切换**：重复调用 `createViewTab` 会切换到已有的同 viewId Tab，不会重复创建
- **视图注册**：`ViewTabRegistry` 管理 viewId → viewProvider 映射
- **渲染切换**：`DomainPanelView` 自动根据 Tab 类型显示终端或 SwiftUI 视图

### 9.5 使用示例

```swift
// 插件代码示例
final class MyPlugin: Plugin {
    static let id = "my-plugin"
    static let name = "我的插件"

    func activate(context: PluginContext) {
        // 注册侧边栏入口
        context.ui.registerSidebarTab(
            for: Self.id,
            pluginName: Self.name,
            tab: SidebarTab(
                id: "\(Self.id)-entry",
                title: Self.name,
                icon: "star.fill",
                viewProvider: { AnyView(EmptyView()) },
                onSelect: {
                    // 点击时创建或切换到 View Tab
                    context.ui.createViewTab(
                        for: Self.id,
                        viewId: Self.id,
                        title: Self.name,
                        placement: .split(.horizontal)
                    ) {
                        AnyView(MyPluginView())
                    }
                }
            )
        )
    }
}
```

### 9.6 已删除的旧 API

| 旧 API | 替代方案 |
|-------|---------|
| `registerPage` | `createViewTab(..., placement: .page)` |
| `registerPluginPageEntry` | `registerSidebarTab` + `createViewTab` |
| `PluginPageRegistry` | `ViewTabRegistry` |

## 10. 不在本次范围

- Tab 拖拽到其他 Panel 时的内容类型校验
- View Tab 的状态持久化（需要插件配合）
- `.tab` placement 的真正实现（当前 fallback 到 split）
