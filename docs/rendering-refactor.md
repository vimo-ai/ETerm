# 渲染架构重构设计

## 一、现状问题

### 1.1 渲染层面
- 每帧都重建所有 Terminal 的 Image，即使内容没变化
- 无 damage 的 Terminal 仍被遍历（缓存命中但有开销）
- Page 切换后，旧 Page 的 Terminal 仍可能触发渲染逻辑
- Image 全量提交到 GPU，没有复用机制

### 1.2 架构层面
- Swift 层 UI 混乱（SwiftUI + NSView 混用）
- 布局计算分散在多个层级
- `syncLayoutToRust()` 每次 `requestRender` 都调用，即使布局没变

## 二、目标架构

### 2.1 边界划分

```
Swift 层（交互 + UI 控件）
├── PageBar（Tab 切换、拖拽排序）
├── PanelHeader（标题、关闭按钮）
├── DividerView（分割线、拖拽调整）
├── TabItemView（Tab 项）
├── 各种 Overlay（搜索框、InlineComposer）
└── 菜单、设置面板等

Rust 层（纯渲染）
├── 终端内容（文字、光标、选中高亮）
├── 终端背景
└── 搜索高亮等视觉效果
```

### 2.2 渲染架构

```
┌─────────────────────────────────────────────────┐
│              共享资源层                          │
│  ┌─────────────┐  ┌─────────────┐              │
│  │ Font Cache  │  │ Glyph Atlas │              │
│  │  (字体缓存)  │  │ (字形纹理)   │              │
│  └─────────────┘  └─────────────┘              │
└─────────────────────────────────────────────────┘
         ↑                ↑                ↑
         │                │                │
┌────────┴───┐   ┌───────┴────┐   ┌───────┴────┐
│ Terminal 1 │   │ Terminal 2 │   │ Terminal 3 │
│ ┌────────┐ │   │ ┌────────┐ │   │ ┌────────┐ │
│ │Surface │ │   │ │Surface │ │   │ │Surface │ │
│ │(GPU纹理)│ │   │ │(GPU纹理)│ │   │ │(GPU纹理)│ │
│ └────────┘ │   │ └────────┘ │   │ └────────┘ │
│  独立dirty  │   │  独立dirty  │   │  独立dirty  │
└────────────┘   └────────────┘   └────────────┘
         │                │                │
         └────────────────┼────────────────┘
                          ↓
              ┌─────────────────────┐
              │    GPU 合成层        │
              │  (贴图到正确位置)     │
              └─────────────────────┘
```

### 2.3 渲染流程（重构后）

```
render_all():
    layout = get_current_layout()  // 只包含当前 Page 的可见终端

    for terminal_id in layout:
        if terminal.is_damaged:
            terminal.update_surface()  // 更新自己的 GPU 纹理
        // 无 damage 则跳过，Surface 保持不变

    // 合成阶段
    canvas.clear()
    for terminal_id in layout:
        canvas.draw_image(terminal.surface, position)  // 直接贴图
```

## 三、核心改动

### 3.1 Rust 侧

#### 3.1.1 Terminal 独立 Surface

```rust
// 新增：每个 Terminal 的渲染状态
struct TerminalRenderState {
    surface: skia::Surface,  // 独立 GPU 纹理
    width: u32,
    height: u32,
}

// TerminalEntry 新增字段
struct TerminalEntry {
    terminal: Arc<Mutex<Terminal>>,
    pty_tx: channel::Sender<...>,
    // ... 原有字段
    render_state: Option<TerminalRenderState>,  // 新增
}
```

#### 3.1.2 按需更新逻辑

```rust
pub fn render_terminal(&mut self, id: usize, x: f32, y: f32, width: f32, height: f32) -> bool {
    let entry = self.terminals.get_mut(&id)?;

    // 检查是否需要重建 Surface（尺寸变化）
    if needs_recreate_surface(entry, width, height) {
        entry.render_state = Some(create_surface(width, height));
    }

    // 检查 damage
    let terminal = entry.terminal.lock();
    if !terminal.is_damaged() {
        return true;  // 跳过，复用已有 Surface
    }

    // 有 damage，更新 Surface
    let surface = &mut entry.render_state.as_mut()?.surface;
    let canvas = surface.canvas();

    // 渲染终端内容到 Surface
    render_terminal_content(canvas, &terminal);

    terminal.reset_damage();
    true
}
```

