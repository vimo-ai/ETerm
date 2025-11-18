# ETerm DDD 重构 - 继续工作 Prompt

> 这是给下一个对话的完整上下文

---

## 📋 项目背景

ETerm 是一个 macOS 终端模拟器，正在进行 DDD 架构重构：
- **前端**: Swift + SwiftUI
- **后端**: Rust (Sugarloaf 渲染引擎)
- **目标**: 让 Swift 完全掌控布局，Rust 只负责渲染

---

## ✅ 已完成的工作（80%）

### Swift 端 DDD 架构（100% 完成）

**Domain Layer**：
- ✅ 值对象：`PanelLayout`（布局树）, `PanelBounds`, `TabMetadata`, `SplitDirection`
- ✅ 聚合根：`TerminalWindow`, `EditorPanel`, `TerminalTab`
- ✅ 领域服务：`LayoutCalculator`, `BinaryTreeLayoutCalculator`

**Application Layer**：
- ✅ `WindowController` - 连接 Domain 和 Presentation

**Infrastructure Layer**：
- ✅ `CoordinateMapper` - 统一坐标转换（Swift ↔ Rust, 逻辑 ↔ 物理, 像素 ↔ 网格）
- ✅ `TerminalRenderConfig` - 渲染配置生成

**Presentation Layer**：
- ✅ `ETermApp` 创建 `WindowController`
- ✅ `TabTerminalView` 使用新架构的 Split 功能

**文件结构**：
```
ETerm/
├── Domain/              ✅ 完整
│   ├── ValueObjects/
│   ├── Aggregates/
│   └── Services/
├── Application/         ✅ 完整
│   └── Controllers/
├── Infrastructure/      ✅ 完整
│   ├── Coordination/
│   └── Rendering/
└── Presentation/        ⚠️ 部分
    └── Views/
```

---

## 🔄 待完成的核心工作（20%）

### Rust 层重构：让 ContextGrid 接收 Swift 的位置

**关键认知**：
```
ContextGrid 的三个职责（混杂）：
1. 布局运算（calculate_positions_recursive）  ← ❌ 要移除
2. 管理多个 Panel 数据（HashMap）            ← ✅ 保留
3. RIO 显示调用逻辑（objects()）              ← ✅ 保留（但用 Swift 的位置）
```

**不是删除 ContextGrid，而是**：
- 移除它的布局计算能力
- 让它接收 Swift 传来的位置
- 保留数据管理和渲染调用

---

## 🎯 具体任务

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

    // ❌ 删除 dimension
    // pub dimension: PaneDimension,
}

impl ContextGridItem {
    // ✅ 保留
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

// ❌ split_right() 和 split_down() 也可以删除（Swift 负责 split）
```

**新增这些方法**：
```rust
impl ContextGrid {
    /// ✅ 新增：让 Swift 设置 pane 位置
    pub fn set_pane_position(&mut self, pane_id: usize, x: f32, y: f32) {
        if let Some(item) = self.inner.get_mut(&pane_id) {
            // 转换为逻辑坐标
            let logical_x = x / self.scale;
            let logical_y = y / self.scale;
            item.set_position([logical_x, logical_y]);

            eprintln!("[ContextGrid] Set pane {} position: ({}, {}) logical, ({}, {}) physical",
                      pane_id, logical_x, logical_y, x, y);
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

                eprintln!("[ContextGrid] Resized pane {} terminal: {}x{}", pane_id, cols, rows);
            }
        }
    }

