#[cfg(target_os = "macos")]
pub fn external_fallbacks() -> Vec<String> {
    // 优化 fallback 顺序，避免彩色符号字体覆盖 ANSI 颜色
    // 1. 等宽字体优先（保持终端排版）
    // 2. 单色符号字体（避免彩色背景问题）
    // 3. 移除可能有彩色符号的字体（.SF NS, Arial Unicode MS）
    vec![
        String::from("SF Mono"),        // 等宽单色
        String::from("Menlo"),          // 等宽单色
        String::from("Apple Symbols"),  // 符号单色
        String::from("STIX Two Math"),  // 数学/技术符号（包含 ⏺ 等）
        String::from("Geneva"),         // 通用单色
        // Apple Color Emoji 不在这里添加，由 spec.emoji 配置控制
    ]
}

#[cfg(target_os = "windows")]
pub fn external_fallbacks() -> Vec<String> {
    vec![
        // Lucida Sans Unicode
        // Microsoft JhengHei
        String::from("Segoe UI"),
        // String::from("Segoe UI Emoji"),
        String::from("Segoe UI Symbol"),
        String::from("Segoe UI Historic"),
    ]
}

#[cfg(not(any(target_os = "macos", windows)))]
pub fn external_fallbacks() -> Vec<String> {
    vec![
        /* Sans-serif fallbacks */
        String::from("Noto Sans"),
        /* More sans-serif fallbacks */
        String::from("DejaVu Sans"),
        String::from("FreeSans"),
        /* Mono fallbacks */
        String::from("Noto Sans Mono"),
        String::from("DejaVu Sans Mono"),
        String::from("FreeMono"),
        /* Symbols fallbacks */
        String::from("Noto Sans Symbols"),
        String::from("Noto Sans Symbols2"),
        // String::from("Noto Color Emoji"),
    ]
}
