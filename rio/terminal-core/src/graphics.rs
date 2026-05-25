use crate::colors::ColorRgb;
use crate::grid::Dimensions;
use parking_lot::Mutex;
use smallvec::SmallVec;
use std::mem;
use std::sync::{Arc, Weak};

pub const MAX_GRAPHIC_DIMENSIONS: [usize; 2] = [4096, 4096];

#[derive(Eq, PartialEq, Clone, Debug, Copy, Hash, PartialOrd, Ord)]
pub struct GraphicId(pub u64);

#[derive(Eq, PartialEq, Clone, Debug, Copy)]
pub enum ColorType {
    Rgb,
    Rgba,
}

#[derive(Eq, PartialEq, Clone, Debug)]
pub struct GraphicData {
    pub id: GraphicId,
    pub width: usize,
    pub height: usize,
    pub color_type: ColorType,
    pub pixels: Vec<u8>,
    pub is_opaque: bool,
    pub resize: Option<ResizeCommand>,
}

impl GraphicData {
    #[inline]
    pub fn maybe_transparent(&self) -> bool {
        !self.is_opaque && self.color_type == ColorType::Rgba
    }

    pub fn is_filled(&self, x: usize, y: usize, width: usize, height: usize) -> bool {
        if x + width >= self.width || y + height >= self.height {
            return false;
        }

        if !self.maybe_transparent() {
            return true;
        }

        debug_assert!(self.color_type == ColorType::Rgba);

        for offset_y in y..y + height {
            let offset = offset_y * self.width * 4;
            let row = &self.pixels[offset..offset + width * 4];

            if row.chunks_exact(4).any(|pixel| pixel.last() != Some(&255)) {
                return false;
            }
        }

        true
    }
}

#[cfg(feature = "image")]
impl GraphicData {
    pub fn from_dynamic_image(id: GraphicId, image: image_rs::DynamicImage) -> Self {
        let color_type;
        let width;
        let height;
        let pixels;

        match image {
            image_rs::DynamicImage::ImageRgba8(img) => {
                color_type = ColorType::Rgba;
                width = img.width() as usize;
                height = img.height() as usize;
                pixels = img.into_raw();
            }
            _ => {
                let img = image.into_rgba8();
                color_type = ColorType::Rgba;
                width = img.width() as usize;
                height = img.height() as usize;
                pixels = img.into_raw();
            }
        }

        let is_opaque = match color_type {
            ColorType::Rgb => true,
            ColorType::Rgba => !pixels.chunks_exact(4).any(|pixel| pixel[3] != 255),
        };

        GraphicData {
            id,
            width,
            height,
            color_type,
            pixels,
            is_opaque,
            resize: None,
        }
    }

    pub fn resized(
        self,
        cell_width: usize,
        cell_height: usize,
        view_width: usize,
        view_height: usize,
    ) -> Option<Self> {
        use std::cmp;

        let resize = match self.resize {
            Some(resize) => resize,
            None => return Some(self),
        };

        if (resize.width == ResizeParameter::Auto
            && resize.height == ResizeParameter::Auto)
            || self.height == 0
            || self.width == 0
        {
            return Some(self);
        }

        let mut width = match resize.width {
            ResizeParameter::Auto => 1,
            ResizeParameter::Pixels(n) => n as usize,
            ResizeParameter::Cells(n) => n as usize * cell_width,
            ResizeParameter::WindowPercent(n) => n as usize * view_width / 100,
        };

        let mut height = match resize.height {
            ResizeParameter::Auto => 1,
            ResizeParameter::Pixels(n) => n as usize,
            ResizeParameter::Cells(n) => n as usize * cell_height,
            ResizeParameter::WindowPercent(n) => n as usize * view_height / 100,
        };

        if width == 0 || height == 0 {
            return None;
        }

        if resize.width == ResizeParameter::Auto {
            width = self.width * height / self.height;
        }

        if resize.height == ResizeParameter::Auto {
            height = self.height * width / self.width;
        }

        width = cmp::min(width, MAX_GRAPHIC_DIMENSIONS[0]);
        height = cmp::min(height, MAX_GRAPHIC_DIMENSIONS[1]);

        let dynimage = match self.color_type {
            ColorType::Rgb => {
                let buffer = image_rs::RgbImage::from_raw(
                    self.width as u32,
                    self.height as u32,
                    self.pixels,
                )?;
                image_rs::DynamicImage::ImageRgb8(buffer)
            }
            ColorType::Rgba => {
                let buffer = image_rs::RgbaImage::from_raw(
                    self.width as u32,
                    self.height as u32,
                    self.pixels,
                )?;
                image_rs::DynamicImage::ImageRgba8(buffer)
            }
        };

        let width = width as u32;
        let height = height as u32;
        let filter = image_rs::imageops::FilterType::Triangle;

        let new_image = if resize.preserve_aspect_ratio {
            dynimage.resize(width, height, filter)
        } else {
            dynimage.resize_exact(width, height, filter)
        };

        Some(Self::from_dynamic_image(self.id, new_image))
    }
}

