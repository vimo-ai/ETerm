# TerminalWindowCoordinator 重构规划

> 目标：修复 DDD 架构，将业务逻辑从 Infrastructure 层移入 Domain 层

## 一、现状分析

### 1.1 问题概述

| 指标 | 当前值 | 目标值 |
|------|-------|-------|
| Coordinator 代码行数 | 2483 行 | ~500 行 |
| Coordinator 方法数 | 103 个 | ~30 个 |
| 终端激活逻辑调用点 | 8 处分散 | 1 处统一入口 |
| 业务规则位置 | Infrastructure 层 | Domain 层 |

### 1.2 架构问题

```
当前架构（错误）：
┌─────────────────────────────────────────┐
│  Presentation (View)                     │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│  Infrastructure (Coordinator) ← 2483行！ │
│  - 业务逻辑 ❌                           │
│  - 状态管理 ❌                           │
│  - 终端激活规则 ❌                       │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│  Domain (TerminalWindow) ← 贫血模型      │
│  - 只有数据，没有行为 ❌                 │
└─────────────────────────────────────────┘
```

---

## 二、方法分类（103个方法）

### 2.1 归属层统计

| 归属层 | 方法数量 | 说明 |
|--------|---------|------|
| Domain（应移入聚合根） | ~25 | 业务规则、状态转换 |
| Application（协调层） | ~35 | 编排调用、事件分发 |
| Infrastructure（基础设施） | ~25 | FFI 调用、渲染、I/O |
| Presentation（应移入 View） | ~18 | UI 状态、坐标计算 |

### 2.2 Domain 层方法（应移入 TerminalWindow）

#### Tab 相关
| 方法 | 业务规则 | 副作用 |
|------|---------|--------|
| `handleTabClick(panelId:tabId:)` | 1. 旧Tab终端→Background 2. 新Tab终端→Active | 渲染、通知 |
| `handleTabClose(panelId:tabId:)` | 最后一个Tab+最后一个Panel时不允许关闭 | 渲染、保存Session |
| `handleTabCloseOthers(panelId:keepTabId:)` | 保留指定Tab，关闭其他 | 渲染 |
| `handleTabCloseLeft(panelId:fromTabId:)` | 关闭左侧所有Tab | 渲染 |
| `handleTabCloseRight(panelId:fromTabId:)` | 关闭右侧所有Tab | 渲染 |
| `removeTab(_:from:closeTerminal:)` | 关闭后激活下一个Tab的终端 | 渲染、保存Session |

#### Panel 相关
| 方法 | 业务规则 | 副作用 |
|------|---------|--------|
| `handleSmartClose()` | Tab→Panel→Page→Window 层级关闭 | 渲染、保存Session |
| `handleClosePanel(panelId:)` | 关闭后激活第一个Panel的终端 | 渲染、保存Session |
| `handleSplitPanel(panelId:direction:)` | CWD 继承给新Panel | 渲染、保存Session |
| `setActivePanel(_:)` | 同步到 TerminalWindow | UI 更新 |

#### Page 相关
| 方法 | 业务规则 | 副作用 |
|------|---------|--------|
| `createPage(title:)` | 1. CWD继承 2. 自动切换到新Page | 渲染、保存Session |
| `switchToPage(_:)` | 1. 旧Page所有终端→Background 2. 新Page激活终端→Active 3. 延迟创建终端 | 渲染 |
| `closePage(_:)` | 切换到另一Page，激活其终端 | 渲染、保存Session |
| `removePage(_:closeTerminals:)` | 跨窗口移动，激活剩余Page终端 | 渲染 |

### 2.3 Domain 层（补充 - Page/Panel 导航与拖拽）

| 方法 | 业务规则 | 副作用 |
|------|---------|--------|
| `closeCurrentPage()` | 调用 closePage | 渲染、保存Session |
| `handlePageCloseOthers(keepPageId:)` | 保留指定 Page，关闭其他 | 渲染 |
| `handlePageCloseLeft(fromPageId:)` | 关闭左侧所有 Page | 渲染 |
| `handlePageCloseRight(fromPageId:)` | 关闭右侧所有 Page | 渲染 |
| `renamePage(_:to:)` | 修改 Page 标题 | 保存Session |
| `reorderPages(_:)` | Page 排序 | 保存Session |
| `switchToNextPage()` | 切换到下一个 Page | 渲染 |
| `switchToPreviousPage()` | 切换到上一个 Page | 渲染 |
| `addPage(_:insertBefore:tabCwds:detachedTerminals:)` | 跨窗口接收 Page | 渲染、保存Session |
| `handlePageReorder(draggedPageId:targetPageId:)` | 拖拽排序 Page | 保存Session |
| `handlePageMoveToEnd(pageId:)` | 移动到末尾 | 保存Session |
| `handlePageReceivedFromOtherWindow(...)` | 跨窗口接收 | 渲染 |
| `handlePageDragOutOfWindow(_:at:)` | 拖出窗口创建新窗口 | 渲染 |
| `addTab(_:to:)` | 跨 Panel 移动 Tab | 渲染 |
| `navigatePanelUp/Down/Left/Right()` | 键盘导航 Panel | 渲染 |
| `navigatePanel(direction:)` | 导航核心逻辑 | 渲染 |

### 2.4 Application 层方法（保留在 Coordinator）

#### 生命周期（5个）
- `init(initialWindow:workingDirectoryRegistry:terminalPool:)`
- `cleanup()`
- `setTerminalPool(_:)`
- `setPendingDetachedTerminals(_:)`
- `attachPendingDetachedTerminals()` ← private

