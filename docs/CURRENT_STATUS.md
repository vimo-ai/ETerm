# ETerm DDD 重构 - 当前状态报告

> 更新时间：2025-11-18
> 工作进度：约 80% 完成

---

## ✅ 已完成的工作

### 阶段 1-4：Swift 端 DDD 架构（100% 完成）

#### Domain Layer（领域层）✅
```
ETerm/Domain/
├── ValueObjects/
│   ├── SplitDirection.swift      ✅ 分割方向枚举
│   ├── PanelLayout.swift          ✅ 布局树（递归结构）
│   ├── PanelBounds.swift          ✅ Panel 边界信息
│   └── TabMetadata.swift          ✅ Tab 元数据
├── Aggregates/
│   ├── TerminalWindow.swift       ✅ 窗口聚合根
│   ├── EditorPanel.swift          ✅ 面板聚合根
│   └── TerminalTab.swift          ✅ Tab 聚合根
└── Services/
    ├── LayoutCalculator.swift     ✅ 布局计算器协议
    └── BinaryTreeLayoutCalculator.swift ✅ 二叉树布局实现
```

**核心能力**：
- ✅ Swift 可以独立计算布局（不依赖 Rust）
- ✅ 布局树结构清晰，支持任意复杂的分割
- ✅ 布局算法独立可测试

#### Application Layer（应用层）✅
```
ETerm/Application/
└── Controllers/
    └── WindowController.swift     ✅ 窗口控制器
```

**核心能力**：
- ✅ 连接 Domain Layer 和 Presentation Layer
- ✅ 提供 `panelBounds` 和 `panelRenderConfigs` 计算属性
- ✅ 使用 `@Observable` 支持 SwiftUI 响应式更新

#### Infrastructure Layer（基础设施层）✅
```
ETerm/Infrastructure/
├── Coordination/
│   └── CoordinateMapper.swift     ✅ 坐标映射服务
└── Rendering/
    └── TerminalRenderConfig.swift ✅ 渲染配置
```

**核心能力**：
- ✅ 统一处理所有坐标转换（Swift ↔ Rust, 逻辑 ↔ 物理, 像素 ↔ 网格）
- ✅ 自动计算 rows/cols
- ✅ 避免了坐标转换混乱的问题

#### Presentation Layer（表示层）⚠️ 部分完成
- ✅ `ETermApp.swift` 创建 `WindowController`
- ✅ `TabTerminalView.swift` 接收 `WindowController`
- ✅ Split 按钮调用 `controller.splitPanel()`（使用新架构）
- ⚠️ `TerminalManagerNSView` 大部分还是旧代码（直接调用 Rust FFI）

---

## 🔄 正在进行的工作

### 阶段 6：Rust 层简化（20% 完成）

#### 已完成 ✅
1. **添加了新的 FFI 函数声明**（`SugarloafBridge.h`）
   - `tab_manager_create_panel(cols, rows)`
   - `tab_manager_update_panel_config(panel_id, x, y, width, height, cols, rows)`

2. **在 Rust 中实现了接口**（`terminal.rs`, `lib.rs`）
   - 但目前是"包装"旧逻辑，不是真正的重构

3. **FFI 链接问题已解决**
   - 执行了 `./scripts/update_sugarloaf.sh`
   - 库文件已更新到 Xcode 能找到的位置

#### 待完成 ❌
**核心任务：让 ContextGrid 接收 Swift 的位置，而不是自己计算**

当前问题分析：
```
ContextGrid 的三个职责（混杂）：
1. 布局运算（calculate_positions_recursive）  ← ❌ 要移除
2. 管理多个 Panel 数据（HashMap）            ← ✅ 保留
3. RIO 显示调用逻辑（objects()）              ← ✅ 保留（但用 Swift 的位置）
```

