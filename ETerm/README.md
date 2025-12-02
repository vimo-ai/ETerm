# ETerm

基于 Rio/Sugarloaf 渲染引擎的 macOS 终端应用，集成英语学习功能。

## 项目结构

```
english/
├── ETerm/                    # Swift macOS 应用
│   ├── ETerm/
│   │   ├── Domain/           # DDD 领域层（聚合根、值对象、服务）
│   │   ├── Application/      # 应用层（Coordinator、Keyboard）
│   │   ├── Infrastructure/   # 基础设施层（FFI、渲染）
│   │   ├── Presentation/     # 表现层（SwiftUI/AppKit 视图）
│   │   └── Protocols/        # 协议定义
│   ├── Sugarloaf/            # 静态库目录
│   └── ARCHITECTURE.md       # 详细架构文档
│
├── sugarloaf-ffi/            # Rust FFI 桥接层
│   ├── src/
│   │   ├── lib.rs            # Sugarloaf FFI
│   │   ├── terminal.rs       # 终端管理 + TerminalPool
│   │   └── context_grid.rs   # Panel 布局管理
│   └── Cargo.toml
│
├── rio/                      # Rio 终端源码（submodule，保持干净）
└── scripts/
    ├── update_sugarloaf_dev.sh     # 🚀 开发快速编译（thin LTO）
    └── build_sugarloaf_release.sh  # 🏗️ 发布完整优化（full LTO）
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
| Domain | TerminalWindow, EditorPanel, TerminalTab | 业务状态、领域逻辑 |
| Application | TerminalWindowCoordinator, KeyboardSystem | 协调、用户交互处理 |
| Infrastructure | TerminalPoolWrapper, SugarloafWrapper | Rust FFI 封装 |
| Presentation | DDDTerminalView, PanelView | UI 渲染 |

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
- GPU 加速渲染（60 FPS）
- 多 Tab / 多 Panel 支持
- 文本选择和复制
- 中文输入法支持
- 字体大小调整 (Cmd+/-)

### 英语学习（集成中）
- 单词查询 (DictionaryService)
- 句子理解 (OllamaService)
- 写作助手

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

1. 在 `sugarloaf-ffi/src/*.rs` 添加 `#[no_mangle] pub extern "C" fn`
2. 在 `ETerm/ETerm/SugarloafBridge.h` 添加 C 声明
3. 在 Swift Wrapper 中封装

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
- [Presentation/Views/README.md](./ETerm/Presentation/Views/README.md) - UI 组件说明
