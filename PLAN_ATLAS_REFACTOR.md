# ETerm Atlas Rendering Architecture

## 1. 背景与目标

### 当前问题
- **内存占用过高**：8 终端 = 3.2GB（每终端 ~400MB）
- **LineCache 架构**：每行每状态存储完整 `skia_safe::Image`
- **Resize 性能差**：需清空所有缓存重建

### 改造目标
- **内存优化**：8 终端降至 ~100-150MB（95%+ 减少）
- **保持 Skia 渲染质量**：不降级到 WGPU
- **Resize 优化**：保留 Atlas，无需重建

---

## 2. 核心架构

### 2.1 架构对比

```
改造前（LineCache）：
终端 1-8 ──> 独立 LineCache (400MB/终端) ──> 总计 3.2GB

改造后（GlyphAtlas）：
终端 1-8 ──> 共享 GlyphAtlas (32MB) + LayoutCache (5MB/终端)
          ──> 总计 ~100MB
```

### 2.2 核心数据结构

```rust
// rio/sugarloaf-ffi/src/render/cache/glyph_atlas.rs

/// 字形 Atlas（所有终端共享）
pub struct GlyphAtlas {
    /// Atlas Surface（CPU 光栅化）
    surface: skia_safe::Surface,

    /// 缓存的 Image snapshot（dirty flag 机制）
    cached_image: Option<skia_safe::Image>,
    dirty: bool,

    /// 字形分配器
    allocator: AtlasAllocator,

    /// 字形位置映射
    glyph_map: HashMap<GlyphKey, AtlasRegion>,
}

/// 字形键（针对终端场景简化）
#[derive(Hash, Eq, PartialEq, Clone, Copy)]
pub struct GlyphKey {
    pub glyph_id: u16,
    pub font_index: u16,
    pub size: u16,        // 物理尺寸（已含 DPI）
    pub flags: u8,        // bold/italic/synthetic
}

/// Atlas 区域
#[derive(Clone, Copy)]
pub struct AtlasRegion {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}
```

### 2.3 改造后的 LineCache

```rust
// rio/sugarloaf-ffi/src/render/cache/line_cache.rs

pub struct LineCache {
    /// 保留：布局缓存（~5MB/终端）
    layout_cache: LruCache<u64, GlyphLayout>,

    /// 新增：共享 Atlas 引用
    atlas: Arc<Mutex<GlyphAtlas>>,

    // 删除：renders: LruCache<u64, Image>
}
```

---

## 3. 渲染流程

```rust
fn render_line(&mut self, line: usize, state: &TerminalState) -> Image {
    let text_hash = compute_text_hash(line, state);

    // 1. 获取或计算布局
    let layout = match self.layout_cache.get(&text_hash) {
        Some(l) => l.clone(),
        None => {
            let l = self.shape_line(line, state);
            self.layout_cache.put(text_hash, l.clone());
            l
        }
    };

    // 2. 创建行 Surface
    let mut surface = Surface::new_raster_n32_premul((line_width, line_height));
    let canvas = surface.canvas();
    canvas.clear(background_color);

    // 3. 从 Atlas 组合字形
    let atlas = self.atlas.lock().unwrap();
    let atlas_image = atlas.get_image();  // dirty flag，不每次 snapshot

    for glyph in &layout.glyphs {
        let key = GlyphKey::from_glyph(glyph, font_size);

        if let Some(region) = atlas.get(&key) {
            canvas.draw_image_rect(
                atlas_image,
                region.to_src_rect(),
                glyph.target_rect(),
                &paint,
            );
        }
    }

    // 4. 绘制动态元素（光标、选区、搜索）
    self.draw_cursor(canvas, &layout, cursor_info);
    self.draw_selection(canvas, &layout, selection_info);

    surface.image_snapshot()
}
```

---

## 4. GlyphAtlas 实现

```rust
impl GlyphAtlas {
    const ATLAS_SIZE: i32 = 2048;

    pub fn new() -> Self {
        let surface = Surface::new_raster_n32_premul((Self::ATLAS_SIZE, Self::ATLAS_SIZE))
            .expect("Failed to create atlas surface");

        Self {
            surface,
            cached_image: None,
            dirty: true,
            allocator: AtlasAllocator::new(Self::ATLAS_SIZE as u16),
            glyph_map: HashMap::new(),
        }
    }

    /// 获取 Atlas Image（dirty flag 机制）
    pub fn get_image(&mut self) -> &skia_safe::Image {
        if self.dirty || self.cached_image.is_none() {
            self.cached_image = Some(self.surface.image_snapshot());
            self.dirty = false;
        }
        self.cached_image.as_ref().unwrap()
    }

    /// 获取或光栅化字形
    pub fn get_or_rasterize<F>(&mut self, key: GlyphKey, rasterize: F) -> Option<AtlasRegion>
    where
        F: FnOnce() -> Option<GlyphBitmap>,
    {
        // 缓存命中
        if let Some(&region) = self.glyph_map.get(&key) {
            return Some(region);
        }

        // 光栅化字形
        let bitmap = rasterize()?;

        // 分配空间
        let (x, y) = match self.allocator.allocate(bitmap.width, bitmap.height) {
            Some(pos) => pos,
            None => {
                // Atlas 满了，清空重建
                self.clear();
                self.allocator.allocate(bitmap.width, bitmap.height)?
            }
        };

        // 写入 Atlas
        let canvas = self.surface.canvas();
        canvas.write_pixels(
            &bitmap.info,
            &bitmap.data,
            bitmap.row_bytes,
            (x as i32, y as i32),
        );
        self.dirty = true;

        let region = AtlasRegion { x, y, width: bitmap.width, height: bitmap.height };
        self.glyph_map.insert(key, region);

        Some(region)
    }

    fn clear(&mut self) {
        self.glyph_map.clear();
        self.allocator.clear();
        self.surface.canvas().clear(Color::TRANSPARENT);
        self.dirty = true;
    }
}
```

