# MemexKit Click Issue Debug Log

## Problem Description
MemexView 作为插件嵌入 ETerm 时，某些 SwiftUI 组件无法接收点击事件。

## Environment
- ETerm 主应用使用 ZStack 层叠结构：
  1. RioTerminalView (底层，Metal-based terminal)
  2. Plugin content (中间层，插件视图)
  3. VStack(PageBar + Spacer) (顶层，覆盖全屏)

## Tested Solutions

### Working (可行方案)

| 方案 | 状态 | 说明 |
|------|------|------|
| 简单 VStack + Button | ✅ 工作 | 最基本的布局，按钮可点击 |
| VStack + HStack + 多个 Button | ✅ 工作 | Header 区域多个按钮都可点击 |
| @StateObject ViewModel + .task | ✅ 工作 | 异步操作不影响点击 |
| 用 Button 替代 Picker | ✅ 工作 | 自定义按钮组替代 segmented picker |

### Not Working (不可行方案)

| 方案 | 状态 | 说明 |
|------|------|------|
| SwiftUI `ScrollView` | ❌ 失败 | ScrollView 内的按钮无法点击 |
| SwiftUI `List` | ❌ 失败 | List 内的按钮无法点击 |
| SwiftUI `Picker(.segmented)` | ❌ 失败 | Picker 无法接收点击 |
| 自定义 `ClickableNSScrollView` | ❌ 失败 | 即使 override `acceptsFirstMouse`，仍无法点击 |
| NSViewRepresentable + NSScrollView + NSHostingView | ❌ 失败 | 嵌套 hosting view 导致事件丢失 |
| StatusCardView (VStack without ScrollView) | ❌ 失败 | 仍然无法点击 |

## Root Cause Analysis (from Codex/GPT)

**核心问题**: ScrollView/List/Picker 都包装了 AppKit 的 `NSScrollView`，依赖正确的 hit-testing 链条。

**可能原因**:
1. PageBar 的 VStack+Spacer 覆盖在插件内容之上，可能拦截了 hit-testing
2. NSView 层级中有某个视图 override `hitTest` 返回 `self` 或 `nil`
3. 嵌套的 NSHostingView 导致 responder chain 断裂
4. Metal view (RioTerminalView) 的 layer 可能干扰事件传递

## Key Insight
- **简单 Button 能工作** 是因为 SwiftUI 可以在 hosting view 层直接处理
- **NSScrollView 系列控件不工作** 是因为它们需要完整的 AppKit hit-testing chain

## Files Involved
- `ETerm/ETerm/Core/Layout/Presentation/ContentView.swift` - ZStack 结构定义
- `ETerm/ETerm/Core/Layout/Presentation/PageBarView.swift` - PageBar 的 hitTest 实现
- `Plugins/MemexKit/Sources/MemexKit/MemexView.swift` - 插件视图

## Constraints
- **不能修改 ETerm 主应用代码** (用户明确要求)
- 只能在 MemexKit 插件内部解决问题

## Next Steps to Try
1. [ ] 完全不使用任何滚动容器，用固定高度的卡片布局
2. [ ] 尝试把整个 MemexView 变成 NSViewRepresentable，从根本上避免 SwiftUI 的 hosting view 嵌套
3. [ ] 检查是否可以通过 `.allowsHitTesting()` 或 `.contentShape()` 强制事件穿透
4. [ ] 考虑使用 gesture recognizer 手动处理滚动，而不是依赖 NSScrollView
5. [ ] 调查 ContentView 中 Spacer 是否真的在拦截事件

## Important Discovery

### 两个插件都用 sidebarView
- MemexKit: `sidebarView(for: "memex")` → `MemexView()`
- HistoryKit: `sidebarView(for: "history-panel")` → `HistoryPanelView()`

**展示方式完全相同！**

### HistoryKit 也使用 ScrollView
文件: `Plugins/HistoryKit/Sources/HistoryKit/Views/HistoryPanelView.swift:294`
```swift
ScrollView {
    // content...
}
```

**需要验证**: HistoryKit 的 ScrollView 能否点击？
- 如果能点击 → 问题在 MemexKit 的特定实现
- 如果不能点击 → 这是 ETerm 的通用 bug（所有 sidebarView 都有问题）

## Questions
1. 为什么简单按钮能工作但加入任何"容器型"控件就失败？
2. HistoryKit 的 ScrollView 是否能正常点击？（关键验证点）
3. 是否需要在 ETerm 层面添加 `.allowsHitTesting(false)` 到 PageBar 的 Spacer？
4. MemexKit 和 HistoryKit 的 pageContent 注册方式有何不同？

---
Last Updated: 2024-12-31
