//! Block Elements Drawing (U+2580-U+259F)
//!
//! 自定义绘制 32 个 Block Elements 字符，确保像素级精确对齐。
//!
//! ## 字符列表
//!
//! | Code   | Char | Name                    | Drawing          |
//! |--------|------|-------------------------|------------------|
//! | U+2580 | ▀    | Upper Half Block        | top 50%          |
//! | U+2581 | ▁    | Lower 1/8 Block         | bottom 12.5%     |
//! | U+2582 | ▂    | Lower 1/4 Block         | bottom 25%       |
//! | U+2583 | ▃    | Lower 3/8 Block         | bottom 37.5%     |
//! | U+2584 | ▄    | Lower Half Block        | bottom 50%       |
//! | U+2585 | ▅    | Lower 5/8 Block         | bottom 62.5%     |
//! | U+2586 | ▆    | Lower 3/4 Block         | bottom 75%       |
//! | U+2587 | ▇    | Lower 7/8 Block         | bottom 87.5%     |
//! | U+2588 | █    | Full Block              | 100%             |
//! | U+2589 | ▉    | Left 7/8 Block          | left 87.5%       |
//! | U+258A | ▊    | Left 3/4 Block          | left 75%         |
//! | U+258B | ▋    | Left 5/8 Block          | left 62.5%       |
//! | U+258C | ▌    | Left Half Block         | left 50%         |
//! | U+258D | ▍    | Left 3/8 Block          | left 37.5%       |
//! | U+258E | ▎    | Left 1/4 Block          | left 25%         |
//! | U+258F | ▏    | Left 1/8 Block          | left 12.5%       |
//! | U+2590 | ▐    | Right Half Block        | right 50%        |
//! | U+2591 | ░    | Light Shade             | 25% pattern      |
//! | U+2592 | ▒    | Medium Shade            | 50% pattern      |
//! | U+2593 | ▓    | Dark Shade              | 75% pattern      |
//! | U+2594 | ▔    | Upper 1/8 Block         | top 12.5%        |
//! | U+2595 | ▕    | Right 1/8 Block         | right 12.5%      |
//! | U+2596 | ▖    | Quadrant Lower Left     | LL               |
//! | U+2597 | ▗    | Quadrant Lower Right    | LR               |
//! | U+2598 | ▘    | Quadrant Upper Left     | UL               |
//! | U+2599 | ▙    | Quadrant UL+LL+LR       | UL+LL+LR         |
//! | U+259A | ▚    | Quadrant UL+LR          | UL+LR (diagonal) |
//! | U+259B | ▛    | Quadrant UL+UR+LL       | UL+UR+LL         |
//! | U+259C | ▜    | Quadrant UL+UR+LR       | UL+UR+LR         |
//! | U+259D | ▝    | Quadrant Upper Right    | UR               |
//! | U+259E | ▞    | Quadrant UR+LL          | UR+LL (diagonal) |
//! | U+259F | ▟    | Quadrant UR+LL+LR       | UR+LL+LR         |

use skia_safe::{Canvas, Color4f, Paint, Rect};

/// Block Elements 绘制器
pub struct BlockDrawer {
    /// 是否启用（可通过配置关闭）
    enabled: bool,
}

impl BlockDrawer {
    pub fn new() -> Self {
        Self { enabled: true }
    }

