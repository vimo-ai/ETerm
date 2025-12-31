# ETerm

> **AI CLI 时代，体验最好的插件友好型终端。**

---

## 愿景

### 为什么需要 ETerm？

**AI CLI 正在改变开发者的工作方式。**

Claude Code、Cursor、Codex CLI 这些工具不再是"偶尔用一下"的助手，而是开发者日常工作的核心界面。它们产生了传统终端从未处理过的新需求：

| 传统 CLI | AI CLI |
|---------|--------|
| 命令执行完即结束 | 会话持久化，可回溯 |
| 输出是文本流 | 输出是结构化对话 |
| 无状态 | 有上下文、有记忆 |
| 单设备使用 | 需要跨设备访问 |
| 手动操作 | 可被远程注入消息 |

**现有终端的困境：**

- **iTerm2 / Kitty** - 功能强大，但为传统 CLI 设计，对 AI 会话无感知
- **Warp** - 有 AI 功能，但封闭、数据上云、不可扩展
- **Terminal.app** - 原生但功能有限

**ETerm 的定位：**

```
ETerm 不是通用终端的替代品。
ETerm 是 AI CLI 工作流的最佳容器。
```

### 设计哲学

#### 1. 插件优先，而非功能堆砌

```
❌ 传统思路：终端内置 AI 功能
✅ ETerm 思路：终端提供 SDK，功能由插件实现
```

任何功能都应该是插件。会话搜索是插件（MemexKit），远程控制是插件（VlaudeKit），AI 补全也是插件。

这意味着：
- 用户可以只安装需要的功能
- 开发者可以创造我们没想到的功能
- 核心保持轻量，扩展无限可能

#### 2. 本地优先，数据主权

```
你的会话数据在你的机器上。
索引在本地，搜索在本地，向量化在本地。
同步是可选的，而且你控制同步到哪里。
```

#### 3. 开放而非封闭

- **完全开放** - 核心能暴露的都暴露，不替用户做决定
- **信任插件** - 用户选择安装即信任，给予最大自由
- **独立分发** - Bundle 插件可热加载，无需重编译主应用

#### 4. 体验优先

"体验最好"不是功能最多，而是：
- **性能** - GPU 渲染，60 FPS，低延迟
- **流畅** - 原生动画，无卡顿
- **直觉** - 开箱即用，符合 macOS 习惯
- **美观** - 精心设计的默认主题（水墨）

### 长期目标

```
短期：macOS 上最好的 Claude Code 伴侣
中期：AI CLI 生态的中心枢纽（多 Agent 协作、会话编排）
长期：定义 AI 原生终端的标准
```

---

📖 [插件 SDK 设计文档](../DESIGN_ETERM_PLUGIN_SDK.md) | [架构文档](./ARCHITECTURE.md)

---

## 项目结构

```
english/
├── ETerm/                          # Swift macOS 应用
│   ├── ETerm/
│   │   ├── Application/            # 应用层（Command、Event、Input）
│   │   ├── Core/                   # 核心功能模块
│   │   │   ├── Keyboard/           # 键盘输入处理、快捷键、IME
│   │   │   ├── Layout/             # 布局视图（Panel、Tab、Divider）
│   │   │   ├── Settings/           # 设置界面
│   │   │   ├── Shared/             # 共享组件和协议
│   │   │   └── Terminal/           # 终端核心（DDD 架构）
│   │   │       ├── Domain/         # 聚合根、值对象、领域服务
│   │   │       ├── Infrastructure/ # FFI、Window、Coordination
│   │   │       └── Presentation/   # 终端视图
│   │   ├── Features/               # 功能模块
│   │   │   ├── AI/                 # AI 服务（翻译、字典）
│   │   │   └── Plugins/            # 插件系统
│   │   └── Resources/              # 资源文件
│   └── ARCHITECTURE.md             # 详细架构文档
│
├── rio/                            # Rio 终端源码
│   ├── sugarloaf-ffi/              # Rust FFI 桥接层
│   │   └── src/
│   │       ├── app/                # 应用层（TerminalPool、RenderScheduler）
│   │       ├── domain/             # 领域层（状态、聚合、事件）
│   │       ├── ffi/                # FFI 导出函数
│   │       ├── render/             # 渲染层（Renderer、布局、字体）
│   │       ├── lib.rs              # 库入口
│   │       └── rio_machine.rs      # Rio 终端状态机
│   ├── sugarloaf/                  # 渲染引擎
│   └── ...                         # 其他 Rio 组件
│
├── scripts/
│   ├── update_sugarloaf_dev.sh     # 🚀 开发快速编译（thin LTO）
│   └── build_sugarloaf_release.sh  # 🏗️ 发布完整优化（full LTO）
│
└── Packages/                       # Swift Package 依赖
    └── PanelLayoutKit/             # Panel 布局计算库
```

