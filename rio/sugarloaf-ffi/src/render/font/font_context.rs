#[cfg(feature = "new_architecture")]
use sugarloaf::font::{FontLibrary, FontLibraryData};
use skia_safe::{FontMgr, FontStyle, Font, Typeface};
use std::sync::Arc;
use parking_lot::RwLock;
use std::collections::HashMap;
use std::cell::RefCell;

/// 字体上下文（封装 FontLibrary + Skia FontMgr + 缓存）
/// 复用老代码的完整字体查找逻辑
pub struct FontContext {
    /// 字体库（复用 rio/sugarloaf/src/font/）
    font_library: Arc<RwLock<FontLibraryData>>,

    /// Skia FontMgr（用于系统 fallback）
    font_mgr: FontMgr,

    /// 主字体的 Typeface（font_id = 0，优先使用）
    primary_font_typeface: Option<Typeface>,

    /// 字符 → (Typeface, is_emoji) 缓存
    /// 复用老代码逻辑：rio/sugarloaf/src/sugarloaf.rs:1481-1484
    char_font_cache: RefCell<HashMap<char, (Typeface, bool)>>,

    /// font_id → Typeface 缓存
    typeface_cache: RefCell<HashMap<usize, Option<Typeface>>>,
}

impl FontContext {
    pub fn new(font_library: FontLibrary) -> Self {
        let font_mgr = FontMgr::new();

        // 获取主字体 typeface (font_id = 0)
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

    /// 查找字符的最佳字体（复用老代码：1467-1506 行）
    /// 五步 fallback：
    /// 1. ASCII 快速路径
    /// 2. styled_font 是否支持（unichar_to_glyph）
    /// 3. 查缓存
    /// 4. 系统 fallback（Skia FontMgr）
    /// 5. 最终 fallback
    pub fn find_font_for_char(
        &self,
        ch: char,
        font_size: f32,
        styled_font: &Font,
    ) -> (Font, bool) {
        // 步骤 1: ASCII 直接用 styled_font（快速路径）
        if (ch as u32) < 0x80 {
            return (styled_font.clone(), false);
        }

        // 步骤 2: 检查 styled_font 是否支持（优先主字体）
        // unichar_to_glyph 返回 0 表示字体不支持该字符
        let glyph_id = styled_font.unichar_to_glyph(ch as i32);
        if glyph_id != 0 {
            return (styled_font.clone(), false);
        }

        // 步骤 3: 检查缓存
        {
            let cache = self.char_font_cache.borrow();
            if let Some((typeface, is_emoji)) = cache.get(&ch) {
                return (Font::from_typeface(typeface, font_size), *is_emoji);
            }
        }

        // 步骤 4: 系统 fallback（使用 Skia FontMgr）
        if let Some(typeface) = self.font_mgr.match_family_style_character(
            "",  // 空字符串表示系统 fallback
            FontStyle::normal(),
            &[],
            ch as i32,
        ) {
            // 通过字体 family name 判断是否为 emoji 字体
            let family_name = typeface.family_name();
            let is_emoji = family_name.to_lowercase().contains("emoji");

            // 缓存结果
            self.char_font_cache
                .borrow_mut()
                .insert(ch, (typeface.clone(), is_emoji));

            return (Font::from_typeface(&typeface, font_size), is_emoji);
        }

        // 步骤 5: 最终 fallback（使用 styled_font）
        (styled_font.clone(), false)
    }

    /// 查找 emoji 字体（复用老代码：1402-1411 行）
    /// 强制使用 "Apple Color Emoji" 字体
    pub fn find_emoji_font(&self, ch: char, font_size: f32) -> Option<Font> {
        self.font_mgr
            .match_family_style_character(
                "Apple Color Emoji",
                FontStyle::normal(),
                &[],
                ch as i32,
            )
            .map(|tf| Font::from_typeface(&tf, font_size))
    }

    /// 从 font_id 获取或创建 Typeface（带缓存）
    pub fn get_typeface_for_font_id(&self, font_id: usize) -> Option<Typeface> {
        // 检查缓存
        {
            let cache = self.typeface_cache.borrow();
            if let Some(result) = cache.get(&font_id) {
                return result.clone();
            }
        }

        // 从 FontLibrary 加载
        let lib = self.font_library.read();
        let typeface = if let Some((font_data, offset, _key)) = lib.get_data(&font_id) {
            let offset_usize = offset as usize;
            let font_bytes = &font_data[offset_usize..];
            let data = skia_safe::Data::new_copy(font_bytes);
            self.font_mgr.new_from_data(&data, None)
        } else {
            None
        };

        // 缓存结果
        self.typeface_cache
            .borrow_mut()
            .insert(font_id, typeface.clone());

        typeface
    }

    /// 获取主字体的 Font 实例
    pub fn get_primary_font(&self, font_size: f32) -> Font {
        if let Some(ref typeface) = self.primary_font_typeface {
            Font::from_typeface(typeface, font_size)
        } else {
            Font::default()
        }
    }

    /// 获取字体库（只读访问）
    pub fn font_library(&self) -> &Arc<RwLock<FontLibraryData>> {
        &self.font_library
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

        // 验证主字体存在
        assert!(font_context.primary_font_typeface.is_some());
    }

    #[test]
    fn test_find_font_for_ascii() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let styled_font = font_context.get_primary_font(14.0);

        // ASCII 字符应该直接返回 styled_font（快速路径）
        let (font, is_emoji) = font_context.find_font_for_char('A', 14.0, &styled_font);
        assert!(!is_emoji);
        // 验证返回的是同一个字体（通过 typeface 比较）
        assert_eq!(
            font.typeface().unique_id(),
            styled_font.typeface().unique_id()
        );
    }

    #[test]
    fn test_find_font_for_chinese() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let styled_font = font_context.get_primary_font(14.0);

        // 中文字符应该触发 fallback 查找
        let (font, _is_emoji) = font_context.find_font_for_char('中', 14.0, &styled_font);
        // 验证返回了有效的字体
        assert!(font.typeface().unique_id() != 0);
    }

    #[test]
    fn test_find_emoji_font() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);

        // 测试 emoji 字体查找
        let emoji_font = font_context.find_emoji_font('😀', 14.0);
        assert!(emoji_font.is_some());

        if let Some(font) = emoji_font {
            let typeface = font.typeface();
            let family_name = typeface.family_name();
            // 验证是 emoji 字体
            assert!(
                family_name.to_lowercase().contains("emoji"),
                "Expected emoji font, got: {}",
                family_name
            );
        }
    }

    #[test]
    fn test_char_font_cache() {
        let (font_library, _) = FontLibrary::new(SugarloafFonts::default());
        let font_context = FontContext::new(font_library);
        let styled_font = font_context.get_primary_font(14.0);

        // 第一次查找
        let (font1, _) = font_context.find_font_for_char('中', 14.0, &styled_font);

        // 第二次查找（应该命中缓存）
        let (font2, _) = font_context.find_font_for_char('中', 14.0, &styled_font);

        // 验证返回相同的字体
        assert_eq!(
            font1.typeface().unique_id(),
            font2.typeface().unique_id()
        );
    }
}