#### 3.1.3 合成阶段

```rust
pub fn end_frame(&mut self) {
    let mut sugarloaf = self.sugarloaf.lock();
    let canvas = sugarloaf.canvas();

    canvas.clear(background_color);

    // 从 layout 获取位置，从 Terminal 获取 Surface
    let layout = self.render_layout.lock();
    for (terminal_id, x, y, _, _) in layout.iter() {
        if let Some(entry) = self.terminals.get(terminal_id) {
            if let Some(render_state) = &entry.render_state {
                let image = render_state.surface.image_snapshot();
                canvas.draw_image(&image, (*x, *y), None);
            }
        }
    }

    sugarloaf.flush();
}
```

### 3.2 Swift 侧

#### 3.2.1 优化 syncLayoutToRust

```swift
// 缓存上次的 layout，只在变化时同步
private var lastLayoutHash: Int = 0

private func syncLayoutToRust() {
    let tabsToRender = coordinator.terminalWindow.getActiveTabsForRendering(...)

    // 计算 hash，判断是否变化
    let currentHash = calculateLayoutHash(tabsToRender)
    if currentHash == lastLayoutHash {
        return  // 布局没变，跳过
    }
    lastLayoutHash = currentHash

    // 布局变化，同步到 Rust
    pool.setRenderLayout(layouts, containerHeight: ...)
}
```

#### 3.2.2 requestRender 简化

```swift
func requestRender() {
    guard isInitialized else { return }

    // 只在布局可能变化的场景才同步
    // 键盘输入等场景不需要同步布局
    renderScheduler?.requestRender()
}

// 布局变化时单独调用
func onLayoutChanged() {
    syncLayoutToRust()
    requestRender()
}
```

## 四、实施计划

### 阶段一：Rust 渲染优化（可独立测试）

1. **Terminal 独立 Surface**
   - TerminalEntry 新增 render_state 字段
   - Surface 创建/销毁/resize 逻辑

2. **按需更新**
   - render_terminal 检查 damage
   - 无 damage 跳过渲染

3. **合成逻辑**
   - end_frame 改为贴图合成
   - 只处理 layout 中的终端

4. **单元测试**
   - Surface 生命周期测试
   - damage 检测测试
   - 多终端渲染测试

### 阶段二：集成验证

- 用现有 Swift 代码测试
- 验证 Page 切换行为
- 验证性能提升

### 阶段三：Swift UI 优化（可独立进行）

1. **syncLayoutToRust 优化**
   - 添加 layout hash 缓存
   - 只在变化时同步

2. **requestRender 拆分**
   - 区分布局变化 vs 内容变化
   - 减少不必要的 FFI 调用

3. **NSView 层级清理**（如需要）
   - 评估现有结构是否需要调整

## 五、接口兼容性

### 不变的 FFI 接口
```c
terminal_pool_create()
terminal_pool_destroy()
terminal_pool_create_terminal()
terminal_pool_close_terminal()
terminal_pool_resize_terminal()
terminal_pool_write_input()
terminal_pool_set_render_layout()
terminal_pool_render_all()
render_scheduler_request_render()
// ... 其他现有接口
```

### 内部变化（对 Swift 透明）
- Terminal 内部持有 Surface
- render_terminal 行为变化（检查 damage）
- end_frame 行为变化（贴图合成）

## 六、预期收益

| 场景 | 现状 | 重构后 |
|------|------|--------|
| 无变化的 Terminal | 遍历 + 缓存命中 | 完全跳过 |
| Page 切换后旧 Page | 可能仍触发渲染 | 不在 layout，零开销 |
| 单终端输入 | 所有终端重建 Image | 只更新一个 Surface |
| GPU 提交 | 每帧重建所有 Image | 贴图合成，复用 Surface |

## 七、风险与缓解

1. **Surface 内存占用**
   - 每个 Terminal 一个 GPU 纹理
   - 缓解：合理的 Surface 尺寸，及时释放不可见的

2. **resize 时重建 Surface**
   - 可能有短暂卡顿
   - 缓解：异步重建，或延迟重建

3. **多屏 DPI 切换**
   - Surface scale 需要更新
   - 缓解：监听 DPI 变化，重建 Surface
