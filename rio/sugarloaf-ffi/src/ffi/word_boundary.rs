//! Word Boundary Detection FFI - 分词相关

use crate::app::TerminalPool;
use crate::ffi::terminal_pool::TerminalPoolHandle;
use std::ffi::c_char;

/// 词边界结果（C ABI 兼容）
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FFIWordBoundary {
    /// 单词起始列（屏幕坐标）
    pub start_col: u16,
    /// 单词结束列（屏幕坐标，包含）
    pub end_col: u16,
    /// 绝对行号
    pub absolute_row: i64,
    /// 单词文本指针（需要调用者使用 terminal_pool_free_word_boundary 释放）
    pub text_ptr: *mut c_char,
    /// 文本长度（字节）
    pub text_len: usize,
    /// 是否有效
    pub valid: bool,
}

impl Default for FFIWordBoundary {
    fn default() -> Self {
        Self {
            start_col: 0,
            end_col: 0,
            absolute_row: 0,
            text_ptr: std::ptr::null_mut(),
            text_len: 0,
            valid: false,
        }
    }
}

/// 获取指定位置的单词边界
///
/// # 参数
/// - `handle`: TerminalPool 句柄
/// - `terminal_id`: 终端 ID
/// - `screen_row`: 屏幕行（0-based）
/// - `screen_col`: 屏幕列（0-based）
///
/// # 返回
/// - `FFIWordBoundary`: 单词边界信息，失败时 valid=false
///
/// # 分词规则（参考 Swift WordBoundaryDetector）
/// 1. 中文字符：连续中文算一个词
/// 2. 英文/数字/下划线：连续算一个词
/// 3. 空白符号：作为分隔符
/// 4. 其他符号：独立成词
///
/// # 注意
/// - 返回的 text_ptr 需要调用者使用 `terminal_pool_free_word_boundary` 释放
/// - 如果 valid=false，text_ptr 为 null，不需要释放
#[no_mangle]
pub extern "C" fn terminal_pool_get_word_at(
    handle: *mut TerminalPoolHandle,
    terminal_id: i32,
    screen_row: i32,
    screen_col: i32,
) -> FFIWordBoundary {
    if handle.is_null() || screen_row < 0 || screen_col < 0 {
        return FFIWordBoundary::default();
    }

    let pool = unsafe { &*(handle as *const TerminalPool) };

    // 使用 try_with_terminal 避免阻塞主线程
    pool.try_with_terminal(terminal_id as usize, |terminal| {
        let state = terminal.state();
        let grid = &state.grid;

        // 验证坐标有效性
        if screen_row as usize >= grid.lines() || screen_col as usize >= grid.columns() {
            return FFIWordBoundary::default();
        }

        // 获取行数据
        if let Some(row) = grid.row(screen_row as usize) {
            let cells = row.cells();
            let position = screen_col as usize;

            // 检查位置是否在范围内
            if position >= cells.len() {
                return FFIWordBoundary::default();
            }

            // 执行分词
            let (start_col, end_col) = find_word_boundary(cells, position);

            // 提取文本
            let word_text: String = cells[start_col..=end_col]
                .iter()
                .map(|cell| cell.c)
                .collect();

            // 转换为绝对行号
            let absolute_row = grid.screen_to_absolute(screen_row as usize, 0).line as i64;

            // 分配 C 字符串
            match std::ffi::CString::new(word_text.as_bytes()) {
                Ok(c_string) => {
                    let ptr = c_string.into_raw();
                    FFIWordBoundary {
                        start_col: start_col as u16,
                        end_col: end_col as u16,
                        absolute_row,
                        text_ptr: ptr,
                        text_len: word_text.len(),
                        valid: true,
                    }
                }
                Err(_) => FFIWordBoundary::default(),
            }
        } else {
            FFIWordBoundary::default()
        }
    }).unwrap_or(FFIWordBoundary::default())
}

