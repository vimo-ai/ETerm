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
| PageBar 组件 | `context.ui.registerPageBarItem` | ❌ 不支持 |
| Page/Tab Slot | `context.ui.registerPageSlot` | ❌ 不支持 |
| 底部停靠 | - | `host.showBottomDock` |
| 气泡 | - | `host.showBubble` |

## 插件分析

### 已迁移 ✅
- **MCPRouterKit** - Rust FFI + 设置视图
- **WorkspaceKit** - SwiftData + 事件发射
- **OneLineCommandKit** - 命令执行 + 弹窗

### 不适合迁移（深度集成）🔒
| 插件 | 原因 |
|------|------|
| **Claude** | 使用 PageSlot、Socket Server、Session 映射、Tab 装饰多状态管理，深度集成终端事件 |
| **ClaudeMonitor** | 使用 PageBarItem、MenuBar、多个 Service 单例，深度集成 Claude 事件 |
| **Vlaude** | 依赖 Claude 的 ClaudeSessionMapper、ClaudeEvents，需要 Tab Slot |

### 可考虑迁移 🔄
| 插件 | 文件数 | 复杂度 | 迁移可行性 |
|------|--------|--------|-----------|
| **WritingAssistant** | 1 | 低 | ⚠️ 使用 UIEvent（showComposer），需主程序配合 |
| **DevHelper** | 5 | 中 | ✅ 项目扫描 + 脚本执行，可独立 |
| **EnglishLearning** | 2+5 视图 | 中 | ⚠️ 使用 InfoContent、事件订阅、TranslationController |

### 建议保留内嵌 🏠
| 插件 | 原因 |
|------|------|
| **Framework** | 核心框架 |
| **Core** | 核心命令 |
| **ExtensionHost** | SDK 加载器 |
| **ExampleSidebarPlugin** | 示例代码 |

## 迁移策略

### 策略 A：保守迁移（推荐）
只迁移功能独立、不依赖深度集成能力的插件：

1. **DevHelper** → DevHelperKit
   - 项目扫描器
   - 脚本执行
   - 侧边栏视图

### 策略 B：扩展 SDK 能力后迁移
先扩展 HostBridge 协议支持更多能力，再迁移：

1. 添加 PageSlot/TabSlot 支持
2. 添加 PageBarItem 支持
3. 添加事件订阅回调机制
4. 迁移 Claude 相关插件

### 策略 C：混合模式
部分插件保持内嵌，部分迁移 SDK：
- 核心功能（Claude, ClaudeMonitor）保持内嵌
- 辅助功能（DevHelper, EnglishLearning）迁移 SDK

## 决策点

请确认以下问题：

1. **迁移范围**：
   - [ ] 只迁移 DevHelper
   - [ ] 迁移 DevHelper + EnglishLearning
   - [ ] 扩展 SDK 后迁移更多
   - [ ] 其他：_______

2. **Claude 相关插件**：
   - [ ] 保持内嵌（推荐）
   - [ ] 迁移到 SDK（需扩展能力）

3. **EnglishLearning**：
   - [ ] 保持内嵌（涉及 TranslationController 全局状态）
   - [ ] 迁移到 SDK（需改造翻译流程）

4. **WritingAssistant**：
   - [ ] 保持内嵌（依赖 UIEvent）
   - [ ] 迁移到 SDK（需改造 Composer 触发方式）

## 下一步

确认迁移范围后，使用 `/parallel-migrate` 执行迁移任务。
