use crate::font_context::FontContext;

/// Font metrics in physical pixels.
///
/// cell_width and cell_height are rounded to integer pixels
/// to prevent sub-pixel misalignment between adjacent cells.
#[derive(Debug, Clone, Copy)]
pub struct FontMetrics {
    pub cell_width: f32,
    pub cell_height: f32,
    pub baseline_offset: f32,
}

/// Compute font metrics from a font context and physical font size.
///
/// Implements the cell_width/cell_height rounding that ensures
/// pixel-perfect alignment on both macOS and iOS.
pub fn compute_font_metrics(
    physical_font_size: f32,
    font_context: &FontContext,
) -> FontMetrics {
    let primary_font = font_context.get_primary_font(physical_font_size);
    let (_, skia_metrics) = primary_font.metrics();

    let raw_cell_height = -skia_metrics.ascent + skia_metrics.descent + skia_metrics.leading;
    let cell_height = raw_cell_height.round();

    let (raw_cell_width, _) = primary_font.measure_str("M", None);
    let cell_width = raw_cell_width.round();

    let baseline_offset = -skia_metrics.ascent;

    FontMetrics { cell_width, cell_height, baseline_offset }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sugarloaf::font::{FontLibrary, fonts::SugarloafFonts};

    #[test]
    fn test_compute_font_metrics() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);

        let metrics = compute_font_metrics(28.0, &font_context);

        assert!(metrics.cell_width > 0.0);
        assert!(metrics.cell_height > 0.0);
        assert!(metrics.baseline_offset > 0.0);

        // cell_width and cell_height should be rounded to integer pixels
        assert_eq!(metrics.cell_width, metrics.cell_width.round());
        assert_eq!(metrics.cell_height, metrics.cell_height.round());
    }
}