#### 事件分发（5个）
- `handleTerminalClosed(terminalId:)`
- `handleBell(terminalId:)`
- `handleTitleChange(terminalId:title:)`
- `handleExecuteDropIntent(_:)` ← @objc
- `setupDropIntentHandler()` ← private

#### UI 触发编排（10个）
- `handleAddTab(panelId:)`
- `handleTabRename(panelId:tabId:newTitle:)`
- `handleTabReorder(panelId:tabIds:)`
- `handleDrop(tabId:sourcePanelId:dropZone:targetPanelId:)`
- `createNewTab(in:)`
- `createNewTabWithCommand(in:command:cwd:env:)`
- `executeTabReorder(panelId:tabIds:)` ← private
- `executeMoveTabToPanel(tabId:sourcePanelId:targetPanelId:)` ← private
- `executeSplitWithNewPanel(tabId:sourcePanelId:targetPanelId:edge:)` ← private
- `executeMovePanelInLayout(panelId:targetPanelId:edge:)` ← private

#### 搜索功能（5个）
- `startSearch(pattern:isRegex:caseSensitive:)`
- `searchNext()`
- `searchPrev()`
- `clearSearch()`
- `toggleTerminalSearch()`

### 2.5 Infrastructure 层方法

#### 终端 FFI（12个）
- `createTerminalInternal(cols:rows:shell:cwd:)` ← private
- `createTerminalForTab(_:cols:rows:cwd:)` ← private
- `closeTerminalInternal(_:)` ← private
- `writeInputInternal(terminalId:data:)` ← private
- `scrollInternal(terminalId:deltaLines:)` ← private
- `clearSelectionInternal(terminalId:)` ← private
- `getCursorPositionInternal(terminalId:)` ← private
- `createTerminalsForAllTabs()` ← private
- `ensureTerminalsForPage(_:)` ← private
- `ensureTerminalsForActivePage()` ← private
- `detachTerminal(_:)` → DetachedTerminalHandle?
- `attachTerminalsForPage(_:detachedTerminals:)` ← private
- `recreateTerminalsForPage(_:tabCwds:)` ← private

#### 渲染（3个）
- `syncLayoutToRust()`
- `scheduleRender()`
- `renderAllPanels(containerBounds:)`

#### 坐标与布局（4个）
- `setCoordinateMapper(_:)`
- `updateCoordinateMapper(scale:containerBounds:)`
- `updateDividerRatio(layoutPath:newRatio:)`
- `getRatioAtPath(_:)` / `getRatioAtPath(_:in:)` ← private

#### 选区操作（4个）
- `setSelection(terminalId:selection:)`
- `clearSelection(terminalId:)`
- `getSelectionText(terminalId:)`
- `restoreClaudeSession(terminalId:sessionId:)` ← private

#### 查询方法（10个）
- `getCwd(terminalId:)`
- `getWorkingDirectory(tabId:terminalId:)`
- `getTerminalPool()`
- `getActiveTerminalId()`
- `getActiveTabCwd()`
- `hasActiveTerminalRunningProcess()`
- `isActiveTerminalBracketedPasteEnabled()`
- `isKittyKeyboardEnabled(terminalId:)`
- `getActiveTerminalForegroundProcessName()`
- `collectRunningProcesses()`
- `getInputRow(terminalId:)`
- `getCursorPosition(terminalId:)`

### 2.6 Presentation 层方法（应移入 View）

#### UI 状态属性（6个）
- `@Published showInlineComposer: Bool`
- `@Published composerPosition: CGPoint`
- `@Published composerInputHeight: CGFloat`
- `@Published showTerminalSearch: Bool`
- `@Published searchPanelId: UUID?`
- `var currentTabSearchInfo: TabSearchInfo?` ← computed

#### 字体操作（2个）
- `changeFontSize(operation:)`
- `updateFontMetrics(_:)`

#### 坐标计算（3个）
- `findPanel(at:containerBounds:)`
- `getTerminalIdAtPoint(_:containerBounds:)`
- `handleScroll(terminalId:deltaLines:)`

#### 输入路由（1个）
- `writeInput(terminalId:data:)`

### 2.7 方法归属汇总

| 层次 | 方法数量 | 具体内容 |
|------|---------|---------|
| **Domain** | 29 | Tab/Panel/Page 操作、导航、拖拽 |
| **Application** | 25 | 生命周期、事件分发、UI编排、搜索 |
| **Infrastructure** | 33 | FFI、渲染、坐标、选区、查询 |
| **Presentation** | 12 | UI状态、字体、坐标计算、输入 |
| **合计** | **99** | 另有 4 个协议方法 |

### 2.8 操作分类策略（重构核心）

