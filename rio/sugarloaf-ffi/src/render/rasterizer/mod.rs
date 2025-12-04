#[cfg(feature = "new_architecture")]
mod line_rasterizer;

#[cfg(feature = "new_architecture")]
pub use line_rasterizer::LineRasterizer;
