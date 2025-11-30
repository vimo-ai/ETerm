use crate::config::colors::{ColorArray, ColorBuilder, ColorComposition, Format};

// These functions are expected to panic if cannot convert the hex string

#[inline]
pub fn background() -> ColorComposition {
    // Shuimo 主题背景色（纯黑，但实际由 Sugarloaf 设为透明）
    let color = ColorBuilder::from_hex(String::from("#000000"), Format::SRGB0_1)
        .unwrap()
        .to_arr();
    (
        color,
        wgpu::Color {
            r: color[0] as f64,
            g: color[1] as f64,
            b: color[2] as f64,
            a: color[3] as f64,
        },
    )
}

#[inline]
pub fn cursor() -> ColorArray {
    // ETerm Shuimo Theme - 光标颜色（暗红色）
    ColorBuilder::from_hex(String::from("#861717"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn vi_cursor() -> ColorArray {
    ColorBuilder::from_hex(String::from("#12d0ff"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn tabs() -> ColorArray {
    ColorBuilder::from_hex(String::from("#443d40"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn tabs_foreground() -> ColorArray {
    ColorBuilder::from_hex(String::from("#7d7d7d"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn bar() -> ColorArray {
    ColorBuilder::from_hex(String::from("#1b1a1a"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn tabs_active() -> ColorArray {
    ColorBuilder::from_hex(String::from("#303030"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn tabs_active_foreground() -> ColorArray {
    [1., 1., 1., 1.]
}

#[inline]
pub fn tabs_active_highlight() -> ColorArray {
    ColorBuilder::from_hex(String::from("#ffa133"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn foreground() -> ColorArray {
    // Shuimo 主题 - 前景色（淡灰色）
    ColorBuilder::from_hex(String::from("#dbdadd"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn green() -> ColorArray {
    // Shuimo 主题 - 青绿色
    ColorBuilder::from_hex(String::from("#4a9992"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn red() -> ColorArray {
    // ETerm Shuimo Theme - 暗红色
    ColorBuilder::from_hex(String::from("#861717"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn blue() -> ColorArray {
    // ETerm Shuimo Theme - 蓝色
    ColorBuilder::from_hex(String::from("#268bd2"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn yellow() -> ColorArray {
    // ETerm Shuimo Theme - 黄色
    ColorBuilder::from_hex(String::from("#b58900"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn black() -> ColorArray {
    // ETerm Shuimo Theme - 黑色
    ColorBuilder::from_hex(String::from("#0f1423"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn cyan() -> ColorArray {
    // ETerm Shuimo Theme - 青色
    ColorBuilder::from_hex(String::from("#2aa198"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn magenta() -> ColorArray {
    // ETerm Shuimo Theme - 洋红色（使用暗红色保持一致）
    ColorBuilder::from_hex(String::from("#861717"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn white() -> ColorArray {
    // ETerm Shuimo Theme - 白色
    ColorBuilder::from_hex(String::from("#eee8d5"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn default_light_black() -> ColorArray {
    // ETerm Shuimo Theme - Bright Black（使用半透明 foreground，模拟 Warp 的 details 色）
    let mut color = ColorBuilder::from_hex(String::from("#dbdadd"), Format::SRGB0_1)
        .unwrap()
        .to_arr();
    color[3] = 0.5; // 设置 alpha = 0.5
    color
}
#[inline]
pub fn default_light_blue() -> ColorArray {
    // ETerm Shuimo Theme - Bright Blue
    ColorBuilder::from_hex(String::from("#839496"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn default_light_cyan() -> ColorArray {
    // ETerm Shuimo Theme - Bright Cyan
    ColorBuilder::from_hex(String::from("#93a1a1"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn default_light_green() -> ColorArray {
    // ETerm Shuimo Theme - Bright Green（与 normal 一致）
    ColorBuilder::from_hex(String::from("#4a9992"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn default_light_magenta() -> ColorArray {
    // ETerm Shuimo Theme - Bright Magenta（使用暗红色）
    ColorBuilder::from_hex(String::from("#861717"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn default_light_red() -> ColorArray {
    // ETerm Shuimo Theme - Bright Red（与 normal 一致）
    ColorBuilder::from_hex(String::from("#861717"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn default_light_white() -> ColorArray {
    // ETerm Shuimo Theme - Bright White
    ColorBuilder::from_hex(String::from("#fdf6e3"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn default_light_yellow() -> ColorArray {
    // ETerm Shuimo Theme - Bright Yellow
    ColorBuilder::from_hex(String::from("#657b83"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn split() -> ColorArray {
    ColorBuilder::from_hex(String::from("#292527"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn selection_foreground() -> ColorArray {
    ColorBuilder::from_hex(String::from("#44C9F0"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn selection_background() -> ColorArray {
    ColorBuilder::from_hex(String::from("#1C191A"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}

#[inline]
pub fn search_match_background() -> ColorArray {
    ColorBuilder::from_hex(String::from("#44C9F0"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn search_match_foreground() -> ColorArray {
    [1., 1., 1., 1.]
}
#[inline]
pub fn search_focused_match_background() -> ColorArray {
    ColorBuilder::from_hex(String::from("#E6A003"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn search_focused_match_foreground() -> ColorArray {
    [1., 1., 1., 1.]
}
#[inline]
pub fn hint_foreground() -> ColorArray {
    // Dark text color (#181818)
    ColorBuilder::from_hex(String::from("#181818"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
#[inline]
pub fn hint_background() -> ColorArray {
    // Orange background color (#f4bf75)
    ColorBuilder::from_hex(String::from("#f4bf75"), Format::SRGB0_1)
        .unwrap()
        .to_arr()
}