**不是所有操作都走 Command，按特点分类处理：**

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 核心操作（~15个）→ Command 管道                           │
│    switchTab, closeTabs, splitPanel, switchPage, closePage  │
│    createPage, smartClose, navigate, reorderTabs/Pages      │
│    特点：需要 激活终端 + 渲染 + 保存 的后处理                 │
├─────────────────────────────────────────────────────────────┤
│ 2. 终端 I/O（~8个）→ TerminalIO 协议                         │
│    writeInput, scroll, setSelection, clearSelection         │
│    getSelectionText, getCursorPosition, getInputRow         │
│    特点：直接操作 FFI，需要路由到正确的 terminalId           │
├─────────────────────────────────────────────────────────────┤
│ 3. 查询操作（~15个）→ 聚合根暴露                             │
│    activeTerminalId, activeTabCwd, hasRunningProcess        │
│    isKittyKeyboardEnabled, collectRunningProcesses          │
│    特点：只读，不改变状态                                    │
├─────────────────────────────────────────────────────────────┤
│ 4. UI 状态（~10个）→ View 层                                 │
│    showSearch, showComposer, composerPosition               │
│    searchPanelId, changeFontSize, updateMetrics             │
│    特点：纯 UI，不涉及领域逻辑                               │
├─────────────────────────────────────────────────────────────┤
│ 5. FFI 封装（~30个）→ 隐藏到 PoolWrapper                     │
│    createTerminalInternal, closeTerminalInternal            │
│    writeInputInternal, scrollInternal, ensureTerminals...   │
│    特点：底层实现，外部不应该直接调用                        │
├─────────────────────────────────────────────────────────────┤
│ 6. 生命周期/事件（~10个）→ 保留在 Coordinator                │
│    init, cleanup, setTerminalPool, handleBell               │
│    handleTitleChange, handleTerminalClosed                  │
│    特点：协调器核心职责                                      │
└─────────────────────────────────────────────────────────────┘
```

**方法数变化：**

| 分类 | 当前 | 重构后 | 去向 |
|------|-----|--------|------|
| Command 核心操作 | 24 | 1 (perform) | Command 管道 |
| 终端 I/O | 8 | 8 | TerminalIO 协议（保留） |
| 查询 | 15 | 0 | 移入聚合根 |
| UI 状态 | 10 | 0 | 移入 View |
| FFI 封装 | 30 | 0 | 隐藏到 PoolWrapper |
| 生命周期/事件 | 10 | 10 | 保留 |
| **Coordinator 合计** | **99** | **~20** | - |

---

## 三、核心业务规则

### 3.1 终端激活规则（最重要）

**规则描述**：
- 同一时刻只有一个终端处于 Active 模式
- Active 终端会触发渲染，Background 终端不触发
- 切换时：旧终端 → Background，新终端 → Active
- 关闭后：自动激活下一个终端

**当前调用点（8处分散）**：

```swift
// 1. handleTabClick (line ~886)
terminalPool.setMode(terminalId: Int(oldId), mode: .background)
terminalPool.setMode(terminalId: Int(newId), mode: .active)

// 2. handleSmartClose 关闭 Panel 后 (line ~1079)
terminalPool.setMode(terminalId: Int(terminalId), mode: .active)

// 3. handleClosePanel (line ~1144)
terminalPool.setMode(terminalId: Int(terminalId), mode: .active)

// 4. switchToPage - 旧终端 (line ~1702)
terminalPool.setMode(terminalId: Int(oldId), mode: .background)

// 5. switchToPage - 新终端 (line ~1708)
terminalPool.setMode(terminalId: Int(terminalId), mode: .active)

// 6. closePage (line ~1770)
terminalPool.setMode(terminalId: Int(terminalId), mode: .active)

// 7. removePage (line ~1956)
terminalPool.setMode(terminalId: Int(terminalId), mode: .active)

// 8. removeTab (line ~2116)
terminalPool.setMode(terminalId: Int(terminalId), mode: .active)
```

### 3.2 关闭层级规则

```
handleSmartClose() 决策树：

Panel.tabCount > 1?
    ├── Yes → 关闭当前 Tab
    └── No → Page.panelCount > 1?
                ├── Yes → 关闭当前 Panel
                └── No → Window.pageCount > 1?
                            ├── Yes → 关闭当前 Page
                            └── No → 返回 .shouldCloseWindow
```

### 3.3 CWD 继承规则

| 场景 | 继承来源 |
|------|---------|
| 新建 Tab | 同 Panel 激活 Tab 的 CWD |
| 分割 Panel | 源 Panel 激活 Tab 的 CWD |
| 新建 Page | 当前激活终端的 CWD |
| 跨窗口移动 | 保留原终端的 CWD |

### 3.4 延迟加载规则

```swift
// 只在切换到 Page 时才创建终端
func switchToPage(_ pageId: UUID) {
    // ...
    ensureTerminalsForPage(activePage)  // 延迟创建
    // ...
}
```

---

## 四、特性测试用例设计

### 4.1 终端激活测试

```swift
class TerminalActivationTests: XCTestCase {

    // 测试：Tab 切换时的终端模式
    func test_tabSwitch_setsCorrectModes() {
        // Given: Panel 有 Tab A (active) 和 Tab B
        // When: 点击 Tab B
        // Then: Tab A 终端 → Background, Tab B 终端 → Active
    }

    // 测试：关闭 Tab 后激活下一个
    func test_closeTab_activatesNext() {
        // Given: Panel 有 Tab A, B, C，A 激活
        // When: 关闭 Tab A
        // Then: Tab B 终端 → Active
    }

    // 测试：关闭 Page 后激活另一个 Page 的终端
    func test_closePage_activatesOtherPageTerminal() {
        // Given: Page A (active), Page B (background)
        // When: 关闭 Page A
        // Then: Page B 的激活 Tab 终端 → Active
    }

    // 测试：Page 切换时的批量模式变更
    func test_pageSwitchChangesAllTerminalModes() {
        // Given: Page A 有 3 个终端 (active), Page B 有 2 个终端 (background)
        // When: 切换到 Page B
        // Then: Page A 3个终端 → Background, Page B 激活终端 → Active
    }
}
```

### 4.2 关闭层级测试

```swift
class SmartCloseTests: XCTestCase {

