# 渲染问题调试

## 当前状态
- ✅ Sugarloaf 成功初始化
- ✅ render() 被调用
- ✅ Metal layer 存在
- ❌ 屏幕显示黑色

## 可能的原因

### 1. RichText 渲染问题
可能是字体加载失败或 RichText 渲染有问题。

**解决方案**: 尝试渲染 Quad (矩形) 代替 RichText

### 2. Surface 配置问题
WGPU surface 可能没有正确连接到 CAMetalLayer

**检查**: Layer 类型是否正确

### 3. 背景色问题
Sugarloaf 默认背景可能是黑色，内容也是黑色

**解决方案**: 设置背景色或使用鲜艳颜色测试

### 4. Redraw 触发问题
Metal layer 的 contents 可能没有自动更新

**解决方案**: 手动触发 setNeedsDisplay

## 下一步测试

### 测试 1: 使用 Quad 渲染彩色矩形

需要添加 FFI:
```rust
#[no_mangle]
pub extern "C" fn sugarloaf_add_quad(
    handle: *mut SugarloafHandle,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
) {
    // 添加 Quad
}
```

### 测试 2: 查看 layer.contents
检查 CAMetalLayer.contents 是否有值

### 测试 3: 强制 present
确保 WGPU present 被调用

##  Rio 的做法

Rio 使用 Winit 创建窗口，Winit 会：
1. 创建 NSWindow
2. 创建 NSView
3. 设置 view 为 layer-backed
4. **Winit 自动配置 CAMetalLayer**
5. 将 view 指针传递给 raw-window-handle

我们的做法：
1. SwiftUI 创建窗口 ✅
2. 我们创建 SugarloafNSView ✅
3. 设置为 layer-backed ✅
4. **让 WGPU 自动创建 layer** ✅
5. 传递 view 指针 ✅

理论上应该能工作！

## 可能的关键差异

Rio 使用的 raw-window-handle 可能有特殊的初始化流程。

让我们检查 WGPU 创建 surface 时是否有错误。