## 快速开始

### 1. 编译 Rust FFI

```bash
# 日常开发（推荐）
./scripts/update_sugarloaf_dev.sh

# 正式发布
./scripts/build_sugarloaf_release.sh
```

### 2. Xcode 配置

1. 打开 `ETerm/ETerm.xcodeproj`
2. 确保 Build Settings:
   - Bridging Header: `ETerm/ETerm-Bridging-Header.h`
   - Runpath Search Paths: `@executable_path/../Frameworks`
3. Build Phases:
   - Link: `libsugarloaf_ffi.dylib`
   - Copy Files (Frameworks): `libsugarloaf_ffi.dylib` (Code Sign On Copy)

### 3. 运行

```bash
# 或在 Xcode 中 Cmd+R
xcodebuild -project ETerm/ETerm.xcodeproj -scheme ETerm build
```

## 架构概览

采用 **DDD（领域驱动设计）+ 单向数据流** 架构：

```
用户操作 → Coordinator → 聚合根(AR) → UI 重绘 → Rust 渲染
```

### 核心组件

| 层级 | 组件 | 职责 |
|------|------|------|
| Domain | TerminalWindow, EditorPanel, TerminalTab, Page | 业务状态、领域逻辑 |
| Application | CommandService, EventService, InputCoordinator | 命令分发、事件总线、输入协调 |
| Infrastructure | TerminalPoolWrapper, RenderSchedulerWrapper, WindowManager | Rust FFI 封装、渲染调度、窗口管理 |
| Presentation | RioTerminalView, PanelView, DomainPanelView | UI 渲染 |

### 数据流

```
TabClick → Coordinator.handleTabClick()
              ↓
          panel.setActiveTab()      # 修改 AR 状态
              ↓
          objectWillChange.send()   # 通知 SwiftUI
              ↓
          renderView.requestRender()
              ↓
          AR.getActiveTabsForRendering()  # 从 AR 读取
              ↓
          TerminalPool.render()     # Rust 渲染
```

详细架构说明见 [ARCHITECTURE.md](./ARCHITECTURE.md)

## 技术栈

- **渲染引擎**: Sugarloaf (WGPU + Metal)
- **终端后端**: Rio (crosswords + teletypewriter)
- **UI 框架**: SwiftUI + AppKit
- **FFI**: Rust cdylib

## 功能模块

### 终端功能
- GPU 加速渲染（60 FPS，Metal/WGPU）
- 多 Tab / 多 Panel 支持
- 文本选择和复制
- 中文输入法支持
- 字体大小调整 (Cmd+/-)

### 插件系统
- **ClaudeMonitor**: Claude 使用量监控和统计
- **EnglishLearning**: 英语学习功能（翻译、单词查询）
- **OneLineCommand**: 命令行快捷输入
- **WritingAssistant**: AI 写作助手
- **Vlaude**: 远程控制支持

### AI 功能
- 单词查询 (DictionaryService)
- 句子翻译 (DashScopeClient)
- 写作助手 (AIService)

## 开发指南

### 编译模式说明

| 脚本 | 用途 | LTO | 编译单元 | 增量编译 |
|------|------|-----|---------|----------|
| `update_sugarloaf_dev.sh` | 日常开发 | thin | 16 | ✅ |
| `build_sugarloaf_release.sh` | 正式发布 | full | 1 | ❌ |

