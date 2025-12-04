use crate::domain::{AbsolutePoint, ScreenPoint};

/// 渲染上下文（坐标转换 + 配置）
pub struct RenderContext {
    /// 当前显示偏移（滚动位置）
    pub display_offset: usize,
    /// 屏幕可见行数
    pub screen_rows: usize,
    /// 屏幕可见列数
    pub screen_cols: usize,
}

impl RenderContext {
    pub fn new(display_offset: usize, screen_rows: usize, screen_cols: usize) -> Self {
        Self {
            display_offset,
            screen_rows,
            screen_cols,
        }
    }

    /// 将绝对坐标转换为屏幕坐标
    pub fn to_screen_point(&self, point: AbsolutePoint) -> Option<ScreenPoint> {
        if !self.is_visible(point.line) {
            return None;
        }

        let screen_line = point.line.checked_sub(self.display_offset)?;
        if screen_line >= self.screen_rows {
            return None;
        }

        if point.col >= self.screen_cols {
            return None;
        }

        Some(ScreenPoint::new(screen_line, point.col))
    }

    /// 判断绝对行号是否在可见区域
    pub fn is_visible(&self, absolute_line: usize) -> bool {
        absolute_line >= self.display_offset
            && absolute_line < self.display_offset + self.screen_rows
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_coordinate_conversion() {
        let ctx = RenderContext::new(100, 24, 80);

        // 可见区域第一行
        let point = AbsolutePoint::new(100, 0);
        let screen = ctx.to_screen_point(point).unwrap();
        assert_eq!(screen.line, 0);
        assert_eq!(screen.col, 0);

        // 可见区域最后一行
        let point = AbsolutePoint::new(123, 79);
        let screen = ctx.to_screen_point(point).unwrap();
        assert_eq!(screen.line, 23);
        assert_eq!(screen.col, 79);

        // 可见区域中间
        let point = AbsolutePoint::new(110, 40);
        let screen = ctx.to_screen_point(point).unwrap();
        assert_eq!(screen.line, 10);
        assert_eq!(screen.col, 40);
    }

    #[test]
    fn test_coordinate_conversion_out_of_bounds() {
        let ctx = RenderContext::new(100, 24, 80);

        // 超出列范围
        let point = AbsolutePoint::new(100, 80);
        assert!(ctx.to_screen_point(point).is_none());

        // 在显示区域之前
        let point = AbsolutePoint::new(99, 0);
        assert!(ctx.to_screen_point(point).is_none());

        // 在显示区域之后
        let point = AbsolutePoint::new(124, 0);
        assert!(ctx.to_screen_point(point).is_none());
    }

    #[test]
    fn test_visibility_check() {
        let ctx = RenderContext::new(100, 24, 80);

        // 可见区域内
        assert!(ctx.is_visible(100));
        assert!(ctx.is_visible(110));
        assert!(ctx.is_visible(123));

        // 可见区域外
        assert!(!ctx.is_visible(99));
        assert!(!ctx.is_visible(124));
        assert!(!ctx.is_visible(0));
        assert!(!ctx.is_visible(200));
    }

    #[test]
    fn test_zero_offset() {
        let ctx = RenderContext::new(0, 24, 80);

        let point = AbsolutePoint::new(0, 0);
        let screen = ctx.to_screen_point(point).unwrap();
        assert_eq!(screen.line, 0);
        assert_eq!(screen.col, 0);

        assert!(ctx.is_visible(0));
        assert!(ctx.is_visible(23));
        assert!(!ctx.is_visible(24));
    }
}