    func test_smartClose_closesTab_whenMultipleTabs() {
        // Given: Panel 有多个 Tab
        // When: handleSmartClose()
        // Then: 只关闭当前 Tab，返回 .closedTab
    }

    func test_smartClose_closesPanel_whenSingleTabMultiplePanels() {
        // Given: Panel 只有 1 个 Tab，Page 有多个 Panel
        // When: handleSmartClose()
        // Then: 关闭当前 Panel，返回 .closedPanel
    }

    func test_smartClose_closesPage_whenSinglePanelMultiplePages() {
        // Given: 1 Tab, 1 Panel, 多个 Page
        // When: handleSmartClose()
        // Then: 关闭当前 Page，返回 .closedPage
    }

    func test_smartClose_returnsCloseWindow_whenLastOne() {
        // Given: 1 Tab, 1 Panel, 1 Page
        // When: handleSmartClose()
        // Then: 返回 .shouldCloseWindow
    }
}
```

### 4.3 CWD 继承测试

```swift
class CwdInheritanceTests: XCTestCase {

    func test_newTab_inheritsCwdFromActiveTab() {
        // Given: 激活 Tab 的 CWD 是 /foo/bar
        // When: 创建新 Tab
        // Then: 新 Tab 的 CWD 是 /foo/bar
    }

    func test_splitPanel_inheritsCwd() {
        // Given: Panel 激活 Tab 的 CWD 是 /project
        // When: 分割 Panel
        // Then: 新 Panel 的 Tab CWD 是 /project
    }

    func test_newPage_inheritsCwdFromActiveTerminal() {
        // Given: 当前激活终端 CWD 是 /workspace
        // When: 创建新 Page
        // Then: 新 Page 的初始 Tab CWD 是 /workspace
    }
}
```

---

## 五、新架构设计

### 5.1 核心问题

当前 24 个 `handle*` 方法都在重复同一个模式：

```swift
// 重复模式（每个 handle* 都这样写）
func handleXxx(...) {
    // 1. 调用聚合根
    terminalWindow.doSomething()
    // 2. 设置终端模式（8 处散落）
    terminalPool.setMode(...)
    // 3. 触发渲染
    scheduleRender()
    // 4. 保存 Session
    WindowManager.shared.saveSession()
}
```

### 5.2 解决方案：Command 管道

```
┌─────────────────────────────────────────────────────────────┐
│  View                                                        │
│      │                                                       │
│      ▼ perform(.switchTab(panel: id, tab: id))              │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  Coordinator (单一入口)                                       │
│                                                              │
│  func perform(_ command: WindowCommand) {                    │
│      let result = terminalWindow.execute(command)  // 领域   │
│      activationService.apply(result.activation)    // 激活   │
│      applyEffects(result.effects)                  // 副作用 │
│  }                                                           │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  TerminalWindow.execute() → CommandResult                    │
│      - 纯业务逻辑                                            │
│      - 返回：变更结果 + 需要激活的终端 + 副作用声明           │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 Command 定义

```swift
/// 窗口命令（按操作对象分层）
enum WindowCommand {
    case tab(TabCommand)
    case panel(PanelCommand)
    case page(PageCommand)
    case window(WindowOnlyCommand)
}

// MARK: - Tab 操作

enum TabCommand {
    /// 切换 Tab
    case `switch`(panelId: UUID, tabId: UUID)
    /// 添加新 Tab
    case add(panelId: UUID)
    /// 关闭 Tab（单个或批量）
    case close(panelId: UUID, filter: TabFilter)
    /// 重排 Tab
    case reorder(panelId: UUID, order: [UUID])
    /// 移动 Tab 到另一个 Panel
    case move(tabId: UUID, from: UUID, to: UUID)
}

/// Tab 过滤器（合并 closeLeft/Right/Others/Single）
enum TabFilter {
    case single(UUID)
    case others(keep: UUID)
    case left(of: UUID)
    case right(of: UUID)
}

// MARK: - Panel 操作

enum PanelCommand {
    /// 分割 Panel
    case split(panelId: UUID, direction: SplitDirection)
    /// 关闭 Panel
    case close(panelId: UUID)
    /// 键盘导航 Panel
    case navigate(direction: NavigationDirection)
}

// MARK: - Page 操作

enum PageCommand {
    /// 切换 Page
    case `switch`(pageId: UUID)
    /// 创建 Page
    case create(title: String?)
    /// 关闭 Page（单个或批量）
    case close(filter: PageFilter)
    /// 重排 Page
    case reorder(order: [UUID])
}

/// Page 过滤器
enum PageFilter {
    case single(UUID)
    case others(keep: UUID)
    case left(of: UUID)
    case right(of: UUID)
}

// MARK: - Window 操作

enum WindowOnlyCommand {
    /// 智能关闭（Tab → Panel → Page → Window 层层递进）
    case smartClose
}
```

### 5.4 CommandResult 定义