---

## 5. AtlasAllocator（从 Rio 移植）

```rust
// 直接复用 Rio 的 shelf-based allocator
// 源码：rio/sugarloaf/src/components/rich_text/image_cache/atlas.rs

pub struct AtlasAllocator {
    size: u16,
    shelves: Vec<Shelf>,
}

struct Shelf {
    y: u16,
    height: u16,
    cursor: u16,
}

impl AtlasAllocator {
    pub fn allocate(&mut self, width: u16, height: u16) -> Option<(u16, u16)> {
        // 1. 查找合适的 shelf
        for shelf in &mut self.shelves {
            if shelf.height >= height && shelf.cursor + width <= self.size {
                let x = shelf.cursor;
                shelf.cursor += width;
                return Some((x, shelf.y));
            }
        }

        // 2. 创建新 shelf
        let y = self.shelves.last().map(|s| s.y + s.height).unwrap_or(0);
        if y + height <= self.size {
            self.shelves.push(Shelf { y, height, cursor: width });
            return Some((0, y));
        }

        None  // Atlas 满了
    }
}
```

---

## 6. 内存分析

| 组件 | LineCache | Atlas | 说明 |
|------|----------|-------|------|
| 布局缓存 | 5 MB/终端 | 5 MB/终端 | 不变 |
| 渲染缓存 | 400 MB/终端 | 0 | **消除** |
| 字形纹理 | - | 32 MB（共享） | 2048×2048 RGBA |
| **8 终端** | **3.2 GB** | **~100 MB** | **-97%** |

### 容量估算
- Atlas 尺寸：2048×2048 = 16MB（RGBA）
- 平均字形：20×30 像素
- 容量：~5000 个唯一字形（含碎片）
- 实际需求：ASCII + 常用汉字 ≈ 2000 字形
- **结论**：单个 Atlas 足够

---

## 7. 风险与应对

| 风险 | 影响 | 应对策略 |
|------|------|----------|
| Atlas 满溢 | 卡顿 | 清空重建 + 日志监控 |
| DPI 变化 | 字形失真 | 监听 DPI 事件，清空 Atlas |
| Color Emoji | 内存增加 | 初期统一 RGBA，后续可分离 |
| 并发访问 | 性能 | Arc<Mutex>，实测后决定是否优化 |
| 碎片化 | 利用率低 | Shelf allocator 已优化 |

---

## 8. 实施步骤

### Phase 1：Atlas 核心（2天）
- [ ] 创建 `glyph_atlas.rs`
- [ ] 移植 `AtlasAllocator`
- [ ] 实现 `get_or_rasterize()`
- [ ] 单元测试

### Phase 2：字形光栅化（1天）
- [ ] 创建 `GlyphRasterizer`
- [ ] 提取单字形绘制逻辑
- [ ] 处理 Box-drawing 字符

### Phase 3：改造 LineCache（1天）
- [ ] 删除 `renders` 字段
- [ ] 添加 `atlas` 引用
- [ ] 修改 API

### Phase 4：改造 Renderer（2天）
- [ ] 修改 `render_with_layout()`
- [ ] 逐字形组合绘制
- [ ] 处理光标/选区/搜索

### Phase 5：测试（1天）
- [ ] 单元测试
- [ ] 内存测试（8终端）
- [ ] 渲染对比测试

---

## 9. 验收标准

### 功能
- [ ] 所有现有测试通过
- [ ] 渲染效果与 LineCache 一致
- [ ] Color Emoji 正常显示

### 性能
- [ ] 8 终端内存 < 150 MB
- [ ] Resize 无明显卡顿
- [ ] 首帧渲染 < 16ms

---

## 10. 设计决策

### 采用
- ✅ CPU Surface（稳定，跨平台一致）
- ✅ 简化 GlyphKey（针对终端场景）
- ✅ Arc<Mutex>（简单，后续可优化）
- ✅ 统一 RGBA Atlas（简单，Emoji 少）
- ✅ Dirty flag snapshot（避免频繁生成 Image）

### 不采用
- ❌ GPU Surface（复杂，后续单独设计）
- ❌ 二级行缓存（违背 Atlas 初衷）
- ❌ 复杂 batching（过早优化）
- ❌ Variable Fonts（需求不明确）
- ❌ Subpixel positioning（等宽终端不需要）
