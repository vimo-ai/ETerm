use std::marker::PhantomData;
use std::ops::{Add, Sub, Mul, Div};

/// 逻辑像素空间标记（设备无关像素）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Logical;

/// 物理像素空间标记（设备物理像素）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Physical;

/// 像素值对象（零开销抽象，使用 Phantom Type）
///
/// 使用 Phantom Type 在编译期区分像素类型：
/// - `Pixels<Logical>`: 逻辑像素（设备无关）
/// - `Pixels<Physical>`: 物理像素（设备物理像素）
///
/// # 零开销抽象
///
/// `PhantomData<Space>` 在编译期存在，运行时不占用内存。
/// `Pixels<Logical>` 和 `Pixels<Physical>` 的内存布局完全相同。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pixels<Space> {
    pub value: f32,
    _marker: PhantomData<Space>,
}

pub type LogicalPixels = Pixels<Logical>;
pub type PhysicalPixels = Pixels<Physical>;

impl<T> Pixels<T> {
    #[inline]
    pub const fn new(value: f32) -> Self {
        Self {
            value,
            _marker: PhantomData,
        }
    }
}

// 同坐标系内的算术运算
impl<T> Add for Pixels<T> {
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        Self::new(self.value + rhs.value)
    }
}

impl<T> Sub for Pixels<T> {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self {
        Self::new(self.value - rhs.value)
    }
}

impl<T> Mul<f32> for Pixels<T> {
    type Output = Self;
    fn mul(self, rhs: f32) -> Self {
        Self::new(self.value * rhs)
    }
}

impl<T> Div<f32> for Pixels<T> {
    type Output = Self;
    fn div(self, rhs: f32) -> Self {
        Self::new(self.value / rhs)
    }
}

// 跨坐标系转换（需要 scale 参数）
impl PhysicalPixels {
    pub fn to_logical(self, scale: f32) -> LogicalPixels {
        LogicalPixels::new(self.value / scale)
    }
}

impl LogicalPixels {
    pub fn to_physical(self, scale: f32) -> PhysicalPixels {
        PhysicalPixels::new(self.value * scale)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_logical_to_physical() {
        let logical = LogicalPixels::new(14.0);
        let physical = logical.to_physical(2.0);
        assert_eq!(physical.value, 28.0);
    }

    #[test]
    fn test_physical_to_logical() {
        let physical = PhysicalPixels::new(28.0);
        let logical = physical.to_logical(2.0);
        assert_eq!(logical.value, 14.0);
    }

    #[test]
    fn test_round_trip() {
        let original = LogicalPixels::new(14.0);
        let physical = original.to_physical(2.0);
        let back = physical.to_logical(2.0);
        assert_eq!(original.value, back.value);
    }

    #[test]
    fn test_arithmetic() {
        let a = LogicalPixels::new(10.0);
        let b = LogicalPixels::new(5.0);
        assert_eq!((a + b).value, 15.0);
        assert_eq!((a - b).value, 5.0);
        assert_eq!((a * 2.0).value, 20.0);
    }
}
