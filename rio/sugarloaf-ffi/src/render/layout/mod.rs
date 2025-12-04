#[cfg(feature = "new_architecture")]
mod glyph;

#[cfg(feature = "new_architecture")]
mod text_shaper;

#[cfg(feature = "new_architecture")]
pub use glyph::GlyphInfo;

#[cfg(feature = "new_architecture")]
pub use text_shaper::TextShaper;