    /// ✅ 修改：objects() 不计算位置，直接使用已设置的位置
    pub fn objects(&self) -> Vec<Object> {
        eprintln!("[ContextGrid] Generating objects for {} panes", self.inner.len());
        let mut objects = Vec::new();

        for item in self.inner.values() {
            let pos = item.position();
            eprintln!("[ContextGrid] -> Pane {} at position [{}, {}]",
                      item.pane_id, pos[0], pos[1]);
            objects.push(item.get_rich_text_object().clone());
        }

        objects
    }
}
```

### 任务 3：修改 TabManager 的 update_panel_config

**文件**：`sugarloaf-ffi/src/terminal.rs`

**修改这个方法**（当前是"包装"旧逻辑，要改成真正使用 Swift 的配置）：

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
    eprintln!("[TabManager] update_panel_config: panel={}, pos=({}, {}), size={}x{}, grid={}x{}",
              panel_id, x, y, width, height, cols, rows);

    if let Some(context_grid) = &mut self.context_grid {
        // ✅ 设置位置（Swift 传来的）
        context_grid.set_pane_position(panel_id, x, y);

        // ✅ 设置尺寸
        context_grid.set_pane_size(panel_id, cols, rows);

        eprintln!("[TabManager] ✅ Successfully updated panel {}", panel_id);
        true
    } else {
        eprintln!("[TabManager] ❌ No context_grid available");
        false
    }
}
```

### 任务 4：修改 Swift 端的调用逻辑

**文件**：`ETerm/ETerm/TabTerminalView.swift`

**问题**：当前 `updateRustConfigs()` 有 Panel ID 映射问题
- Swift 使用 `UUID`
- Rust 使用 `usize`

**临时解决方案**（使用顺序映射）：

```swift
private func updateRustConfigs() {
    guard let controller = windowController,
          let tabManager = tabManager else {
        print("[Swift] ⚠️ No controller or tabManager")
        return
    }

    let configs = controller.panelRenderConfigs
    print("[Swift] Updating \(configs.count) panel configs")

    // 🎯 临时方案：用顺序作为 Rust panel_id
    // Panel 1 → Rust pane_id = 1
    // Panel 2 → Rust pane_id = 2
    // ...
    for (index, (panelId, config)) in configs.enumerated() {
        let rustPanelId = size_t(index + 1)  // Rust pane_id 从 1 开始

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
            print("[Swift] ✅ Panel \(panelId) (Rust:\(rustPanelId)) → \(config.cols)x\(config.rows)")
        } else {
            print("[Swift] ❌ Failed to update panel \(panelId)")
        }
    }

    renderTerminal()
}
```

**改进方案**（在 `WindowController` 中维护映射表）：

```swift
// WindowController.swift
private var panelIdMapping: [UUID: Int] = [:]  // Swift UUID → Rust usize

func registerPanel(_ panelId: UUID, rustId: Int) {
    panelIdMapping[panelId] = rustId
}

func getRustPanelId(_ swiftId: UUID) -> Int? {
    return panelIdMapping[swiftId]
}
```

---

## 🧪 验收标准

完成后运行 App，验证：

### 功能验证
- [ ] App 可以启动
- [ ] 点击"垂直分割"按钮，窗口左右分割
- [ ] 点击"水平分割"按钮，窗口上下分割
- [ ] 拖动分隔线可以调整大小（如果还不行，可以后续修复）
- [ ] 鼠标滚动正常
- [ ] 文本选择正常

### 架构验证（查看日志）
```
[Swift] Updating 2 panel configs
[Swift] ✅ Panel xxx (Rust:1) → 80x24
[Swift] ✅ Panel yyy (Rust:2) → 80x24
[TabManager] update_panel_config: panel=1, pos=(0, 0), size=400x600, grid=80x24
[ContextGrid] Set pane 1 position: (0, 0) logical...
[TabManager] ✅ Successfully updated panel 1
[TabManager] update_panel_config: panel=2, pos=(400, 0), size=400x600, grid=80x24
[ContextGrid] Set pane 2 position: (400, 0) logical...
[TabManager] ✅ Successfully updated panel 2
[ContextGrid] Generating objects for 2 panes
[ContextGrid] -> Pane 1 at position [0, 0]
[ContextGrid] -> Pane 2 at position [200, 0]  ← 注意是逻辑坐标（除以 scale）
```

**关键**：Rust 的日志显示它在使用 Swift 传来的位置，而不是自己计算！

