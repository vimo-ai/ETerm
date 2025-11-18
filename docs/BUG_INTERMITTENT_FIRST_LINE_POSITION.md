# Bug Report: 间歇性首行位置错误

## 🐛 问题描述

在垂直分割(左右布局)后,**左侧 Panel 的第一行**(通常是 Shell Prompt,如 `(base) ➜ ~`)位置错误。

### 症状

1. **只影响第一行**: 其他所有行位置正常
2. **整行一起错误**: 不是单个字符,而是整行文本位置不对
3. **Resize 时移动**: 该行会随窗口 resize 在整个屏幕宽度范围内移动
4. **无法稳定复现**: 有时出现,有时正常,复现条件不明

### 影响范围

- **受影响**: 左侧 Panel 的第一行
- **不受影响**:
  - 右侧 Panel (完全正常)
  - 左侧 Panel 的其他行 (第二行及以后都正常)

---

## 🔍 已知信息

### 环境信息

- **macOS 版本**: Darwin 25.0.0
- **屏幕配置**: Retina 显示器 (scale 2.0)
- **窗口尺寸**: 1913.0x1118.0 points (3826.0x2236.0 pixels)

### 触发条件

1. 启动应用
2. 点击"垂直分割(左右)"按钮
3. **有时**会出现左侧 Panel 首行位置错误

### 观察到的行为

**正常情况**:
```
Left Panel:  Position: (10.0, 10.0)
Right Panel: Position: (976.5, 10.0)
第一行正常显示在左上角
```

**异常情况**:
```
Left Panel:  Position: (10.0, 10.0)  ← Panel 位置正确
Right Panel: Position: (976.5, 10.0)
但第一行 `(base) ➜ ~` 位置错误,会随 resize 移动
```

---

## 🧩 技术分析

### 1. Panel 位置计算正确

从日志可以确认:
- Swift 计算的 `PanelBounds` 正确
- `TerminalRenderConfig` 转换正确
- Rust 接收的位置参数正确
- `ContextGrid` 设置的 `RichText.position` 正确

**结论**: Panel 级别的位置计算没有问题。

### 2. 只有首行受影响

**关键特征**:
- 第 2 行及以后的所有行位置正常
- 只有第 1 行(通常是 Shell Prompt)位置错误

**可能原因**:

#### 假设 A: 终端内部渲染问题

Sugarloaf 或底层终端在渲染第一行时可能有特殊处理:
- 光标所在行的特殊样式
- Prompt 高亮
- 编辑缓冲区的独立渲染

#### 假设 B: RichText 内部坐标问题

`RichText` 对象内部可能有:
```
RichText {
    position: [10.0, 10.0],  // ← 整体位置(正确)
    fragments: [
        Fragment {
            text: "(base) ➜ ~ ",
            relative_position: [?, ?]  // ← 可能这里错了
        },
        Fragment { text: "第二行...", relative_position: [0, 20] },
        ...
    ]
}
```

如果第一个 fragment 的相对位置错误,就会导致只有第一行位置不对。

#### 假设 C: 坐标转换时机问题

可能存在:
1. 设置 Panel 位置时,`scale` = 1.0 (错误)
2. 渲染第一行时,`scale` = 1.0
3. 渲染其他行时,`scale` = 2.0 (正确)

导致第一行使用了错误的坐标转换。

### 3. Resize 时移动整个屏幕宽度

**现象**: 第一行的 X 坐标 = `containerWidth - something`

**分析**:

可能是某个计算使用了错误的坐标系:
```rust
// 错误示例
first_line_x = container_width - panel_width  // ← 应该是 panel_x
```

或者坐标翻转错误:
```rust
// Swift 坐标系翻转
x_rust = container_width - x_swift  // ← Y 轴才需要翻转,X 轴不需要!
```

---

## 🔬 需要的调试信息

### 下次复现时收集:

1. **完整的坐标日志**:
```
[RenderConfig] 所有 Panel 的坐标转换
[ContextGrid] 所有 Pane 的位置设置
[ContextGrid] objects() 生成时的位置
```

