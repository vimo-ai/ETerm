//! Block Drawing Module
//!
//! 自定义绘制 Block Elements 和 Box Drawing 字符，解决高 DPI 下的缝隙问题。
//!
//! ## 设计原理
//!
//! 传统字体渲染存在以下问题：
//! 1. 字体 glyph 可能没有完全填满 cell（设计留白）
//! 2. 抗锯齿产生半透明边缘
//! 3. 浮点坐标累积误差
//!
//! 自定义绘制使用精确的矩形/线条，确保像素级对齐，无缝拼接。
//!
//! ## 支持的字符范围
//!
//! - Block Elements (U+2580-U+259F): 32 个方块字符
//! - Box Drawing (U+2500-U+257F): 128 个线条字符（未来扩展）
//! - Shade characters: ░▒▓
//!
//! ## 使用方式
//!
//! ```rust,ignore
//! use block_drawing::{BlockDrawer, is_block_element};
//!
//! if is_block_element(ch) {
//!     drawer.draw(canvas, ch, x, y, width, height, color);
//! }
//! ```

mod block_elements;
mod detector;

pub use block_elements::BlockDrawer;
pub use detector::{is_block_element, is_box_drawing, is_drawable_block_char, BlockCharType};
