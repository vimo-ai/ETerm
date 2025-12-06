#[cfg(feature = "new_architecture")]
pub mod grid;
#[cfg(feature = "new_architecture")]
pub mod cursor;
#[cfg(feature = "new_architecture")]
pub mod selection;
#[cfg(feature = "new_architecture")]
pub mod search;

#[cfg(feature = "new_architecture")]
pub use grid::{GridView, RowView, GridData};
#[cfg(feature = "new_architecture")]
pub use cursor::CursorView;
#[cfg(feature = "new_architecture")]
pub use selection::{SelectionView, SelectionType};
#[cfg(feature = "new_architecture")]
pub use search::{SearchView, MatchRange};
