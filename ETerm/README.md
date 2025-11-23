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
    └── update_sugarloaf.sh   # 编译更新脚本
```

## 快速开始

### 1. 编译 Rust FFI

```bash
./scripts/update_sugarloaf.sh
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

### 重新编译 Rust

修改 `sugarloaf-ffi/` 后：

```bash
./scripts/update_sugarloaf.sh
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

## 相关文档

- [ARCHITECTURE.md](./ARCHITECTURE.md) - DDD 架构详细设计
- [Presentation/Views/README.md](./ETerm/Presentation/Views/README.md) - UI 组件说明
