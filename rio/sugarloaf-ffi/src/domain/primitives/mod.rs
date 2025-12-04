#[cfg(feature = "new_architecture")]
pub mod point;

#[cfg(feature = "new_architecture")]
pub use point::{GridPoint, Absolute, AbsolutePoint, Screen, ScreenPoint};