**性能差异**：dev-fast 性能损失 < 5%，二进制稍大，但编译速度快 3-5 倍。

### 重新编译 Rust

修改 `sugarloaf-ffi/` 后：

```bash
# 日常开发
./scripts/update_sugarloaf_dev.sh

# Xcode: Cmd+Shift+K (Clean) → Cmd+B (Build)
```

### 添加新的 FFI 函数

1. 在 `rio/sugarloaf-ffi/src/ffi/*.rs` 添加 `#[no_mangle] pub extern "C" fn`
2. 在 `ETerm/ETerm/ETerm-Bridging-Header.h` 添加 C 声明
3. 在 `ETerm/ETerm/Core/Terminal/Infrastructure/FFI/` 中的 Swift Wrapper 封装

### 坐标系注意

- **Swift (macOS)**: 左下角原点，Y 向上
- **Rust (Sugarloaf)**: 左上角原点，Y 向下
- 使用 `CoordinateMapper` 进行转换

## 已知问题

- 运行时偶发 panic: `terminal_delete_range index out of bounds`
  - 原因：选区范围计算的边界问题
  - 状态：待修复

## Rio 源码 Patches

为支持 Apple Color Emoji，我们对 Rio 源码做了以下修改：

### 1. Emoji 字体 evictable 修复

**文件**: `rio/sugarloaf/src/font/mod.rs`

**问题**: 通过 `spec.emoji` 配置的自定义 emoji 字体使用 `evictable=true` 加载，导致字体数据被丢弃。当从 Binary source（如系统字体）加载时，`path` 被设置为字体名称而非实际路径，导致后续无法重新加载字体数据。

**修复**: 将 emoji 字体的 `evictable` 参数从 `true` 改为 `false`：
```rust
// Before: match find_font(&db, emoji_font, true, true)
match find_font(&db, emoji_font, false, true)
```

**待提交 PR**: https://github.com/raphamorim/rio/issues/XXX

### 2. 移除 fallback 中的 Apple Color Emoji

**文件**: `rio/sugarloaf/src/font/fallbacks/mod.rs`

**原因**: 如果 Apple Color Emoji 同时在 fallback 列表和 `spec.emoji` 中，会被加载两次。fallback 版本 `is_emoji=false`，会在字体匹配时优先命中，导致 emoji 渲染失败。

**修复**: 从 macOS fallback 列表中移除 `Apple Color Emoji`，由 `spec.emoji` 配置控制。

### 3. 自定义颜色主题 (Shuimo 水墨)

**文件**: `rio/rio-backend/src/config/colors/defaults.rs`

**说明**: ETerm 使用从 Warp 自定义主题移植的 "Shuimo（水墨）" 配色方案，特点是低饱和度、护眼舒适。

**配色方案**:
- 背景色: `#000000` (深黑)
- 前景色: `#dbdadd` (淡灰)
- 主要强调色: `#4a9992` (青绿) - 用于目录、成功提示
- 警告/错误色: `#861717` (暗红)

**配置备份**: `.eterm-config/shuimo-theme.toml`

**⚠️ 重要**: 当更新 Rio 子模块时，需要重新应用颜色配置：
1. 参考 `.eterm-config/shuimo-theme.toml` 中的颜色值
2. 修改 `rio/rio-backend/src/config/colors/defaults.rs` 中对应的 hex 值
3. 重新编译：`./scripts/update_sugarloaf_dev.sh`

**快速恢复命令**:
```bash
# 查看备份的配色
cat .eterm-config/shuimo-theme.toml

# 修改 defaults.rs 后重新编译
./scripts/update_sugarloaf_dev.sh
```

## 相关文档

- [ARCHITECTURE.md](./ARCHITECTURE.md) - DDD 架构详细设计
- [docs/PLUGIN_DEVELOPMENT_GUIDE.md](./docs/PLUGIN_DEVELOPMENT_GUIDE.md) - 插件开发指南
- [docs/COORDINATE_SYSTEM_ANALYSIS.md](./docs/COORDINATE_SYSTEM_ANALYSIS.md) - 坐标系分析