需要重构的内容：
- ❌ 移除链表关系（right/down/parent）
- ❌ 移除 `calculate_positions_recursive()`
- ❌ 移除 `resize_pane_recursive()`
- ✅ 新增 `set_pane_position(pane_id, x, y)` - 让 Swift 设置位置
- ✅ 修改 `objects()` - 使用 Swift 传入的位置，不自己计算

---

## 🎯 下一步工作：完成 Rust 层重构

### 任务 1：修改 ContextGridItem 结构

**文件**：`sugarloaf-ffi/src/context_grid.rs`

**改动**：
```rust
pub struct ContextGridItem {
    pub pane_id: usize,
    pub terminal: Box<TerminalHandle>,
    pub rich_text_id: usize,
    rich_text_object: Object,

    pub cols: u16,
    pub rows: u16,

    // ❌ 删除链表关系
    // right: Option<usize>,
    // down: Option<usize>,
    // parent: Option<usize>,

    // ❌ 删除 dimension（不需要了）
    // pub dimension: PaneDimension,
}

impl ContextGridItem {
    // ✅ 保留 position()，但直接从 rich_text_object 读取
    pub fn position(&self) -> [f32; 2] {
        if let Object::RichText(ref rich_text) = self.rich_text_object {
            rich_text.position
        } else {
            [0.0, 0.0]
        }
    }

    // ✅ 新增：让 Swift 设置位置
    pub fn set_position(&mut self, position: [f32; 2]) {
        if let Object::RichText(ref mut rich_text) = self.rich_text_object {
            rich_text.position = position;
        }
    }
}
```

### 任务 2：修改 ContextGrid 方法

**删除这些方法**：
```rust
// ❌ 删除
fn calculate_positions_for_affected_nodes(...)
fn calculate_positions_recursive(...)
fn resize_pane_recursive(...)
```

**新增/修改这些方法**：
```rust
impl ContextGrid {
    /// ✅ 新增：让 Swift 设置 pane 位置
    pub fn set_pane_position(&mut self, pane_id: usize, x: f32, y: f32) {
        if let Some(item) = self.inner.get_mut(&pane_id) {
            // 转换为逻辑坐标（Sugarloaf 内部会乘以 scale）
            let logical_x = x / self.scale;
            let logical_y = y / self.scale;
            item.set_position([logical_x, logical_y]);
        }
    }

    /// ✅ 新增：让 Swift 设置 pane 尺寸
    pub fn set_pane_size(&mut self, pane_id: usize, cols: u16, rows: u16) {
        if let Some(item) = self.inner.get_mut(&pane_id) {
            if item.cols != cols || item.rows != rows {
                item.cols = cols;
                item.rows = rows;

                let terminal_ptr = &mut *item.terminal as *mut TerminalHandle;
                unsafe {
                    crate::terminal_resize(terminal_ptr, cols, rows);
                }
            }
        }
    }

    /// ✅ 修改：objects() 不再计算位置，直接使用已设置的位置
    pub fn objects(&self) -> Vec<Object> {
        let mut objects = Vec::new();
        for item in self.inner.values() {
            objects.push(item.get_rich_text_object().clone());
        }
        objects
    }
}
```

### 任务 3：修改 TabManager 的 update_panel_config

**文件**：`sugarloaf-ffi/src/terminal.rs`

**当前实现（错误）**：
```rust
pub fn update_panel_config(...) -> bool {
    // ❌ 现在只是调用 resize_all_tabs
    self.resize_all_tabs(cols, rows);
    true
}
```

**应该改成（正确）**：
```rust
pub fn update_panel_config(
    &mut self,
    panel_id: usize,
    x: f32,           // Swift 传来的位置（物理像素，Rust 坐标系）
    y: f32,
    width: f32,
    height: f32,
    cols: u16,
    rows: u16,
) -> bool {
    if let Some(context_grid) = &mut self.context_grid {
        // ✅ 设置位置（Swift 传来的）
        context_grid.set_pane_position(panel_id, x, y);

        // ✅ 设置尺寸
        context_grid.set_pane_size(panel_id, cols, rows);

        eprintln!("[TabManager] ✅ Updated panel {} config: pos=({}, {}), grid={}x{}",
                  panel_id, x, y, cols, rows);
        true
    } else {
        eprintln!("[TabManager] ❌ No context_grid");
        false
    }
}
```