    /// 设置是否启用
    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    /// 是否启用
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// 绘制 Block Element 字符
    ///
    /// # 参数
    /// - `canvas`: Skia 画布
    /// - `ch`: 要绘制的字符
    /// - `x`: 左上角 x 坐标
    /// - `y`: 左上角 y 坐标
    /// - `width`: cell 宽度
    /// - `height`: cell 高度（应该是 line_height，不是 cell_height）
    /// - `color`: 前景色
    /// - `scale`: DPI 缩放因子（用于阴影点阵密度）
    ///
    /// # 返回
    /// - `true`: 成功绘制
    /// - `false`: 不是 Block Element 字符或未启用
    pub fn draw(
        &self,
        canvas: &Canvas,
        ch: char,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        color: Color4f,
        scale: f32,
    ) -> bool {
        if !self.enabled {
            return false;
        }

        // 🎯 关键修复：坐标对齐到整数像素边界
        // 问题：glyph.x 是浮点数（如 8.4, 16.8），即使关闭抗锯齿，
        // 浮点坐标也会导致相邻 cell 的边界不重合，产生缝隙。
        //
        // 解决方案：确保当前 cell 的右边界 = 下一个 cell 的左边界
        // 例如：cell1 在 x=8.4, width=8.4
        //       left = round(8.4) = 8
        //       right = round(8.4 + 8.4) = round(16.8) = 17
        //       cell2 在 x=16.8 → left = round(16.8) = 17（与 cell1 右边界重合！）
        let left = x.round();
        let top = y.round();
        let right = (x + width).round();
        let bottom = (y + height).round();

        let x = left;
        let y = top;
        let width = right - left;
        let height = bottom - top;

        // 创建 Paint（关闭抗锯齿，确保像素精确）
        let mut paint = Paint::default();
        paint.set_anti_alias(false); // 关键：关闭抗锯齿
        paint.set_color4f(color, None);

        match ch {
            // ===== 垂直分割（从下往上填充）=====
            '▁' => self.draw_lower_block(canvas, x, y, width, height, 1.0 / 8.0, &paint),
            '▂' => self.draw_lower_block(canvas, x, y, width, height, 2.0 / 8.0, &paint),
            '▃' => self.draw_lower_block(canvas, x, y, width, height, 3.0 / 8.0, &paint),
            '▄' => self.draw_lower_block(canvas, x, y, width, height, 4.0 / 8.0, &paint),
            '▅' => self.draw_lower_block(canvas, x, y, width, height, 5.0 / 8.0, &paint),
            '▆' => self.draw_lower_block(canvas, x, y, width, height, 6.0 / 8.0, &paint),
            '▇' => self.draw_lower_block(canvas, x, y, width, height, 7.0 / 8.0, &paint),
            '█' => self.draw_full_block(canvas, x, y, width, height, &paint),
            '▀' => self.draw_upper_block(canvas, x, y, width, height, 4.0 / 8.0, &paint),
            '▔' => self.draw_upper_block(canvas, x, y, width, height, 1.0 / 8.0, &paint),

            // ===== 水平分割（从左往右填充）=====
            '▏' => self.draw_left_block(canvas, x, y, width, height, 1.0 / 8.0, &paint),
            '▎' => self.draw_left_block(canvas, x, y, width, height, 2.0 / 8.0, &paint),
            '▍' => self.draw_left_block(canvas, x, y, width, height, 3.0 / 8.0, &paint),
            '▌' => self.draw_left_block(canvas, x, y, width, height, 4.0 / 8.0, &paint),
            '▋' => self.draw_left_block(canvas, x, y, width, height, 5.0 / 8.0, &paint),
            '▊' => self.draw_left_block(canvas, x, y, width, height, 6.0 / 8.0, &paint),
            '▉' => self.draw_left_block(canvas, x, y, width, height, 7.0 / 8.0, &paint),
            '▐' => self.draw_right_block(canvas, x, y, width, height, 4.0 / 8.0, &paint),
            '▕' => self.draw_right_block(canvas, x, y, width, height, 1.0 / 8.0, &paint),

            // ===== 阴影（点阵 pattern）=====
            '░' => self.draw_shade(canvas, x, y, width, height, 0.25, scale, &paint),
            '▒' => self.draw_shade(canvas, x, y, width, height, 0.50, scale, &paint),
            '▓' => self.draw_shade(canvas, x, y, width, height, 0.75, scale, &paint),

            // ===== 象限 =====
            '▖' => self.draw_quadrant_ll(canvas, x, y, width, height, &paint),
            '▗' => self.draw_quadrant_lr(canvas, x, y, width, height, &paint),
            '▘' => self.draw_quadrant_ul(canvas, x, y, width, height, &paint),
            '▝' => self.draw_quadrant_ur(canvas, x, y, width, height, &paint),
            '▙' => self.draw_quadrants(canvas, x, y, width, height, true, false, true, true, &paint),
            '▚' => self.draw_quadrants(canvas, x, y, width, height, true, false, false, true, &paint),
            '▛' => self.draw_quadrants(canvas, x, y, width, height, true, true, true, false, &paint),
            '▜' => self.draw_quadrants(canvas, x, y, width, height, true, true, false, true, &paint),
            '▞' => self.draw_quadrants(canvas, x, y, width, height, false, true, true, false, &paint),
            '▟' => self.draw_quadrants(canvas, x, y, width, height, false, true, true, true, &paint),

            _ => return false,
        }

        true
    }