#[derive(Eq, PartialEq, Clone, Copy, Debug)]
pub enum ResizeParameter {
    Auto,
    Cells(u32),
    Pixels(u32),
    WindowPercent(u32),
}

#[derive(Eq, PartialEq, Clone, Copy, Debug)]
pub struct ResizeCommand {
    pub width: ResizeParameter,
    pub height: ResizeParameter,
    pub preserve_aspect_ratio: bool,
}

#[derive(Debug, Clone)]
pub struct UpdateQueues {
    pub pending: Vec<GraphicData>,
    pub remove_queue: Vec<GraphicId>,
}

#[derive(Clone, Debug)]
pub struct TextureRef {
    pub id: GraphicId,
    pub width: u16,
    pub height: u16,
    pub cell_height: usize,
    pub texture_operations: Weak<Mutex<Vec<GraphicId>>>,
}

impl PartialEq for TextureRef {
    fn eq(&self, t: &Self) -> bool {
        self.id == t.id
    }
}

impl Eq for TextureRef {}

impl Drop for TextureRef {
    fn drop(&mut self) {
        if let Some(texture_operations) = self.texture_operations.upgrade() {
            texture_operations.lock().push(self.id);
        }
    }
}

pub type GraphicsCell = SmallVec<[GraphicCell; 1]>;

#[derive(Clone, Debug)]
pub struct GraphicCell {
    pub texture: Arc<TextureRef>,
    pub offset_x: u16,
    pub offset_y: u16,
    pub texture_operations: Weak<Mutex<Vec<GraphicId>>>,
}

impl PartialEq for GraphicCell {
    fn eq(&self, c: &Self) -> bool {
        self.texture == c.texture
            && self.offset_x == c.offset_x
            && self.offset_y == c.offset_y
    }
}

impl Eq for GraphicCell {}

impl Drop for GraphicCell {
    fn drop(&mut self) {
        if let Some(texture_operations) = self.texture_operations.upgrade() {
            texture_operations.lock().push(self.texture.id);
        }
    }
}

#[derive(Debug, Default)]
pub struct Graphics {
    pub last_id: u64,
    pub pending: Vec<GraphicData>,
    pub texture_operations: Arc<Mutex<Vec<GraphicId>>>,
    pub sixel_shared_palette: Option<Vec<ColorRgb>>,
    pub cell_height: f32,
    pub cell_width: f32,
    pub sixel_parser: Option<Box<crate::sixel::Parser>>,
}

impl Graphics {
    pub fn new<S: Dimensions>(size: &S) -> Self {
        let mut graphics = Graphics::default();
        graphics.resize(size);
        graphics
    }

    pub fn next_id(&mut self) -> GraphicId {
        self.last_id += 1;
        GraphicId(self.last_id)
    }

    pub fn has_pending_updates(&self) -> bool {
        !self.pending.is_empty() || !self.texture_operations.lock().is_empty()
    }

    pub fn take_queues(&mut self) -> Option<UpdateQueues> {
        let remove_queue = {
            let mut queue = self.texture_operations.lock();
            if queue.is_empty() {
                Vec::new()
            } else {
                mem::take(&mut *queue)
            }
        };

        if remove_queue.is_empty() && self.pending.is_empty() {
            return None;
        }

        Some(UpdateQueues {
            pending: mem::take(&mut self.pending),
            remove_queue,
        })
    }

    pub fn resize<S: Dimensions>(&mut self, size: &S) {
        self.cell_height = size.square_height();
        self.cell_width = size.square_width();
    }
}