```swift
/// 命令执行结果
struct CommandResult {
    /// 是否成功
    var success: Bool = true

    /// 失败原因（用于 UI 提示）
    var error: CommandError? = nil

    // MARK: - 终端激活

    /// 需要激活的终端
    var terminalToActivate: Int?

    /// 需要停用的终端列表
    var terminalsToDeactivate: [Int] = []

    // MARK: - 终端生命周期

    /// 需要创建的终端（用于 addTab, splitPanel 等）
    var terminalsToCreate: [TerminalSpec] = []

    /// 需要关闭的终端
    var terminalsToClose: [Int] = []

    // MARK: - 副作用

    /// 副作用声明
    var effects: Effects = Effects()
}

/// 终端创建规格
struct TerminalSpec {
    let tabId: UUID
    let cwd: String?
    let command: String?
    let env: [String: String]?
}

/// 命令错误
enum CommandError {
    case cannotCloseLastTab
    case cannotCloseLastPanel
    case cannotCloseLastPage
    case tabNotFound
    case panelNotFound
    case pageNotFound
}

/// 副作用声明
struct Effects {
    var syncLayout: Bool = false
    var render: Bool = false
    var saveSession: Bool = false
    var updateTrigger: Bool = false
}
```

### 5.5 目标架构

```
┌─────────────────────────────────────────────────────────────┐
│  Presentation (View)                                         │
│  ├── UI 状态 (showSearch, composerPosition) ← 从 Coordinator 移入│
│  ├── 坐标计算                                                │
│  ├── coordinator.perform(.switchTab(...))   // Command 操作  │
│  ├── coordinator.writeInput(...)            // TerminalIO    │
│  └── coordinator.terminalWindow.activeTerminalId // 查询     │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│  Application (Coordinator) ← ~300行, ~20方法                 │
│  ├── perform(_:)           // Command 单一入口 (1)           │
│  ├── TerminalIO 实现        // 终端 I/O 转发 (8)             │
│  ├── 生命周期管理            // init, cleanup, setPool (5)   │
│  └── 事件处理               // handleBell, handleTitle (5)  │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│  Domain                                                      │
│  ├── Aggregates/                                             │
│  │   └── TerminalWindow                                      │
│  │       ├── execute(_:) → CommandResult  // 业务规则        │
│  │       ├── activeTerminalId             // 查询属性        │
│  │       └── collectRunningProcesses()    // 查询方法        │
│  ├── Services/                                               │
│  │   └── TerminalActivationService                           │
│  │       ├── activate(terminalId:)                           │
│  │       └── deactivateAll(terminalIds:)                     │
│  └── Commands/                                               │
│      ├── WindowCommand.swift  // ~15 个核心操作              │
│      └── CommandResult.swift  // 返回激活信息+副作用         │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│  Infrastructure                                              │
│  ├── FFI/ (TerminalPoolWrapper)  // 隐藏所有 *Internal 方法  │
│  ├── Rendering/ (RenderScheduler)                            │
│  └── Persistence/ (SessionManager)                           │
└─────────────────────────────────────────────────────────────┘
```

**数据流：**

```
核心操作：View → perform(command) → TerminalWindow.execute() → CommandResult
                                  → ActivationService.activate()
                                  → applyEffects()

终端 I/O：View → writeInput() → TerminalPool.writeInput() (直通)

查询：    View → terminalWindow.activeTerminalId (直接访问聚合根)
```

### 5.6 新增文件

```
ETerm/ETerm/Core/Terminal/
├── Domain/
│   ├── Commands/
│   │   ├── WindowCommand.swift         ← 新增
│   │   └── CommandResult.swift         ← 新增
│   └── Services/
│       └── TerminalActivationService.swift  ← 新增
└── Application/
    └── TerminalWindowCoordinator.swift      ← 重构（~300行）
```

### 5.7 重构后的 Coordinator（核心代码）

```swift
class TerminalWindowCoordinator {

    // MARK: - 单一入口

    /// 执行命令（所有 UI 操作都走这里）
    func perform(_ command: WindowCommand) {
        // 1. 领域层执行命令
        let result = terminalWindow.execute(command)

        // 2. 处理错误
        guard result.success else {
            if let error = result.error {
                handleCommandError(error)
            }
            return
        }

        // 3. 终端生命周期管理
        for id in result.terminalsToClose {
            terminalPool.closeTerminal(terminalId: id)
            activationService.clearActiveIfMatch(terminalId: id)
        }
        for spec in result.terminalsToCreate {
            let terminalId = terminalPool.createTerminal(
                cols: 80, rows: 24,
                cwd: spec.cwd,
                command: spec.command,
                env: spec.env
            )
            if let tab = terminalWindow.getTab(spec.tabId) {
                tab.setRustTerminalId(terminalId)
            }
        }

        // 4. 激活服务处理终端模式
        for id in result.terminalsToDeactivate {
            activationService.deactivate(terminalId: id)
        }
        if let id = result.terminalToActivate {
            activationService.activate(terminalId: id)
        }

        // 5. 统一副作用处理
        applyEffects(result.effects)
    }

    // MARK: - 错误处理

    private func handleCommandError(_ error: CommandError) {
        switch error {
        case .cannotCloseLastTab, .cannotCloseLastPanel, .cannotCloseLastPage:
            // UI 可以选择显示提示或忽略
            break
        case .tabNotFound, .panelNotFound, .pageNotFound:
            // 记录日志
            print("[Coordinator] Command error: \(error)")
        }
    }

    // MARK: - 副作用处理

    private func applyEffects(_ effects: Effects) {
        if effects.syncLayout {
            syncLayoutToRust()
        }
        if effects.updateTrigger {
            objectWillChange.send()
            updateTrigger = UUID()
        }
        if effects.render {
            scheduleRender()
        }
        if effects.saveSession {
            WindowManager.shared.saveSession()
        }
    }
}
```

### 5.8 TerminalWindow.execute() 实现

