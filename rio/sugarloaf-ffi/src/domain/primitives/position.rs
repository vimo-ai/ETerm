use super::pixels::{Pixels, Logical, Physical, LogicalPixels, PhysicalPixels};

/// 位置值对象（x + y）
///
/// 使用 Phantom Type 在编译期区分位置类型：
/// - `Position<Logical>`: 逻辑位置（设备无关）
/// - `Position<Physical>`: 物理位置（设备物理像素）
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Position<Space> {
    pub x: Pixels<Space>,
    pub y: Pixels<Space>,
}

pub type LogicalPosition = Position<Logical>;
pub type PhysicalPosition = Position<Physical>;

impl<T> Position<T> {
    pub fn new(x: Pixels<T>, y: Pixels<T>) -> Self {
        Self { x, y }
    }

    /// 转换为数组（用于 FFI 或 Skia API）
    pub fn as_array(&self) -> [f32; 2] {
        [self.x.value, self.y.value]
    }
}

impl PhysicalPosition {
    pub fn to_logical(self, scale: f32) -> LogicalPosition {
        LogicalPosition::new(
            self.x.to_logical(scale),
            self.y.to_logical(scale),
        )
    }
}

impl LogicalPosition {
    pub fn to_physical(self, scale: f32) -> PhysicalPosition {
        PhysicalPosition::new(
            self.x.to_physical(scale),
            self.y.to_physical(scale),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_position_conversion() {
        let logical = LogicalPosition::new(
            LogicalPixels::new(100.0),
            LogicalPixels::new(50.0),
        );
        let physical = logical.to_physical(2.0);
        assert_eq!(physical.x.value, 200.0);
        assert_eq!(physical.y.value, 100.0);
    }

    #[test]
    fn test_as_array() {
        let pos = LogicalPosition::new(
            LogicalPixels::new(10.0),
            LogicalPixels::new(20.0),
        );
        let arr = pos.as_array();
        assert_eq!(arr, [10.0, 20.0]);
    }

    #[test]
    fn test_position_round_trip() {
        let original = LogicalPosition::new(
            LogicalPixels::new(100.0),
            LogicalPixels::new(50.0),
        );
        let physical = original.to_physical(2.0);
        let back = physical.to_logical(2.0);
        assert_eq!(original.x.value, back.x.value);
        assert_eq!(original.y.value, back.y.value);
    }
}
