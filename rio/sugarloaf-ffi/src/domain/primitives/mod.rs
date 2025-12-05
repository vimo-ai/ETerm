#[cfg(feature = "new_architecture")]
pub mod point;

#[cfg(feature = "new_architecture")]
pub mod pixels;

#[cfg(feature = "new_architecture")]
pub mod size;

#[cfg(feature = "new_architecture")]
pub mod position;

#[cfg(feature = "new_architecture")]
pub use point::{GridPoint, Absolute, AbsolutePoint, Screen, ScreenPoint};

#[cfg(feature = "new_architecture")]
pub use pixels::{Logical, Physical, Pixels, LogicalPixels, PhysicalPixels};

#[cfg(feature = "new_architecture")]
pub use size::{Size, LogicalSize, PhysicalSize};

#[cfg(feature = "new_architecture")]
pub use position::{Position, LogicalPosition, PhysicalPosition};