```swift
// TerminalWindow.swift

func execute(_ command: WindowCommand) -> CommandResult {
    switch command {
    case .switchTab(let panelId, let tabId):
        return executeSwitch Tab(panelId: panelId, tabId: tabId)

    case .closeTabs(let panelId, let filter):
        return executeCloseTabs(panelId: panelId, filter: filter)

    case .smartClose:
        return executeSmartClose()

    // ... 其他命令
    }
}

private func executeSwitchTab(panelId: UUID, tabId: UUID) -> CommandResult {
    guard let panel = getPanel(panelId) else {
        return CommandResult(success: false)
    }

    let oldTerminalId = panel.activeTab?.rustTerminalId
    guard panel.setActiveTab(tabId) else {
        return CommandResult(success: false)
    }
    let newTerminalId = panel.activeTab?.rustTerminalId

    return CommandResult(
        terminalToActivate: newTerminalId,
        terminalsToDeactivate: oldTerminalId.map { [$0] } ?? [],
        effects: Effects(render: true)
    )
}

private func executeCloseTabs(panelId: UUID, filter: TabFilter) -> CommandResult {
    // 统一处理 closeOthers/closeLeft/closeRight
    guard let panel = getPanel(panelId) else {
        return CommandResult(success: false)
    }

    let tabsToClose: [Tab] = switch filter {
    case .others(let keep):
        panel.tabs.filter { $0.tabId != keep }
    case .left(let ref):
        // 获取 ref 左边的所有 tab
        panel.tabs.prefix(while: { $0.tabId != ref }).map { $0 }
    case .right(let ref):
        // 获取 ref 右边的所有 tab
        panel.tabs.drop(while: { $0.tabId != ref }).dropFirst().map { $0 }
    case .single(let id):
        panel.tabs.filter { $0.tabId == id }
    }

    // 关闭并收集需要停用的终端
    var terminalsToDeactivate: [Int] = []
    for tab in tabsToClose {
        if let id = tab.rustTerminalId {
            terminalsToDeactivate.append(id)
        }
        panel.removeTab(tab.tabId)
    }

    return CommandResult(
        terminalToActivate: panel.activeTab?.rustTerminalId,
        terminalsToDeactivate: terminalsToDeactivate,
        effects: Effects(render: true, saveSession: true)
    )
}
```

### 5.9 TerminalIO 协议（终端 I/O 操作）

**这些操作不走 Command，保留在 Coordinator 作为薄代理：**

```swift
/// 终端 I/O 协议
protocol TerminalIO {
    /// 写入输入
    func writeInput(terminalId: Int, data: String)

    /// 滚动
    func scroll(terminalId: Int, deltaLines: Int32)

    /// 设置选区
    func setSelection(terminalId: Int, selection: TextSelection) -> Bool

    /// 清除选区
    func clearSelection(terminalId: Int) -> Bool

    /// 获取选区文本
    func getSelectionText(terminalId: Int) -> String?

    /// 获取光标位置
    func getCursorPosition(terminalId: Int) -> CursorPosition?

    /// 获取输入行
    func getInputRow(terminalId: Int) -> UInt16?
}

// Coordinator 实现（纯转发，无业务逻辑）
extension TerminalWindowCoordinator: TerminalIO {
    func writeInput(terminalId: Int, data: String) {
        terminalPool.writeInput(terminalId: terminalId, data: data)
    }

    func scroll(terminalId: Int, deltaLines: Int32) {
        terminalPool.scroll(terminalId: terminalId, deltaLines: deltaLines)
    }

    // ... 其他方法同样简单转发
}
```

**特点**：
- 无业务逻辑，纯转发
- 提供类型安全的接口
- View 通过 `coordinator.writeInput()` 调用

### 5.10 查询操作移入聚合根

**这些操作从 Coordinator 移入 TerminalWindow：**

```swift
// TerminalWindow.swift 新增查询属性/方法

extension TerminalWindow {

    // MARK: - 查询属性

    /// 当前激活的终端 ID
    var activeTerminalId: Int? {
        guard let page = activePage,
              let panel = page.activePanel,
              let tab = panel.activeTab else { return nil }
        return tab.rustTerminalId
    }

    /// 当前激活的 Panel ID
    var activePanelId: UUID? {
        activePage?.activePanelId
    }

    // MARK: - 查询方法（需要外部依赖）

    /// 获取终端 CWD（需要 registry）
    func getCwd(terminalId: Int, registry: TerminalWorkingDirectoryRegistry) -> String? {
        // 通过 registry 查询
        return registry.queryWorkingDirectory(tabId: nil, terminalId: terminalId).path
    }

    /// 收集所有运行中的进程
    func collectRunningProcesses(pool: TerminalPoolProtocol) -> [(tabTitle: String, processName: String)] {
        var result: [(String, String)] = []
        for page in pages {
            for panel in page.allPanels {
                for tab in panel.tabs {
                    if let id = tab.rustTerminalId,
                       let name = pool.getForegroundProcessName(terminalId: id) {
                        result.append((tab.title, name))
                    }
                }
            }
        }
        return result
    }
}
```

**View 访问方式变化：**

```swift
// 重构前
let terminalId = coordinator.getActiveTerminalId()

// 重构后
let terminalId = coordinator.terminalWindow.activeTerminalId
```

### 5.11 UI 状态移入 View

**这些状态从 Coordinator 移入 View：**