---

## ⚠️ 可能遇到的问题

### 问题 1：编译错误（未使用的代码）
**解决**：注释掉（不要删除），等确认功能正常后再删除

### 问题 2：Panel ID 映射不对，渲染错误
**解决**：
- 检查日志，确认 Swift 传的 ID 和 Rust 收到的 ID 一致
- 临时方案：用顺序映射（第一个 Panel = 1）

### 问题 3：位置不对，Panel 显示在错误位置
**解决**：
- 检查坐标转换（Swift 是左下角原点，Rust 是左上角原点）
- 检查 scale 转换（物理像素 vs 逻辑坐标）
- 查看 `CoordinateMapper` 的日志

### 问题 4：Split 后只看到一个 Panel
**可能原因**：
- Rust 没有正确接收第二个 Panel 的配置
- `create_panel` 没有正确创建新的 ContextGridItem
- 检查 `updateRustConfigs` 是否在 split 后被调用

---

## 📝 开发提示

### 调试技巧
1. **保留所有 print/eprintln**，方便追踪数据流
2. **先让一个 Panel 正常**，再处理多个 Panel
3. **检查日志顺序**，确认调用链正确

### 代码风格
- Rust：保留现有的 eprintln! 调试日志
- Swift：使用 `print("[Swift] ...")` 标记来源
- 注释清楚标记 ✅ 保留、❌ 删除、🎯 关键

### Git 提交
每完成一个任务就提交：
- `refactor(rust): 移除 ContextGrid 布局计算逻辑`
- `refactor(rust): 添加接收 Swift 位置的接口`
- `fix(swift): 修复 Panel ID 映射问题`

---

## 🚀 工作流程建议

1. **先改 Rust 代码**（任务 1-3）
   - 编译 Rust：`cd sugarloaf-ffi && cargo build --release`
   - 更新库：`./scripts/update_sugarloaf.sh`

2. **再改 Swift 代码**（任务 4）
   - 在 Xcode 中修改
   - 编译 Swift

3. **运行测试**
   - 启动 App
   - 测试 Split 功能
   - 查看日志验证架构

4. **提交代码**
   - `git add -A && git commit -m "refactor: 完成 Rust 层重构，Swift 真正掌控布局"`

---

## 📚 参考文档

- `docs/DDD_ARCHITECTURE.md` - 完整的架构设计
- `docs/CURRENT_STATUS.md` - 当前状态详细说明
- `docs/DEVELOPMENT_PLAN.md` - 原始开发计划

---

## 🎯 最终目标

完成后，整个系统的数据流应该是：

```
用户点击 "Split Right"
    ↓
Swift: WindowController.splitPanel(panelId, .horizontal)
    ↓
Swift: TerminalWindow.splitPanel() 计算布局树
    ↓
Swift: LayoutCalculator.calculateSplitLayout()
    ↓
Swift: 生成 PanelLayout = split(horizontal, leaf(1), leaf(2), 0.5)
    ↓
Swift: LayoutCalculator.calculatePanelBounds() 计算所有位置
    ↓
Swift: 生成 panelRenderConfigs = [
    Panel1: (x=0, y=0, w=400, h=600, cols=80, rows=24),
    Panel2: (x=400, y=0, w=400, h=600, cols=80, rows=24)
]
    ↓
Swift: updateRustConfigs() 调用 FFI
    ↓
Rust: tab_manager_update_panel_config(1, 0, 0, 400, 600, 80, 24)
Rust: tab_manager_update_panel_config(2, 400, 0, 400, 600, 80, 24)
    ↓
Rust: context_grid.set_pane_position(1, 0, 0)
Rust: context_grid.set_pane_position(2, 400, 0)
    ↓
Rust: 渲染时使用这些位置（不再自己计算）
    ↓
✅ Swift 完全掌控布局！
```

---

**开始工作吧！优先完成 Rust 层重构，让架构闭环！** 🚀
