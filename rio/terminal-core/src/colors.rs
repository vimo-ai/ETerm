use std::ops::Mul;

pub type ColorArray = [f32; 4];

#[derive(Debug, Default, Copy, Clone, Eq, PartialEq, Hash)]
pub struct ColorRgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl ColorRgb {
    pub fn to_arr(&self) -> ColorArray {
        [
            self.r as f32 / 255.0,
            self.g as f32 / 255.0,
            self.b as f32 / 255.0,
            1.0,
        ]
    }
}

impl Mul<f32> for ColorRgb {
    type Output = ColorRgb;

    fn mul(self, rhs: f32) -> ColorRgb {
        let result = ColorRgb {
            r: (f32::from(self.r) * rhs).clamp(0.0, 255.0) as u8,
            g: (f32::from(self.g) * rhs).clamp(0.0, 255.0) as u8,
            b: (f32::from(self.b) * rhs).clamp(0.0, 255.0) as u8,
        };

        tracing::trace!(
            "Scaling ColorRgb by {} from {:?} to {:?}",
            rhs,
            self,
            result
        );
        result
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AnsiColor {
    Named(NamedColor),
    Spec(ColorRgb),
    Indexed(u8),
}

#[derive(Debug, Copy, Clone, Eq, PartialEq, PartialOrd, Ord, Hash)]
pub enum NamedColor {
    Black = 0,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    White,
    LightBlack,
    LightRed,
    LightGreen,
    LightYellow,
    LightBlue,
    LightMagenta,
    LightCyan,
    LightWhite,
    Foreground = 256,
    Background,
    Cursor,
    DimBlack,
    DimRed,
    DimGreen,
    DimYellow,
    DimBlue,
    DimMagenta,
    DimCyan,
    DimWhite,
    LightForeground,
    DimForeground,
}

impl NamedColor {
    #[must_use]
    pub fn to_light(self) -> Self {
        match self {
            NamedColor::Foreground => NamedColor::LightForeground,
            NamedColor::Black => NamedColor::LightBlack,
            NamedColor::Red => NamedColor::LightRed,
            NamedColor::Green => NamedColor::LightGreen,
            NamedColor::Yellow => NamedColor::LightYellow,
            NamedColor::Blue => NamedColor::LightBlue,
            NamedColor::Magenta => NamedColor::LightMagenta,
            NamedColor::Cyan => NamedColor::LightCyan,
            NamedColor::White => NamedColor::LightWhite,
            NamedColor::DimForeground => NamedColor::Foreground,
            NamedColor::DimBlack => NamedColor::Black,
            NamedColor::DimRed => NamedColor::Red,
            NamedColor::DimGreen => NamedColor::Green,
            NamedColor::DimYellow => NamedColor::Yellow,
            NamedColor::DimBlue => NamedColor::Blue,
            NamedColor::DimMagenta => NamedColor::Magenta,
            NamedColor::DimCyan => NamedColor::Cyan,
            NamedColor::DimWhite => NamedColor::White,
            val => val,
        }
    }

    #[must_use]
    pub fn to_dim(self) -> Self {
        match self {
            NamedColor::Black => NamedColor::DimBlack,
            NamedColor::Red => NamedColor::DimRed,
            NamedColor::Green => NamedColor::DimGreen,
            NamedColor::Yellow => NamedColor::DimYellow,
            NamedColor::Blue => NamedColor::DimBlue,
            NamedColor::Magenta => NamedColor::DimMagenta,
            NamedColor::Cyan => NamedColor::DimCyan,
            NamedColor::White => NamedColor::DimWhite,
            NamedColor::Foreground => NamedColor::DimForeground,
            NamedColor::LightBlack => NamedColor::Black,
            NamedColor::LightRed => NamedColor::Red,
            NamedColor::LightGreen => NamedColor::Green,
            NamedColor::LightYellow => NamedColor::Yellow,
            NamedColor::LightBlue => NamedColor::Blue,
            NamedColor::LightMagenta => NamedColor::Magenta,
            NamedColor::LightCyan => NamedColor::Cyan,
            NamedColor::LightWhite => NamedColor::White,
            NamedColor::LightForeground => NamedColor::Foreground,
            val => val,
        }
    }
}

use std::ops::{Index, IndexMut};

pub const COUNT: usize = 269;

#[derive(Copy, Debug, Clone, PartialEq)]
pub struct TermColors([Option<ColorArray>; COUNT]);

impl Default for TermColors {
    fn default() -> Self {
        Self([None; COUNT])
    }
}

impl Index<usize> for TermColors {
    type Output = Option<ColorArray>;

    #[inline]
    fn index(&self, index: usize) -> &Self::Output {
        &self.0[index]
    }
}

impl IndexMut<usize> for TermColors {
    #[inline]
    fn index_mut(&mut self, index: usize) -> &mut Self::Output {
        &mut self.0[index]
    }
}

impl Index<NamedColor> for TermColors {
    type Output = Option<ColorArray>;

    #[inline]
    fn index(&self, index: NamedColor) -> &Self::Output {
        &self.0[index as usize]
    }
}

impl IndexMut<NamedColor> for TermColors {
    #[inline]
    fn index_mut(&mut self, index: NamedColor) -> &mut Self::Output {
        &mut self.0[index as usize]
    }
}
