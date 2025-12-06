use std::marker::PhantomData;

/// 绝对坐标标记（含历史缓冲区）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Absolute;

/// 屏幕坐标标记（当前可见区域）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Screen;

/// 网格坐标点（带坐标系标记）
///
/// 使用 Phantom Type 在编译期区分坐标类型：
/// - `GridPoint<Absolute>`: 绝对坐标（Grid 中的真实位置，含历史）
/// - `GridPoint<Screen>`: 屏幕坐标（当前可见区域的相对位置）
///
/// # 零开销抽象
///
/// `PhantomData<T>` 在编译期存在，运行时不占用内存。
/// `GridPoint<Absolute>` 和 `GridPoint<Screen>` 的内存布局完全相同。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GridPoint<T> {
    /// 行号（0-based）
    pub line: usize,
    /// 列号（0-based）
    pub col: usize,
    _marker: PhantomData<T>,
}

/// 绝对坐标点（含历史缓冲区）
pub type AbsolutePoint = GridPoint<Absolute>;

/// 屏幕坐标点（当前可见区域）
pub type ScreenPoint = GridPoint<Screen>;

impl<T> GridPoint<T> {
    /// 创建新的坐标点
    #[inline]
    pub fn new(line: usize, col: usize) -> Self {
        Self {
            line,
            col,
            _marker: PhantomData,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_absolute_point_construction() {
        let point = AbsolutePoint::new(100, 50);
        assert_eq!(point.line, 100);
        assert_eq!(point.col, 50);
    }

    #[test]
    fn test_screen_point_construction() {
        let point = ScreenPoint::new(20, 10);
        assert_eq!(point.line, 20);
        assert_eq!(point.col, 10);
    }

    #[test]
    fn test_absolute_point_equality() {
        let p1 = AbsolutePoint::new(10, 20);
        let p2 = AbsolutePoint::new(10, 20);
        let p3 = AbsolutePoint::new(10, 21);

        assert_eq!(p1, p2);
        assert_ne!(p1, p3);
    }

    // 验证编译期类型安全：以下代码应该无法编译
    // #[test]
    // fn test_type_safety() {
    //     let abs = AbsolutePoint::new(10, 20);
    //     let screen = ScreenPoint::new(5, 10);
    //     assert_eq!(abs, screen);  // 编译错误！
    // }
}
