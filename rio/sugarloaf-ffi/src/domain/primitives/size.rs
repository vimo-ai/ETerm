use super::pixels::{Pixels, Logical, Physical};

/// 尺寸值对象（width + height）
///
/// 使用 Phantom Type 在编译期区分尺寸类型：
/// - `Size<Logical>`: 逻辑尺寸（设备无关）
/// - `Size<Physical>`: 物理尺寸（设备物理像素）
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Size<Space> {
    pub width: Pixels<Space>,
    pub height: Pixels<Space>,
}

pub type LogicalSize = Size<Logical>;
pub type PhysicalSize = Size<Physical>;

impl<T> Size<T> {
    pub fn new(width: Pixels<T>, height: Pixels<T>) -> Self {
        Self { width, height }
    }
}

impl PhysicalSize {
    pub fn to_logical(self, scale: f32) -> LogicalSize {
        LogicalSize::new(
            self.width.to_logical(scale),
            self.height.to_logical(scale),
        )
    }
}

impl LogicalSize {
    pub fn to_physical(self, scale: f32) -> PhysicalSize {
        PhysicalSize::new(
            self.width.to_physical(scale),
            self.height.to_physical(scale),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::super::pixels::LogicalPixels;

    #[test]
    fn test_size_conversion() {
        let logical = LogicalSize::new(
            LogicalPixels::new(800.0),
            LogicalPixels::new(600.0),
        );
        let physical = logical.to_physical(2.0);
        assert_eq!(physical.width.value, 1600.0);
        assert_eq!(physical.height.value, 1200.0);
    }

    #[test]
    fn test_size_round_trip() {
        let original = LogicalSize::new(
            LogicalPixels::new(800.0),
            LogicalPixels::new(600.0),
        );
        let physical = original.to_physical(2.0);
        let back = physical.to_logical(2.0);
        assert_eq!(original.width.value, back.width.value);
        assert_eq!(original.height.value, back.height.value);
    }
}