    // ===== 内部绘制方法 =====

    /// 绘制完整填充
    #[inline]
    fn draw_full_block(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let rect = Rect::from_xywh(x, y, w, h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制下半部分（从底部向上 ratio 比例）
    #[inline]
    fn draw_lower_block(
        &self,
        canvas: &Canvas,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        ratio: f32,
        paint: &Paint,
    ) {
        // 计算分割点并 round 到整数像素
        let block_h = (h * ratio).round();
        let block_y = y + h - block_h;
        let rect = Rect::from_xywh(x, block_y, w, block_h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制上半部分（从顶部向下 ratio 比例）
    #[inline]
    fn draw_upper_block(
        &self,
        canvas: &Canvas,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        ratio: f32,
        paint: &Paint,
    ) {
        let block_h = (h * ratio).round();
        let rect = Rect::from_xywh(x, y, w, block_h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制左半部分（从左向右 ratio 比例）
    #[inline]
    fn draw_left_block(
        &self,
        canvas: &Canvas,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        ratio: f32,
        paint: &Paint,
    ) {
        let block_w = (w * ratio).round();
        let rect = Rect::from_xywh(x, y, block_w, h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制右半部分（从右向左 ratio 比例）
    #[inline]
    fn draw_right_block(
        &self,
        canvas: &Canvas,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        ratio: f32,
        paint: &Paint,
    ) {
        // 右半部分：从左半部分结束的地方开始，确保无缝衔接
        let left_w = (w * (1.0 - ratio)).round();
        let block_w = w - left_w;
        let rect = Rect::from_xywh(x + left_w, y, block_w, h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制阴影（alpha 半透明填充）
    ///
    /// - 25% (░): alpha × 0.25
    /// - 50% (▒): alpha × 0.50
    /// - 75% (▓): alpha × 0.75
    ///
    /// 高分屏下点阵无意义（2x2 物理像素一个点，肉眼就是色块），
    /// 直接用 alpha 混合：对齐无缝、单次 draw_rect、视觉更干净。
    fn draw_shade(
        &self,
        canvas: &Canvas,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        density: f32,
        _scale: f32,
        paint: &Paint,
    ) {
        let mut shade_paint = paint.clone();
        let color = paint.color4f();
        shade_paint.set_color4f(Color4f::new(color.r, color.g, color.b, color.a * density), None);
        let rect = Rect::from_xywh(x, y, w, h);
        canvas.draw_rect(rect, &shade_paint);
    }

    // ===== 象限绘制 =====

    /// 计算象限的分割点（确保像素对齐）
    #[inline]
    fn quadrant_splits(&self, w: f32, h: f32) -> (f32, f32, f32, f32) {
        // 左半宽度和上半高度（round 到整数）
        let left_w = (w / 2.0).round();
        let top_h = (h / 2.0).round();
        // 右半宽度和下半高度（确保总和等于原始值）
        let right_w = w - left_w;
        let bottom_h = h - top_h;
        (left_w, right_w, top_h, bottom_h)
    }

    /// 绘制左上象限
    #[inline]
    fn draw_quadrant_ul(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let (left_w, _, top_h, _) = self.quadrant_splits(w, h);
        let rect = Rect::from_xywh(x, y, left_w, top_h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制右上象限
    #[inline]
    fn draw_quadrant_ur(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let (left_w, right_w, top_h, _) = self.quadrant_splits(w, h);
        let rect = Rect::from_xywh(x + left_w, y, right_w, top_h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制左下象限
    #[inline]
    fn draw_quadrant_ll(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let (left_w, _, top_h, bottom_h) = self.quadrant_splits(w, h);
        let rect = Rect::from_xywh(x, y + top_h, left_w, bottom_h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制右下象限
    #[inline]
    fn draw_quadrant_lr(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let (left_w, right_w, top_h, bottom_h) = self.quadrant_splits(w, h);
        let rect = Rect::from_xywh(x + left_w, y + top_h, right_w, bottom_h);
        canvas.draw_rect(rect, paint);
    }

    /// 绘制多个象限组合
    #[inline]
    fn draw_quadrants(
        &self,
        canvas: &Canvas,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        ul: bool,
        ur: bool,
        ll: bool,
        lr: bool,
        paint: &Paint,
    ) {
        if ul {
            self.draw_quadrant_ul(canvas, x, y, w, h, paint);
        }
        if ur {
            self.draw_quadrant_ur(canvas, x, y, w, h, paint);
        }
        if ll {
            self.draw_quadrant_ll(canvas, x, y, w, h, paint);
        }
        if lr {
            self.draw_quadrant_lr(canvas, x, y, w, h, paint);
        }
    }
}

impl Default for BlockDrawer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skia_safe::surfaces;

    const TEST_SCALE: f32 = 2.0; // 模拟 Retina 显示器

    fn create_test_surface() -> skia_safe::Surface {
        surfaces::raster_n32_premul((100, 100)).expect("Failed to create surface")
    }

    #[test]
    fn test_draw_full_block() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        assert!(drawer.draw(canvas, '█', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
    }

    #[test]
    fn test_draw_half_blocks() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        // 上半
        assert!(drawer.draw(canvas, '▀', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        // 下半
        assert!(drawer.draw(canvas, '▄', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        // 左半
        assert!(drawer.draw(canvas, '▌', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        // 右半
        assert!(drawer.draw(canvas, '▐', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
    }

    #[test]
    fn test_draw_eighth_blocks() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        // 所有 1/8 到 7/8 的变体
        for ch in ['▁', '▂', '▃', '▄', '▅', '▆', '▇'] {
            assert!(drawer.draw(canvas, ch, 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE), "Failed for {}", ch);
        }

        for ch in ['▏', '▎', '▍', '▌', '▋', '▊', '▉'] {
            assert!(drawer.draw(canvas, ch, 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE), "Failed for {}", ch);
        }
    }

    #[test]
    fn test_draw_shades() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        assert!(drawer.draw(canvas, '░', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        assert!(drawer.draw(canvas, '▒', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        assert!(drawer.draw(canvas, '▓', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
    }

    #[test]
    fn test_draw_shades_low_dpi() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        // 低 DPI (scale=1.0) 也应该正常工作
        assert!(drawer.draw(canvas, '░', 0.0, 0.0, 10.0, 20.0, color, 1.0));
        assert!(drawer.draw(canvas, '▒', 0.0, 0.0, 10.0, 20.0, color, 1.0));
        assert!(drawer.draw(canvas, '▓', 0.0, 0.0, 10.0, 20.0, color, 1.0));
    }

    #[test]
    fn test_draw_quadrants() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        // 单象限
        for ch in ['▖', '▗', '▘', '▝'] {
            assert!(drawer.draw(canvas, ch, 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE), "Failed for {}", ch);
        }

        // 多象限组合
        for ch in ['▙', '▚', '▛', '▜', '▞', '▟'] {
            assert!(drawer.draw(canvas, ch, 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE), "Failed for {}", ch);
        }
    }

    #[test]
    fn test_draw_edge_blocks() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        // 上边和右边 1/8
        assert!(drawer.draw(canvas, '▔', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        assert!(drawer.draw(canvas, '▕', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
    }

    #[test]
    fn test_non_block_char_returns_false() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        assert!(!drawer.draw(canvas, 'A', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        assert!(!drawer.draw(canvas, '中', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        assert!(!drawer.draw(canvas, ' ', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
    }

    #[test]
    fn test_disabled_drawer() {
        let mut drawer = BlockDrawer::new();
        drawer.set_enabled(false);

        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        // 禁用后应该返回 false
        assert!(!drawer.draw(canvas, '█', 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
    }

    #[test]
    fn test_all_32_block_elements() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        let color = Color4f::new(1.0, 1.0, 1.0, 1.0);

        // U+2580 到 U+259F 共 32 个字符
        let all_blocks: Vec<char> = (0x2580u32..=0x259Fu32)
            .filter_map(char::from_u32)
            .collect();

        assert_eq!(all_blocks.len(), 32);

        for ch in all_blocks {
            assert!(
                drawer.draw(canvas, ch, 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE),
                "Failed to draw U+{:04X} '{}'",
                ch as u32,
                ch
            );
        }
    }
}