### 任务 4：修改 Swift 端的调用

**文件**：`ETerm/ETerm/TabTerminalView.swift`

**修改 `updateRustConfigs()` 方法**：
```swift
private func updateRustConfigs() {
    guard let controller = windowController,
          let tabManager = tabManager else { return }

    let configs = controller.panelRenderConfigs

    // 🎯 关键：需要建立 UUID → usize 的映射
    // 临时方案：用 Panel 的顺序作为 panel_id
    let panelIds = Array(controller.allPanelIds.enumerated())

    for (index, (panelId, config)) in zip(panelIds, configs).enumerated() {
        let rustPanelId = size_t(index + 1)  // Rust 的 panel_id 从 1 开始

        let success = tab_manager_update_panel_config(
            tabManager.handle,
            rustPanelId,
            config.x,
            config.y,
            config.width,
            config.height,
            config.cols,
            config.rows
        )

        if success != 0 {
            print("[Swift] ✅ Updated panel \(panelId) (Rust ID: \(rustPanelId))")
        } else {
            print("[Swift] ❌ Failed to update panel \(panelId)")
        }
    }

    renderTerminal()
}
```

---

## ⚠️ 关键问题：Panel ID 映射

**问题**：
- Swift 使用 `UUID` 作为 Panel ID
- Rust 使用 `usize` 作为 Pane ID
- 需要建立映射关系

**临时方案**：
- 使用 Panel 的顺序作为 ID（第一个 Panel = 1，第二个 = 2...）
- 在 `WindowController` 中维护 `[UUID: usize]` 映射表

**长期方案**（可选）：
- Rust 也使用 UUID（但需要大幅改动）
- 或者 Swift 侧维护一个 ID 转换层

---

## 🎯 最终目标验证

完成后，应该达到：

### 功能验证 ✅
- [ ] App 可以启动
- [ ] 可以执行 Split 操作（垂直/水平）
- [ ] 拖动分隔线可以调整大小
- [ ] 鼠标滚动正常
- [ ] 文本选择正常

### 架构验证 ✅
- [ ] Swift 计算布局（`LayoutCalculator`）
- [ ] Swift 传递配置给 Rust（`updateRustConfigs`）
- [ ] Rust 使用 Swift 的配置渲染（不自己算位置）
- [ ] 日志显示 Swift 和 Rust 的位置一致

### 代码质量 ✅
- [ ] Rust 代码简化（移除了布局计算）
- [ ] Swift 代码分层清晰
- [ ] 坐标转换统一（`CoordinateMapper`）

---

## 📝 技术债务和已知问题

1. **Panel ID 映射**：临时使用顺序映射，需要后续优化
2. **旧代码清理**：`TabTerminalView.swift` 还有很多旧代码需要清理
3. **光标偏移问题**：padding 设置问题，等重构完成后统一修复
4. **单元测试**：核心算法还没有测试覆盖

---

## 🚀 下一步行动

**优先级 1（必须）**：
- 完成 Rust 层重构（上述任务 1-4）
- 测试基本功能可用

**优先级 2（重要）**：
- 清理 Swift 代码
- 整理文件结构
- 移除旧代码

**优先级 3（可选）**：
- 添加单元测试
- 完善错误处理
- 性能优化

---

## 📊 代码统计

**新增文件**：12 个 Swift 文件
**修改文件**：5 个文件
**代码行数**：约 1500+ 行新代码

**Rust 改动**：
- 新增：2 个 FFI 函数
- 待删除：约 200 行布局计算代码
- 待新增：约 50 行位置设置代码

---

**文档版本**: v1.1
**更新时间**: 2025-11-18 21:00
**下次更新**: Rust 重构完成后
