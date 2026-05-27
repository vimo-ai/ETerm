
use sugarloaf::font::{FontLibrary, FontLibraryData};
use skia_safe::{FontMgr, FontStyle, Font, Typeface};
use std::sync::Arc;
use parking_lot::RwLock;
use std::collections::HashMap;
use std::cell::RefCell;

pub struct FontContext {
    font_library: Arc<RwLock<FontLibraryData>>,
    font_mgr: FontMgr,
    primary_font_typeface: Option<Typeface>,
    char_font_cache: RefCell<HashMap<char, (Typeface, bool)>>,
    typeface_cache: RefCell<HashMap<usize, Option<Typeface>>>,
}

impl FontContext {
    pub fn new(font_library: FontLibrary) -> Self {
        let font_mgr = FontMgr::new();

        let primary_font_typeface = {
            let lib = font_library.inner.read();
            if let Some((font_data, offset, _key)) = lib.get_data(&0) {
                let offset_usize = offset as usize;
                let font_bytes = &font_data[offset_usize..];
                let data = skia_safe::Data::new_copy(font_bytes);
                font_mgr.new_from_data(&data, None)
            } else {
                None
            }
        };

        Self {
            font_library: font_library.inner,
            font_mgr,
            primary_font_typeface,
            char_font_cache: RefCell::new(HashMap::new()),
            typeface_cache: RefCell::new(HashMap::new()),
        }
    }

    fn create_font_with_emoji_support(typeface: &Typeface, font_size: f32, _is_emoji: bool) -> Font {
        Font::from_typeface(typeface, font_size)
    }

    pub fn find_font_for_char(
        &self,
        ch: char,
        font_size: f32,
        styled_font: &Font,
    ) -> (Font, bool) {
        if (ch as u32) < 0x80 {
            return (styled_font.clone(), false);
        }

        let glyph_id = styled_font.unichar_to_glyph(ch as i32);
        if glyph_id != 0 {
            return (styled_font.clone(), false);
        }

        {
            let cache = self.char_font_cache.borrow();
            if let Some((typeface, is_emoji)) = cache.get(&ch) {
                let font = Self::create_font_with_emoji_support(typeface, font_size, *is_emoji);
                return (font, *is_emoji);
            }
        }

        if let Some((typeface, is_emoji)) = self.find_in_font_library(ch, font_size) {
            self.char_font_cache
                .borrow_mut()
                .insert(ch, (typeface.clone(), is_emoji));

            let font = Self::create_font_with_emoji_support(&typeface, font_size, is_emoji);
            return (font, is_emoji);
        }

        if let Some(typeface) = self.font_mgr.match_family_style_character(
            "",
            FontStyle::normal(),
            &[],
            ch as i32,
        ) {
            let family_name = typeface.family_name();
            let is_emoji = family_name.to_lowercase().contains("emoji");

            self.char_font_cache
                .borrow_mut()
                .insert(ch, (typeface.clone(), is_emoji));

            let font = Self::create_font_with_emoji_support(&typeface, font_size, is_emoji);
            return (font, is_emoji);
        }

        (styled_font.clone(), false)
    }

    fn find_in_font_library(&self, ch: char, _font_size: f32) -> Option<(Typeface, bool)> {
        let lib = self.font_library.read();
        let fonts_len = lib.inner.len();

        for font_id in 0..fonts_len {
            if let Some(font_data) = lib.inner.get(&font_id) {
                let is_emoji = font_data.is_emoji;

                if let Some((shared_data, offset, _key)) = lib.get_data(&font_id) {
                    let offset_usize = offset as usize;
                    let font_bytes = &shared_data[offset_usize..];
                    let data = skia_safe::Data::new_copy(font_bytes);

                    if let Some(typeface) = self.font_mgr.new_from_data(&data, None) {
                        let glyph_id = typeface.unichar_to_glyph(ch as i32);
                        if glyph_id != 0 {
                            return Some((typeface, is_emoji));
                        }
                    }
                }
            }
        }

        None
    }

    pub fn find_emoji_font(&self, ch: char, font_size: f32) -> Option<Font> {
        self.font_mgr
            .match_family_style_character(
                "Apple Color Emoji",
                FontStyle::normal(),
                &[],
                ch as i32,
            )
            .map(|tf| Self::create_font_with_emoji_support(&tf, font_size, true))
    }