/// 释放单词边界资源
///
/// # 参数
/// - `boundary`: 由 `terminal_pool_get_word_at` 返回的边界
///
/// # 安全性
/// - 只应该对 valid=true 的边界调用此函数
/// - 不要对同一个边界重复释放
#[no_mangle]
pub extern "C" fn terminal_pool_free_word_boundary(boundary: FFIWordBoundary) {
    if boundary.valid && !boundary.text_ptr.is_null() {
        unsafe {
            // 重新构建 CString 并释放
            let _ = std::ffi::CString::from_raw(boundary.text_ptr);
        }
    }
}

/// 分词辅助函数
///
/// # 参数
/// - `cells`: 行的所有 cell 数据
/// - `position`: 点击位置（列索引）
///
/// # 返回
/// - `(start_col, end_col)`: 单词的起始和结束列（包含）
///
/// # 分词规则
/// 1. 中文字符（CJK）：连续中文算一个词
/// 2. 英文/数字/下划线：连续算一个词
/// 3. 空白符号：作为分隔符
/// 4. 其他符号：独立成词
fn find_word_boundary(cells: &[crate::domain::views::grid::CellData], position: usize) -> (usize, usize) {
    if cells.is_empty() || position >= cells.len() {
        return (0, 0);
    }

    // 宽字符标志位（中文等占 2 列的字符）
    const WIDE_CHAR_SPACER: u16 = 0b0000_0000_0100_0000;

    // 如果点击在宽字符占位符上，向左移动到实际字符
    let mut actual_position = position;
    if cells[actual_position].flags & WIDE_CHAR_SPACER != 0 && actual_position > 0 {
        actual_position -= 1;
    }

    let target_char = cells[actual_position].c;

    // 如果点击在空白符上，返回单个空格
    if is_word_separator(target_char) {
        return (actual_position, actual_position);
    }

    let char_type = classify_char(target_char);

    // 向左扩展（跳过宽字符占位符）
    let mut start = actual_position;
    while start > 0 {
        let prev_cell = &cells[start - 1];
        // 跳过宽字符占位符
        if prev_cell.flags & WIDE_CHAR_SPACER != 0 {
            start -= 1;
            continue;
        }
        let prev_char = prev_cell.c;
        if is_word_separator(prev_char) || classify_char(prev_char) != char_type {
            break;
        }
        start -= 1;
    }

    // 向右扩展（跳过宽字符占位符）
    let mut end = actual_position;
    while end + 1 < cells.len() {
        let next_cell = &cells[end + 1];
        // 跳过宽字符占位符
        if next_cell.flags & WIDE_CHAR_SPACER != 0 {
            end += 1;
            continue;
        }
        let next_char = next_cell.c;
        if is_word_separator(next_char) || classify_char(next_char) != char_type {
            break;
        }
        end += 1;
    }

    // 确保选区包含最后一个宽字符的占位符
    while end + 1 < cells.len() && cells[end + 1].flags & WIDE_CHAR_SPACER != 0 {
        end += 1;
    }

    (start, end)
}

/// 字符类型
#[derive(Debug, PartialEq, Eq)]
enum CharType {
    /// 中日韩字符（CJK）
    Cjk,
    /// 字母数字下划线
    Alphanumeric,
    /// 其他符号
    Symbol,
}

/// 分类字符
fn classify_char(ch: char) -> CharType {
    // 中日韩字符（Unicode CJK 块）
    if is_cjk(ch) {
        return CharType::Cjk;
    }

    // 字母、数字、下划线
    if ch.is_alphanumeric() || ch == '_' {
        return CharType::Alphanumeric;
    }

    // 其他符号
    CharType::Symbol
}

/// 判断是否为 CJK 字符
fn is_cjk(ch: char) -> bool {
    let code = ch as u32;
    // CJK Unified Ideographs
    (0x4E00..=0x9FFF).contains(&code) ||
    // CJK Extension A
    (0x3400..=0x4DBF).contains(&code) ||
    // CJK Extension B-F
    (0x20000..=0x2A6DF).contains(&code) ||
    // CJK Compatibility Ideographs
    (0xF900..=0xFAFF).contains(&code) ||
    // Hangul (韩文)
    (0xAC00..=0xD7AF).contains(&code) ||
    // Hiragana and Katakana (日文假名)
    (0x3040..=0x309F).contains(&code) ||
    (0x30A0..=0x30FF).contains(&code)
}

