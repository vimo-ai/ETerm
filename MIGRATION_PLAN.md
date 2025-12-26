# 插件迁移计划

## 背景

将 `ETerm/ETerm/Features/Plugins/` 下的内嵌插件迁移到 `Plugins/` 下的 SDK 插件模式。

## 两套系统对比

| 能力 | 内嵌插件 (PluginContext) | SDK 插件 (HostBridge) |
|------|--------------------------|----------------------|
| 事件订阅 | `context.events.subscribe` | manifest.subscribes + onEvent |
| 事件发射 | `context.events.emit` | `host.emit` |
| 侧边栏 Tab | `context.ui.registerSidebarTab` | manifest.sidebarTabs + sidebarView |
| 命令注册 | `context.commands.register` | manifest.commands + handleCommand |
| 快捷键绑定 | `context.keyboard.bind` | manifest.commands.shortcut |
| Tab 装饰 | `context.ui.setTabDecoration` | `host.setTabDecoration` |
| Tab 标题 | `context.ui.setTabTitle` | `host.setTabTitle` |
| 终端写入 | `context.terminal.write` | `host.writeToTerminal` |
| 信息面板 | `context.ui.registerInfoContent` | manifest.infoPanelContent + host.showInfoPanel |
| PageBar 组件 | `context.ui.registerPageBarItem` | - |
| Page/Tab Slot | `context.ui.registerPageSlot` | manifest.tabSlots/pageSlots + slotView |
| 底部停靠 | - | `host.showBottomDock` |
| 气泡 | - | `host.showBubble` |

## 迁移状态

### 已完成迁移 ✅

| 内嵌插件 | SDK 插件 | 完成日期 |
|----------|----------|----------|
| MCPRouter | MCPRouterKit | 2024-12-26 |
| Workspace | WorkspaceKit | 2024-12-26 |
| OneLineCommand | OneLineCommandKit | 2024-12-26 |
| DevHelper | DevHelperKit | 2024-12-26 |
| ClaudeMonitor | ClaudeMonitorKit | 2024-12-26 |
| Translation + EnglishLearning | TranslationKit | 2024-12-26 |
| WritingAssistant | WritingKit | 2024-12-26 |

### 待迁移 ❌

| 内嵌插件 | 目标 SDK 插件 | 复杂度 | 说明 |
|----------|---------------|--------|------|
| Claude | ClaudeKit | 高 | PageSlot、Socket Server、Session 映射、多状态管理 |
| Vlaude | VlaudeKit | 中 | 依赖 Claude 的 SessionMapper、ClaudeEvents |

### 核心框架（不迁移）🏠

| 插件 | 说明 |
|------|------|
| Framework | 插件框架基础设施 |
| Core | 核心命令 |
| ExtensionHost | SDK 插件加载器 |
| Selection | 选中文本 Action 注册表和 Popover 控制器 |
| ExampleSidebarPlugin | 示例代码 |

### 已废弃 🗑️

| 插件 | 说明 |
|------|------|
| Learning | 视图已融合到 TranslationKit，目录待删除 |

## Claude 迁移分析

Claude 是最复杂的插件，使用了以下深度集成能力：

1. **PageSlot** - 在 Tab 内容区显示 Claude 会话视图
2. **Socket Server** - 与 Claude CLI 通信
3. **Session Mapper** - Tab ID 与 Claude Session 的映射关系
4. **Tab 装饰** - 多状态管理（思考中、响应中、完成等）
5. **事件订阅** - 终端输出、Selection 等事件

### 迁移方案

需要先扩展 SDK 能力：

1. 添加 PageSlot/TabSlot 支持到 HostBridge
2. 添加 Socket Server 能力（或保持内嵌）
3. 迁移 Session 管理逻辑

## Vlaude 迁移分析

Vlaude 依赖 Claude 插件：

1. 使用 `ClaudeSessionMapper` 获取当前会话
2. 监听 `ClaudeEvents` 事件
3. 需要 Tab Slot 显示 UI

### 迁移方案

等 Claude 迁移完成后，Vlaude 可以：
1. 通过事件系统与 ClaudeKit 通信
2. 使用扩展后的 HostBridge 能力

## Slot 实现（已完成）

### 架构

SDK 插件通过 Protocol 轻量访问 Tab/Page 信息，无需迁移完整类型：

```
ETermKit:
├── Domain/
│   ├── TabDecoration.swift      # 装饰系统（从 PluginContext 迁移）
│   └── SlotContext.swift        # TabSlotContext / PageSlotContext 协议
└── Protocols/
    └── Plugin.swift             # tabSlotView / pageSlotView 方法

ETerm:
├── Tab.swift                    # conform TabSlotContext
└── Page.swift                   # conform PageSlotContext
```

### 使用方式

1. **manifest.json** 声明 Slot：
```json
{
  "tabSlots": [{ "id": "status", "position": "trailing" }],
  "pageSlots": [{ "id": "summary", "position": "trailing" }]
}
```

2. **Plugin** 实现视图：
```swift
func tabSlotView(for slotId: String, tab: any TabSlotContext) -> AnyView? {
    guard slotId == "status", let terminalId = tab.terminalId else { return nil }
    return AnyView(StatusIcon(terminalId: terminalId))
}
```

### 注意事项

- 仅 `runMode: main` 支持 Slot（isolated 模式需要 IPC 传递 Context，暂未实现）
- TabSlotContext 提供：id, terminalId, decoration, title, isActive
- PageSlotContext 提供：id, title, isActive, slotTabs, effectiveDecoration

## 下一步

1. [x] 扩展 SDK 支持 TabSlot/PageSlot
2. [ ] 迁移 Claude → ClaudeKit
3. [ ] 迁移 Vlaude → VlaudeKit
4. [ ] 所有插件稳定后，清理废弃的内嵌插件目录

## 未来计划：Tab/Page 完整迁移

当前采用 Protocol 轻量方案，如果未来需要完整迁移 Tab/Page 到 ETermKit：

### 需要迁移的类型

| 类型 | 位置 | 复杂度 |
|------|------|--------|
| TabDecoration | ✅ 已迁移 | - |
| DecorationPriority | ✅ 已迁移 | - |
| Tab | Core/Layout/Domain/Aggregates | 高 |
| Page | Core/Terminal/Domain/Aggregates | 高 |
| EditorPanel | Core/Layout/Domain/Aggregates | 高 |
| TabContent | Core/Layout/Domain/ValueObjects | 中 |
| PageContent | Core/Terminal/Domain/ValueObjects | 中 |

### 迁移风险

1. **依赖链复杂**：Tab 依赖 TabContent、EditorPanel，Page 依赖 PanelLayout、EditorPanel
2. **终端绑定**：TerminalTabContent 持有 Rust 终端引用
3. **内部插件依赖**：Claude、Vlaude 等直接使用 Tab/Page 类型

### 建议

- 维持当前 Protocol 方案，满足 SDK 插件需求
- 仅在必要时（如第三方插件需要完整 Tab/Page 操作）再考虑迁移
- 迁移前需全面重构依赖关系
