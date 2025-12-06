//! Cursor View - Read-only Cursor Snapshot
//!
//! 设计要点：
//! - 简单的值对象
//! - 包含位置和形状信息
//! - 不可变
//!
//! 使用场景：
//! - 渲染光标
//! - 判断光标是否在选区内

use crate::domain::primitives::AbsolutePoint;
use rio_backend::ansi::CursorShape;

/// Cursor View - Read-only Cursor Snapshot
///
/// 设计要点：
/// - 简单的值对象
/// - 包含位置和形状信息
/// - 不可变
///
/// 使用场景：
/// - 渲染光标
/// - 判断光标是否在选区内
/// 光标颜色（RGBA）
pub type CursorColor = [f32; 4];

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CursorView {
    /// 光标位置（绝对坐标）
    pub position: AbsolutePoint,
    /// 光标形状
    pub shape: CursorShape,
    /// 光标颜色（RGBA）
    pub color: CursorColor,
}

/// 默认光标颜色（白色，80% 透明度）
pub const DEFAULT_CURSOR_COLOR: CursorColor = [1.0, 1.0, 1.0, 0.8];

impl CursorView {
    /// 创建新的 CursorView（使用默认颜色）
    pub fn new(position: AbsolutePoint, shape: CursorShape) -> Self {
        Self { position, shape, color: DEFAULT_CURSOR_COLOR }
    }

    /// 创建新的 CursorView（指定颜色）
    pub fn with_color(position: AbsolutePoint, shape: CursorShape, color: CursorColor) -> Self {
        Self { position, shape, color }
    }

    /// 判断光标是否可见
    #[inline]
    pub fn is_visible(&self) -> bool {
        self.shape != CursorShape::Hidden
    }

    /// 获取光标行号
    #[inline]
    pub fn line(&self) -> usize {
        self.position.line
    }

    /// 获取光标列号
    #[inline]
    pub fn col(&self) -> usize {
        self.position.col
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试：验证 CursorView 基本功能
    #[test]
    fn test_cursor_view_basic() {
        let position = AbsolutePoint::new(5, 10);
        let cursor = CursorView::new(position, CursorShape::Beam);

        // 验证基本属性
        assert_eq!(cursor.position, position);
        assert_eq!(cursor.shape, CursorShape::Beam);
        assert_eq!(cursor.line(), 5);
        assert_eq!(cursor.col(), 10);
        assert!(cursor.is_visible());
    }

    /// 测试：验证隐藏的光标
    #[test]
    fn test_cursor_view_hidden() {
        let cursor = CursorView::new(
            AbsolutePoint::new(0, 0),
            CursorShape::Hidden,
        );

        // 隐藏光标应该不可见
        assert!(!cursor.is_visible());
    }

    /// 测试：验证 CursorView 是 Copy 的（无需 Clone）
    #[test]
    fn test_cursor_view_copy() {
        let cursor1 = CursorView::new(
            AbsolutePoint::new(1, 2),
            CursorShape::Underline,
        );

        // Copy（不是 Clone）
        let cursor2 = cursor1;

        // 验证两个 cursor 相等
        assert_eq!(cursor1, cursor2);
    }
}