/// 判断是否为分隔符
fn is_word_separator(ch: char) -> bool {
    // 下划线不是分隔符
    if ch == '_' {
        return false;
    }

    // 空白符
    if ch.is_whitespace() {
        return true;
    }

    // ASCII 标点
    if ch.is_ascii_punctuation() {
        return true;
    }

    // 中文标点（常见的）
    // 使用 Unicode 码点范围检查
    let code = ch as u32;

    // 中文标点符号块
    // CJK Symbols and Punctuation: U+3000..U+303F
    if (0x3000..=0x303F).contains(&code) {
        return true;
    }

    // 全角 ASCII 标点: U+FF00..U+FFEF（全角标点）
    if (0xFF01..=0xFF0F).contains(&code) ||  // ！"＃＄％等
       (0xFF1A..=0xFF1F).contains(&code) ||  // ：；＜＝＞？
       (0xFF3B..=0xFF40).contains(&code) ||  // ［＼］＾＿｀
       (0xFF5B..=0xFF60).contains(&code) {   // ｛｜｝～
        return true;
    }

    // 其他常用中文标点
    matches!(ch,
        '\u{2014}' |  // — (EM DASH)
        '\u{2026}' |  // … (HORIZONTAL ELLIPSIS)
        '\u{00B7}' |  // · (MIDDLE DOT)
        '\u{201C}' | '\u{201D}' |  // " " (双引号)
        '\u{2018}' | '\u{2019}'    // ' ' (单引号)
    )
}