```swift
// 从 Coordinator 删除
class TerminalWindowCoordinator {
    // ❌ 删除
    // @Published var showInlineComposer: Bool = false
    // @Published var composerPosition: CGPoint = .zero
    // @Published var showTerminalSearch: Bool = false
    // @Published var searchPanelId: UUID?
}

// 移入 View
struct TerminalContentView: View {
    // ✅ UI 状态由 View 管理
    @State private var showSearch = false
    @State private var searchPanelId: UUID?
    @State private var showComposer = false
    @State private var composerPosition: CGPoint = .zero

    var body: some View {
        // ...
    }
}
```

### 5.12 迁移前后对比

| 指标 | 迁移前 | 迁移后 |
|------|-------|--------|
| Coordinator 方法数 | 99 | ~20 |
| Coordinator 行数 | 2483 | ~300 |
| handle* 方法 | 24 | 1 (perform) |
| setMode 调用点 | 8 | 1 (ActivationService) |
| closeTabs 变体 | 3 | 1 (filter 参数) |
| closePages 变体 | 3 | 1 (filter 参数) |
| 查询方法 | 15 | 0 (移入聚合根) |
| UI 状态属性 | 6 | 0 (移入 View) |
| TerminalIO 方法 | 8 | 8 (保留，纯转发) |

---

## 六、迁移计划（4 阶段）

### Phase 1：TerminalActivationService + 查询收敛

**目标**：99 → ~70 方法

**步骤**：
1. 创建 `TerminalActivationService.swift`
2. 替换 8 处 `setMode` 调用
3. 将 `getActiveTerminalId`、`hasRunningProcess` 等查询移入 `TerminalWindow`
4. Coordinator 只做转发

**预计改动**：
```
+ Domain/Services/TerminalActivationService.swift (~50 行)
~ TerminalWindow.swift (+30 行查询方法)
~ Coordinator (-30 行)
```

### Phase 2：Command 管道

**目标**：70 → ~35 方法

**步骤**：
1. 创建 `WindowCommand.swift` 和 `CommandResult.swift`
2. 在 `TerminalWindow` 实现 `execute(_:) -> CommandResult`
3. Coordinator 添加 `perform(_:)` 单一入口
4. 逐步将 `handle*` 方法改为调用 `perform()`

**预计改动**：
```
+ Domain/Commands/WindowCommand.swift (~60 行)
+ Domain/Commands/CommandResult.swift (~30 行)
~ TerminalWindow.swift (+200 行 execute 实现)
~ Coordinator (-400 行，24 个 handle* → 1 个 perform)
```

### Phase 3：合并同类方法

**目标**：35 → ~25 方法

**步骤**：
1. `closeLeft/Right/Others` → `closeTabs(filter:)`
2. `closePageLeft/Right/Others` → `closePages(filter:)`
3. `navigateUp/Down/Left/Right` → `navigate(direction:)`

**预计改动**：
```
~ WindowCommand.swift (添加 TabFilter, PageFilter)
~ TerminalWindow.swift (合并实现)
~ Coordinator (-50 行)
```

### Phase 4：UI 状态下沉

**目标**：25 → ~20 方法

**步骤**：
1. `showInlineComposer`、`searchPanelId` 移入 View
2. 坐标计算逻辑移入 View
3. Coordinator 只保留核心编排

**预计改动**：
```
~ Coordinator (-100 行)
~ Views (+100 行)
```

### 进度追踪

| Phase | 目标 | 状态 | 备注 |
|-------|------|------|------|
| 1 | ActivationService + 查询收敛 | ✅ 已完成 | perform() 内统一处理，无需单独 Service |
| 2 | Command 管道 | ✅ 已完成 | 25+ 处 perform() 调用 |
| 3 | 合并同类方法 | ✅ 已完成 | TabFilter/PageFilter/PageScope 已实现 |
| 4 | UI 状态下沉 | ✅ 已完成 | @Published 8→4，Search 方法改为参数传入 |
| - | Extension 拆分 | ✅ 已完成 | 6 个 extension 文件（额外改进） |

### 实际实现说明（2025/12 更新）

**与原计划差异**：

1. **TerminalActivationService 未单独创建**
   - 原因：`perform()` 内已实现统一激活逻辑
   - CommandResult 支持 `terminalsToActivate/Deactivate`
   - 无需额外抽象层

2. **Extension 拆分（原计划外）**
   ```
   TerminalWindowCoordinator.swift      (1036 行，主文件)
   ├── +Drop.swift                      (184 行)
   ├── +Terminal.swift                  (498 行)
   ├── +Input.swift                     (97 行)
   ├── +Layout.swift                    (237 行)
   ├── +Search.swift                    (147 行)
   └── +Selection.swift                 (99 行)
   ```

3. **setMode 调用现状**（5 处）
   - `perform()` 内 2 处 → ✅ 统一入口
   - `createTerminalForSpec` 1 处 → ✅ 创建时必须
   - `ensureTerminalsForPage` 1 处 → ✅ 延迟创建
   - `removePage` 1 处 → ⚠️ 边界情况（跨窗口）
   - `removeTab` → ✅ 已迁移到 Command

**当前状态**：

| 指标 | 初始 | 当前 | 说明 |
|------|------|------|------|
| @Published 属性 | 8 | 4 | UI 状态已下沉 |
| setMode 调用 | 9 | 5 | 2 在 perform()，3 边界情况 |
| perform() 调用 | 0 | 25+ | Command 管道完成 |
| Extension 文件 | 0 | 6 | 职责拆分完成 |

**已完成**：
- ✅ `removeTab` → `perform(.tab(.remove(...)))`
- ✅ `createNewTabWithCommand` → `perform(.tab(.addWithConfig(...)))`

---

## 七、测试策略