2. **RichText 对象详情**:
```rust
// 在 ContextGrid::objects() 中添加
eprintln!("[ContextGrid] RichText for pane {}:", pane_id);
if let Object::RichText(ref rt) = item.rich_text_object {
    eprintln!("  position: {:?}", rt.position);
    eprintln!("  content length: {}", rt.content.len());
    // 如果可以访问 fragments
    // eprintln!("  first fragment pos: {:?}", rt.fragments[0].position);
}
```

3. **Scale 值变化**:
```
[CoordinateMapper] 每次创建时的 scale
[ContextGrid] set_pane_position 时的 self.scale
```

4. **时序信息**:
```
记录从 Split 到渲染的完整调用链时间戳
确认是否有并发问题
```

---

## 🧪 建议的调试步骤

### 步骤 1: 添加详细日志

在 `context_grid.rs` 的 `set_pane_position()` 中:

```rust
pub fn set_pane_position(&mut self, pane_id: usize, x: f32, y: f32) {
    if let Some(item) = self.inner.get_mut(&pane_id) {
        let logical_x = x / self.scale;
        let logical_y = y / self.scale;

        eprintln!("[ContextGrid] 🔍 set_pane_position:");
        eprintln!("  pane_id: {}", pane_id);
        eprintln!("  input (physical): ({}, {})", x, y);
        eprintln!("  self.scale: {}", self.scale);
        eprintln!("  output (logical): ({}, {})", logical_x, logical_y);

        // 检查 RichText 对象
        if let Object::RichText(ref rt) = item.rich_text_object {
            eprintln!("  current RichText position: {:?}", rt.position);
        }

        item.set_position([logical_x, logical_y]);

        // 确认设置成功
        let new_pos = item.position();
        eprintln!("  verified new position: {:?}", new_pos);
    }
}
```

### 步骤 2: 检查 Sugarloaf RichText 渲染

查看 `rio/sugarloaf/src/components/rich_text/` 中的渲染逻辑:
- 是否有光标独立渲染
- 是否有 Prompt 特殊处理
- Fragment 的坐标计算方式

### 步骤 3: 临时 Workaround

如果问题频繁出现,可以尝试:

```swift
// TabTerminalView.swift
private func updateRustConfigs() {
    // ... 正常更新

    // 🔧 Workaround: 强制刷新第一行
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.renderTerminal()
    }
}
```

---

## 📝 相关代码位置

### Swift 端

- **坐标计算**: `TerminalRenderConfig.swift:44-88`
- **坐标转换**: `CoordinateMapper.swift:36-41`
- **配置更新**: `TabTerminalView.swift:updateRustConfigs()`

### Rust 端

- **位置设置**: `context_grid.rs:477-486` (`set_pane_position`)
- **对象生成**: `context_grid.rs:567-578` (`objects()`)
- **渲染入口**: `terminal.rs:update_panel_config()`

---

## 🎯 下一步行动

### 高优先级

1. ✅ 已修复: Scale 获取不稳定的问题
2. ⏳ 待验证: 观察 scale 修复后问题是否消失
3. ⏳ 待收集: 下次复现时的详细日志

### 低优先级 (如果问题持续)

1. 深入研究 Sugarloaf RichText 内部实现
2. 检查是否需要 Sugarloaf 库升级
3. 考虑自定义渲染逻辑绕过问题

---

## 📊 复现记录

### 2025-11-18

- **复现次数**: 2/5 (40%)
- **环境**: 开发机,单屏
- **触发方式**: 启动后立即点击垂直分割
- **修复尝试**: 修复了 Scale 获取逻辑 (使用 `getWindowScale()` + 延迟)

### 待更新

下次复现时记录:
- 时间
- 具体操作步骤
- 完整日志
- 截图

---

## 🔗 相关 Issue

- [ ] GitHub Issue #XXX (待创建)
- [ ] 相关讨论: docs/CONTINUATION_PROMPT.md

---

**最后更新**: 2025-11-18
**状态**: 🟡 调查中 (Scale 修复可能已解决)
**负责人**: Claude + User