    pub fn get_emoji_font(&self, font_size: f32) -> Option<Font> {
        self.font_mgr
            .match_family_style("Apple Color Emoji", FontStyle::normal())
            .map(|tf| Font::from_typeface(&tf, font_size))
    }

    pub fn get_typeface_for_font_id(&self, font_id: usize) -> Option<Typeface> {
        {
            let cache = self.typeface_cache.borrow();
            if let Some(result) = cache.get(&font_id) {
                return result.clone();
            }
        }

        let lib = self.font_library.read();
        let typeface = if let Some((font_data, offset, _key)) = lib.get_data(&font_id) {
            let offset_usize = offset as usize;
            let font_bytes = &font_data[offset_usize..];
            let data = skia_safe::Data::new_copy(font_bytes);
            self.font_mgr.new_from_data(&data, None)
        } else {
            None
        };

        self.typeface_cache
            .borrow_mut()
            .insert(font_id, typeface.clone());

        typeface
    }

    pub fn get_primary_font(&self, font_size: f32) -> Font {
        if let Some(ref typeface) = self.primary_font_typeface {
            Font::from_typeface(typeface, font_size)
        } else {
            Font::default()
        }
    }

    pub fn font_library(&self) -> &Arc<RwLock<FontLibraryData>> {
        &self.font_library
    }

    pub fn apply_font_attrs(
        &self,
        base_font: &Font,
        attrs: &sugarloaf::font_introspector::Attributes,
        _font_size: f32,
    ) -> Font {
        use sugarloaf::font_introspector::{Weight, Style};

        let is_bold = attrs.weight() >= Weight::BOLD;
        let is_italic = matches!(attrs.style(), Style::Italic | Style::Oblique(_));

        if !is_bold && !is_italic {
            return base_font.clone();
        }

        let typeface = base_font.typeface();
        let size = base_font.size();
        let mut font = Font::from_typeface(&typeface, size);

        if is_bold { font.set_embolden(true); }
        if is_italic { font.set_skew_x(-0.25); }
        font
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sugarloaf::font::fonts::SugarloafFonts;

    #[test]
    fn test_font_context_creation() {
        let (font_library, _errors) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        assert!(font_context.primary_font_typeface.is_some());
    }

    #[test]
    fn test_apply_font_attrs_italic() {
        use sugarloaf::font_introspector::{Attributes, Stretch, Weight, Style};

        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let base_font = font_context.get_primary_font(14.0);

        let italic_attrs = Attributes::new(Stretch::NORMAL, Weight::NORMAL, Style::Italic);
        let italic_font = font_context.apply_font_attrs(&base_font, &italic_attrs, 14.0);
        assert!(italic_font.skew_x() < 0.0);
    }

    #[test]
    fn test_apply_font_attrs_bold() {
        use sugarloaf::font_introspector::{Attributes, Stretch, Weight, Style};

        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let base_font = font_context.get_primary_font(14.0);

        let bold_attrs = Attributes::new(Stretch::NORMAL, Weight::BOLD, Style::Normal);
        let bold_font = font_context.apply_font_attrs(&base_font, &bold_attrs, 14.0);
        assert!(bold_font.is_embolden());
    }

    #[test]
    fn test_apply_font_attrs_normal() {
        use sugarloaf::font_introspector::{Attributes, Stretch, Weight, Style};

        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let base_font = font_context.get_primary_font(14.0);

        let normal_attrs = Attributes::new(Stretch::NORMAL, Weight::NORMAL, Style::Normal);
        let normal_font = font_context.apply_font_attrs(&base_font, &normal_attrs, 14.0);
        assert_eq!(normal_font.skew_x(), base_font.skew_x());
        assert_eq!(normal_font.is_embolden(), base_font.is_embolden());
    }

    #[test]
    fn test_find_font_for_ascii() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let styled_font = font_context.get_primary_font(14.0);

        let (font, is_emoji) = font_context.find_font_for_char('A', 14.0, &styled_font);
        assert!(!is_emoji);
        assert_eq!(font.typeface().unique_id(), styled_font.typeface().unique_id());
    }

    #[test]
    fn test_find_font_for_chinese() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let styled_font = font_context.get_primary_font(14.0);