### 7.1 重构前

1. **写特性测试锁定行为**
   - 覆盖所有终端激活场景
   - 覆盖关闭层级规则
   - 覆盖 CWD 继承规则

2. **记录当前行为快照**
   - 手动测试并记录关键场景的结果

### 7.2 重构中

1. **每个阶段运行全部测试**
2. **对比验证**（可选）：
   ```swift
   #if DEBUG
   let oldResult = oldLogic()
   let newResult = newLogic()
   assert(oldResult == newResult)
   #endif
   ```

### 7.3 重构后

1. **回归测试**：确保所有特性测试通过
2. **集成测试**：手动验证关键流程
3. **性能测试**：确保没有引入性能回退

---

## 八、风险评估

| 风险 | 级别 | 缓解措施 |
|------|------|---------|
| 行为变更 | 高 | 特性测试 + 对比验证 |
| ActivationService 状态漂移 | 高 | 终端关闭时调用 `clearActiveIfMatch()`，延迟创建时同步状态 |
| 性能回退 | 中 | 避免过度抽象，保持扁平调用 |
| 迁移中断 | 中 | 分阶段迁移，每阶段可独立交付；逐个迁移 handle* |
| 终端创建/销毁遗漏 | 中 | CommandResult 包含 `terminalsToCreate/Close`，Coordinator 统一处理 |
| 代码冲突 | 低 | 在干净分支上进行 |

**特别注意：ActivationService 同步**

```swift
// 终端关闭时，必须通知 ActivationService
func handleTerminalClosed(terminalId: Int) {
    activationService.clearActiveIfMatch(terminalId: terminalId)
    // ...
}

// 延迟创建终端后，必须检查是否需要激活
func ensureTerminalsForPage(_ page: Page) {
    // 创建终端后...
    if page == activePage {
        if let terminalId = page.activePanel?.activeTab?.rustTerminalId {
            activationService.activate(terminalId: terminalId)
        }
    }
}
```

---

## 九、成功标准（架构清晰度）

### 核心原则

**清晰的层次边界**：
- **Domain 层**：纯业务逻辑，不依赖 FFI/UI
- **Infrastructure 层**：FFI 封装、终端池操作
- **Coordinator**：编排层，连接 Domain 和 Infrastructure

### 边界定义

| 操作类型 | 归属层 | 入口 |
|---------|--------|------|
| Tab/Panel/Page 状态变更 | Domain | `perform(.command)` → `TerminalWindow.execute()` |
| 终端激活 (setMode) | Coordinator | `perform()` 内统一处理 |
| 终端创建/销毁 | Infrastructure | `CommandResult.terminalsToCreate/Close` |
| 布局计算 (layoutCalculator) | Infrastructure | 边界情况，保留在 Coordinator |
| FFI 调用 | Infrastructure | +Terminal.swift |

### 完成标准

- [x] 所有 handle* 统一走 `perform()` 入口
- [x] 终端激活通过 `CommandResult` 声明，`perform()` 内统一执行
- [x] UI 状态下沉到 View 层
- [x] Extension 拆分，职责清晰
- [ ] `removeTab` / `createNewTabWithCommand` 走 Command（进行中）

### 允许的边界情况

以下场景保留在 Coordinator，不强求迁移：
1. **layoutCalculator 依赖**：`splitPanelWithExistingTab`, `movePanelInLayout`
2. **跨窗口操作**：`removePage` (forceRemove)
3. **终端延迟创建**：`ensureTerminalsForPage` (FFI 调用)

---

## 十、重构完成总结

### 10.1 已完成的迁移

**removeTab** ✅：
```swift
func removeTab(_ tabId: UUID, from panelId: UUID, closeTerminal: Bool) -> Bool {
    let result = perform(.tab(.remove(tabId: tabId, panelId: panelId, closeTerminal: closeTerminal)))
    return result.success
}
```

**createNewTabWithCommand** ✅：
```swift
let config = TabConfig(cwd: cwd, command: command, commandDelay: commandDelay)
let result = perform(.tab(.addWithConfig(panelId: targetPanelId, config: config)))
```

### 10.2 最终架构

```
┌─────────────────────────────────────────────────────────────┐
│  View Layer                                                  │
│  └── coordinator.perform(.command)                          │
├─────────────────────────────────────────────────────────────┤
│  Coordinator (编排层)                                        │
│  ├── perform() → 统一入口                                    │
│  │   ├── terminalWindow.execute() → Domain 业务逻辑         │
│  │   ├── setMode() → 终端激活（仅 2 处）                     │
│  │   └── applyEffects() → 副作用处理                        │
│  └── Extensions (6 个文件，职责分离)                         │
├─────────────────────────────────────────────────────────────┤
│  Domain Layer                                                │
│  ├── TerminalWindow.execute() → CommandResult               │
│  ├── WindowCommand / TabCommand / PanelCommand / PageCommand│
│  └── 纯业务逻辑，不依赖 FFI                                  │
├─────────────────────────────────────────────────────────────┤
│  Infrastructure Layer                                        │
│  └── +Terminal.swift → FFI 封装                             │
└─────────────────────────────────────────────────────────────┘
```

### 10.3 边界情况（允许保留）

| 场景 | 原因 |
|------|------|
| `splitPanelWithExistingTab` | 需要 layoutCalculator |
| `movePanelInLayout` | 需要 layoutCalculator |
| `removePage` (forceRemove) | 跨窗口特殊操作 |
| `ensureTerminalsForPage` | 终端延迟创建 (FFI) |