// ===== Tests =====

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_classify_char_english() {
        assert_eq!(classify_char('a'), CharType::Alphanumeric);
        assert_eq!(classify_char('Z'), CharType::Alphanumeric);
        assert_eq!(classify_char('0'), CharType::Alphanumeric);
        assert_eq!(classify_char('9'), CharType::Alphanumeric);
        assert_eq!(classify_char('_'), CharType::Alphanumeric);
    }

    #[test]
    fn test_classify_char_cjk() {
        // 中文
        assert_eq!(classify_char('中'), CharType::Cjk);
        assert_eq!(classify_char('文'), CharType::Cjk);
        // 日文假名
        assert_eq!(classify_char('あ'), CharType::Cjk);
        assert_eq!(classify_char('ア'), CharType::Cjk);
        // 韩文
        assert_eq!(classify_char('한'), CharType::Cjk);
    }

    #[test]
    fn test_classify_char_symbol() {
        assert_eq!(classify_char('!'), CharType::Symbol);
        assert_eq!(classify_char('@'), CharType::Symbol);
        assert_eq!(classify_char('#'), CharType::Symbol);
        assert_eq!(classify_char('$'), CharType::Symbol);
    }

    #[test]
    fn test_is_word_separator() {
        // 空白符
        assert!(is_word_separator(' '));
        assert!(is_word_separator('\t'));
        assert!(is_word_separator('\n'));

        // ASCII 标点
        assert!(is_word_separator('.'));
        assert!(is_word_separator(','));
        assert!(is_word_separator('!'));
        assert!(is_word_separator('?'));

        // 非分隔符
        assert!(!is_word_separator('a'));
        assert!(!is_word_separator('中'));
        assert!(!is_word_separator('_'));
    }

    #[test]
    fn test_find_word_boundary_english() {
        use crate::domain::views::grid::CellData;

        // 创建测试数据：hello world
        let text = "hello world";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 'e' (position=1)
        let (start, end) = find_word_boundary(&cells, 1);
        assert_eq!(start, 0);
        assert_eq!(end, 4);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "hello");

        // 点击 'w' (position=6)
        let (start, end) = find_word_boundary(&cells, 6);
        assert_eq!(start, 6);
        assert_eq!(end, 10);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "world");

        // 点击空格 (position=5)
        let (start, end) = find_word_boundary(&cells, 5);
        assert_eq!(start, 5);
        assert_eq!(end, 5);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, " ");
    }

    #[test]
    fn test_find_word_boundary_chinese() {
        use crate::domain::views::grid::CellData;

        // 创建测试数据：你好世界
        let text = "你好世界";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 '好' (position=1)
        let (start, end) = find_word_boundary(&cells, 1);
        assert_eq!(start, 0);
        assert_eq!(end, 3); // 连续 CJK 算一个词
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "你好世界");
    }

    #[test]
    fn test_find_word_boundary_mixed() {
        use crate::domain::views::grid::CellData;

        // 创建测试数据：hello 世界
        let text = "hello 世界";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 'l' (position=2)
        let (start, end) = find_word_boundary(&cells, 2);
        assert_eq!(start, 0);
        assert_eq!(end, 4);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "hello");

        // 点击 '世' (position=6)
        let (start, end) = find_word_boundary(&cells, 6);
        assert_eq!(start, 6);
        assert_eq!(end, 7);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "世界");
    }

    #[test]
    fn test_find_word_boundary_underscore() {
        use crate::domain::views::grid::CellData;

        // 创建测试数据：hello_world
        let text = "hello_world";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 '_' (position=5)
        let (start, end) = find_word_boundary(&cells, 5);
        assert_eq!(start, 0);
        assert_eq!(end, 10); // 下划线算字母数字
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "hello_world");
    }

    #[test]
    fn test_find_word_boundary_symbol() {
        use crate::domain::views::grid::CellData;

        // 创建测试数据：hello@world
        let text = "hello@world";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();

        // 点击 '@' (position=5)
        let (start, end) = find_word_boundary(&cells, 5);
        assert_eq!(start, 5);
        assert_eq!(end, 5); // 符号独立成词
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "@");
    }

    #[test]
    fn test_find_word_boundary_edge_cases() {
        use crate::domain::views::grid::CellData;

        // 空数组
        let cells: Vec<CellData> = Vec::new();
        let (start, end) = find_word_boundary(&cells, 0);
        assert_eq!(start, 0);
        assert_eq!(end, 0);

        // 单字符
        let text = "a";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();
        let (start, end) = find_word_boundary(&cells, 0);
        assert_eq!(start, 0);
        assert_eq!(end, 0);
        let word: String = cells[start..=end].iter().map(|c| c.c).collect();
        assert_eq!(word, "a");

        // 行首
        let text = "hello world";
        let cells: Vec<CellData> = text.chars().map(|c| {
            CellData {
                c,
                ..CellData::default()
            }
        }).collect();
        let (start, end) = find_word_boundary(&cells, 0);
        assert_eq!(start, 0);
        assert_eq!(end, 4);

        // 行尾
        let (start, end) = find_word_boundary(&cells, 10);
        assert_eq!(start, 6);
        assert_eq!(end, 10);
    }

    #[test]
    fn test_ffi_word_boundary_default() {
        let boundary = FFIWordBoundary::default();
        assert_eq!(boundary.start_col, 0);
        assert_eq!(boundary.end_col, 0);
        assert_eq!(boundary.absolute_row, 0);
        assert!(boundary.text_ptr.is_null());
        assert_eq!(boundary.text_len, 0);
        assert!(!boundary.valid);
    }

    #[test]
    fn test_terminal_pool_get_word_at_null_handle() {
        let result = terminal_pool_get_word_at(std::ptr::null_mut(), 0, 0, 0);
        assert!(!result.valid);
        assert!(result.text_ptr.is_null());
    }

    #[test]
    fn test_terminal_pool_free_word_boundary_invalid() {
        // 释放无效边界不应该崩溃
        let boundary = FFIWordBoundary::default();
        terminal_pool_free_word_boundary(boundary);
    }
}