        let (font, _is_emoji) = font_context.find_font_for_char('中', 14.0, &styled_font);
        assert!(font.typeface().unique_id() != 0);
    }

    #[test]
    fn test_find_emoji_font() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);

        let emoji_font = font_context.find_emoji_font('😀', 14.0);
        assert!(emoji_font.is_some());
    }

    #[test]
    fn test_char_font_cache() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let styled_font = font_context.get_primary_font(14.0);

        let (font1, _) = font_context.find_font_for_char('中', 14.0, &styled_font);
        let (font2, _) = font_context.find_font_for_char('中', 14.0, &styled_font);
        assert_eq!(font1.typeface().unique_id(), font2.typeface().unique_id());
    }

    #[test]
    fn test_emoji_with_maple_mono_font() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let styled_font = font_context.get_primary_font(14.0);

        println!("主字体: {}", styled_font.typeface().family_name());

        // 测试这些字符在 find_font_for_char 中选择的字体
        for (ch, name) in [('☀', "sun"), ('✂', "scissors"), ('✨', "sparkles")] {
            let glyph_in_primary = styled_font.unichar_to_glyph(ch as i32);
            let (found_font, is_emoji) = font_context.find_font_for_char(ch, 14.0, &styled_font);
            let found_family = found_font.typeface().family_name();

            println!("{} ({}) U+{:04X}:", name, ch, ch as u32);
            println!("  主字体 glyph_id: {}", glyph_in_primary);
            println!("  find_font_for_char → {} (is_emoji={})", found_family, is_emoji);
        }
    }

    #[test]
    fn test_terminal_symbols_fallback() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let styled_font = font_context.get_primary_font(14.0);

        println!("主字体: {}", styled_font.typeface().family_name());

        // 测试终端常用符号
        let symbols = [
            ('∴', "Therefore", 0x2234),
            ('·', "Middle Dot", 0x00B7),
            ('✢', "Four Teardrop Asterisk", 0x2722),
            ('✳', "Eight Spoked Asterisk", 0x2733),
            ('✶', "Six Pointed Star", 0x2736),
            ('⏺', "Record Symbol", 0x23FA),
        ];

        for (ch, name, code) in symbols {
            let glyph_in_primary = styled_font.unichar_to_glyph(ch as i32);
            let (found_font, is_emoji) = font_context.find_font_for_char(ch, 14.0, &styled_font);
            let found_family = found_font.typeface().family_name();

            println!("{} {} (U+{:04X}):", ch, name, code);
            println!("  主字体 glyph_id: {}", glyph_in_primary);
            println!("  find_font_for_char → {} (is_emoji={})", found_family, is_emoji);
        }
    }

    #[test]
    fn test_specific_emoji_sun_and_scissors() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);

        // 测试 ☀️ (sun emoji - Unicode: U+2600)
        let sun_font = font_context.find_emoji_font('☀', 14.0);
        assert!(sun_font.is_some(), "Failed to find font for sun emoji");

        if let Some(font) = sun_font {
            let typeface = font.typeface();
            let family_name = typeface.family_name();
            println!("sun (U+2600) font family: {}", family_name);
            println!("sun glyph id: {}", typeface.unichar_to_glyph('☀' as i32));
            assert!(typeface.unique_id() != 0);
            assert!(family_name.contains("Emoji"), "Expected emoji font, got: {}", family_name);
        }

        // 测试 ✂️ (scissors emoji - Unicode: U+2702)
        let scissors_font = font_context.find_emoji_font('✂', 14.0);
        assert!(scissors_font.is_some(), "Failed to find font for scissors emoji");

        if let Some(font) = scissors_font {
            let typeface = font.typeface();
            let family_name = typeface.family_name();
            println!("scissors (U+2702) font family: {}", family_name);
            println!("scissors glyph id: {}", typeface.unichar_to_glyph('✂' as i32));
            assert!(typeface.unique_id() != 0);
            assert!(family_name.contains("Emoji"), "Expected emoji font, got: {}", family_name);
        }

        // 测试 ✨ (sparkles emoji - Unicode: U+2728)
        let sparkles_font = font_context.find_emoji_font('✨', 14.0);
        assert!(sparkles_font.is_some(), "Failed to find font for sparkles emoji");

        if let Some(font) = sparkles_font {
            let typeface = font.typeface();
            let family_name = typeface.family_name();
            println!("sparkles (U+2728) font family: {}", family_name);
            println!("sparkles glyph id: {}", typeface.unichar_to_glyph('✨' as i32));
            assert!(typeface.unique_id() != 0);
            assert!(family_name.contains("Emoji"), "Expected emoji font, got: {}", family_name);
        }
    }
}
