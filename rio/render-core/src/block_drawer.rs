//! Block Elements Drawing (U+2580-U+259F)

use skia_safe::{Canvas, Color4f, Paint, Rect};

pub struct BlockDrawer {
    enabled: bool,
}

impl BlockDrawer {
    pub fn new() -> Self {
        Self { enabled: true }
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

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

        let left = x.round();
        let top = y.round();
        let right = (x + width).round();
        let bottom = (y + height).round();

        let x = left;
        let y = top;
        let width = right - left;
        let height = bottom - top;

        let mut paint = Paint::default();
        paint.set_anti_alias(false);
        paint.set_color4f(color, None);

        match ch {
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

            '▏' => self.draw_left_block(canvas, x, y, width, height, 1.0 / 8.0, &paint),
            '▎' => self.draw_left_block(canvas, x, y, width, height, 2.0 / 8.0, &paint),
            '▍' => self.draw_left_block(canvas, x, y, width, height, 3.0 / 8.0, &paint),
            '▌' => self.draw_left_block(canvas, x, y, width, height, 4.0 / 8.0, &paint),
            '▋' => self.draw_left_block(canvas, x, y, width, height, 5.0 / 8.0, &paint),
            '▊' => self.draw_left_block(canvas, x, y, width, height, 6.0 / 8.0, &paint),
            '▉' => self.draw_left_block(canvas, x, y, width, height, 7.0 / 8.0, &paint),
            '▐' => self.draw_right_block(canvas, x, y, width, height, 4.0 / 8.0, &paint),
            '▕' => self.draw_right_block(canvas, x, y, width, height, 1.0 / 8.0, &paint),

            '░' => self.draw_shade(canvas, x, y, width, height, 0.25, scale, &paint),
            '▒' => self.draw_shade(canvas, x, y, width, height, 0.50, scale, &paint),
            '▓' => self.draw_shade(canvas, x, y, width, height, 0.75, scale, &paint),

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

    #[inline]
    fn draw_full_block(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        canvas.draw_rect(Rect::from_xywh(x, y, w, h), paint);
    }

    #[inline]
    fn draw_lower_block(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, ratio: f32, paint: &Paint) {
        let block_h = (h * ratio).round();
        let block_y = y + h - block_h;
        canvas.draw_rect(Rect::from_xywh(x, block_y, w, block_h), paint);
    }

    #[inline]
    fn draw_upper_block(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, ratio: f32, paint: &Paint) {
        let block_h = (h * ratio).round();
        canvas.draw_rect(Rect::from_xywh(x, y, w, block_h), paint);
    }

    #[inline]
    fn draw_left_block(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, ratio: f32, paint: &Paint) {
        let block_w = (w * ratio).round();
        canvas.draw_rect(Rect::from_xywh(x, y, block_w, h), paint);
    }

    #[inline]
    fn draw_right_block(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, ratio: f32, paint: &Paint) {
        let left_w = (w * (1.0 - ratio)).round();
        let block_w = w - left_w;
        canvas.draw_rect(Rect::from_xywh(x + left_w, y, block_w, h), paint);
    }

    fn draw_shade(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, density: f32, _scale: f32, paint: &Paint) {
        let mut shade_paint = paint.clone();
        let color = paint.color4f();
        shade_paint.set_color4f(Color4f::new(color.r, color.g, color.b, color.a * density), None);
        canvas.draw_rect(Rect::from_xywh(x, y, w, h), &shade_paint);
    }

    #[inline]
    fn quadrant_splits(&self, w: f32, h: f32) -> (f32, f32, f32, f32) {
        let left_w = (w / 2.0).round();
        let top_h = (h / 2.0).round();
        let right_w = w - left_w;
        let bottom_h = h - top_h;
        (left_w, right_w, top_h, bottom_h)
    }

    #[inline]
    fn draw_quadrant_ul(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let (left_w, _, top_h, _) = self.quadrant_splits(w, h);
        canvas.draw_rect(Rect::from_xywh(x, y, left_w, top_h), paint);
    }

    #[inline]
    fn draw_quadrant_ur(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let (left_w, right_w, top_h, _) = self.quadrant_splits(w, h);
        canvas.draw_rect(Rect::from_xywh(x + left_w, y, right_w, top_h), paint);
    }

    #[inline]
    fn draw_quadrant_ll(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let (left_w, _, top_h, bottom_h) = self.quadrant_splits(w, h);
        canvas.draw_rect(Rect::from_xywh(x, y + top_h, left_w, bottom_h), paint);
    }

    #[inline]
    fn draw_quadrant_lr(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, paint: &Paint) {
        let (left_w, right_w, top_h, bottom_h) = self.quadrant_splits(w, h);
        canvas.draw_rect(Rect::from_xywh(x + left_w, y + top_h, right_w, bottom_h), paint);
    }

    #[inline]
    fn draw_quadrants(&self, canvas: &Canvas, x: f32, y: f32, w: f32, h: f32, ul: bool, ur: bool, ll: bool, lr: bool, paint: &Paint) {
        if ul { self.draw_quadrant_ul(canvas, x, y, w, h, paint); }
        if ur { self.draw_quadrant_ur(canvas, x, y, w, h, paint); }
        if ll { self.draw_quadrant_ll(canvas, x, y, w, h, paint); }
        if lr { self.draw_quadrant_lr(canvas, x, y, w, h, paint); }
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

    const TEST_SCALE: f32 = 2.0;

    fn create_test_surface() -> skia_safe::Surface {
        surfaces::raster_n32_premul((100, 100)).expect("Failed to create surface")
    }

    #[test]
    fn test_draw_full_block() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        assert!(drawer.draw(canvas, '█', 0.0, 0.0, 10.0, 20.0, Color4f::new(1.0, 1.0, 1.0, 1.0), TEST_SCALE));
    }

    #[test]
    fn test_non_block_char_returns_false() {
        let drawer = BlockDrawer::new();
        let mut surface = create_test_surface();
        let canvas = surface.canvas();
        assert!(!drawer.draw(canvas, 'A', 0.0, 0.0, 10.0, 20.0, Color4f::new(1.0, 1.0, 1.0, 1.0), TEST_SCALE));
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

        let all_blocks: Vec<char> = (0x2580u32..=0x259Fu32)
            .filter_map(char::from_u32)
            .collect();

        assert_eq!(all_blocks.len(), 32);
        for ch in all_blocks {
            assert!(drawer.draw(canvas, ch, 0.0, 0.0, 10.0, 20.0, color, TEST_SCALE));
        }
    }
}
