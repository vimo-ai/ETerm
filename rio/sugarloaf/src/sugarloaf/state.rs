// Copyright (c) 2023-present, Raphael Amorim.
//
// This source code is licensed under the MIT license found in the
// LICENSE file in the root directory of this source tree.

use crate::font::FontLibrary;
use crate::layout::RootStyle;
use crate::layout::RichTextLayout;
// use crate::sugarloaf::graphics::Graphics; // Unused after WGPU cleanup
use crate::{Content, Object, Quad, SugarDimensions};
use crate::sugarloaf::primitives::{RichText, ImageObject};
use std::collections::HashSet;

pub struct SugarState {
    objects: Vec<Object>,
    pub rich_texts: Vec<RichText>,
    pub images: Vec<ImageObject>,
    rich_text_repaint: HashSet<usize>,
    rich_text_to_be_removed: Vec<usize>,
    pub style: RootStyle,
    pub content: Content,
    pub quads: Vec<Quad>,
    pub visual_bell_overlay: Option<Quad>,
}

impl SugarState {
    pub fn new(
        style: RootStyle,
        font_library: &FontLibrary,
        font_features: &Option<Vec<String>>,
    ) -> SugarState {
        let mut content = Content::new(font_library);
        let found_font_features = SugarState::found_font_features(font_features);
        content.set_font_features(found_font_features);

        SugarState {
            content: Content::new(font_library),
            quads: vec![],
            images: vec![],
            style,
            objects: vec![],
            rich_texts: vec![],
            rich_text_to_be_removed: vec![],
            rich_text_repaint: HashSet::default(),
            visual_bell_overlay: None,
        }
    }

    pub fn found_font_features(
        font_features: &Option<Vec<String>>,
    ) -> Vec<crate::font_introspector::Setting<u16>> {
        let mut found_font_features = vec![];
        if let Some(features) = font_features {
            for feature in features {
                let setting: crate::font_introspector::Setting<u16> =
                    (feature.as_str(), 1).into();
                found_font_features.push(setting);
            }
        }

        found_font_features
    }

    #[inline]
    #[allow(dead_code)] // WGPU legacy method
    pub fn new_layer(&mut self) {}

    #[inline]
    pub fn get_state_layout(&self, id: &usize) -> RichTextLayout {
        if let Some(builder_state) = self.content.get_state(id) {
            return builder_state.layout;
        }

        RichTextLayout::from_default_layout(&self.style)
    }

    #[inline]
    pub fn set_rich_text_line_height(&mut self, rich_text_id: &usize, line_height: f32) {
        if let Some(rte) = self.content.get_state_mut(rich_text_id) {
            rte.layout.line_height = line_height;
        }
    }

    #[inline]
    #[allow(dead_code)] // Reserved for future use
    pub fn set_font_features(&mut self, font_features: &Option<Vec<String>>) {
        let found_font_features = SugarState::found_font_features(font_features);
        self.content.set_font_features(found_font_features);
    }

    #[inline]
    pub fn clean_screen(&mut self) {
        self.objects.clear();
    }

    #[inline]
    pub fn compute_objects(&mut self, new_objects: Vec<Object>) {
        let mut rich_texts: Vec<RichText> = vec![];
        for obj in &new_objects {
            if let Object::RichText(rich_text) = obj {
                rich_texts.push(*rich_text);
            }
        }
        self.objects = new_objects;
        self.rich_texts = rich_texts
    }

    #[inline]
    pub fn reset(&mut self) {
        self.quads.clear();
        self.images.clear();
        for rte_id in &self.rich_text_to_be_removed {
            self.content.remove_state(rte_id);
        }

        self.content.mark_states_clean();
        self.rich_text_to_be_removed.clear();
    }

    #[inline]
    pub fn clear_rich_text(&mut self, id: &usize) {
        self.content.clear_state(id);
    }

    #[inline]
    pub fn create_rich_text(&mut self) -> usize {
        self.content
            .create_state(&RichTextLayout::from_default_layout(&self.style))
    }

    #[inline]
    pub fn create_temp_rich_text(&mut self) -> usize {
        let id = self
            .content
            .create_state(&RichTextLayout::from_default_layout(&self.style));
        self.rich_text_to_be_removed.push(id);
        id
    }

    pub fn content(&mut self) -> &mut Content {
        &mut self.content
    }

    #[inline]
    pub fn set_visual_bell_overlay(&mut self, overlay: Option<Quad>) {
        self.visual_bell_overlay = overlay;
    }

    // Skia-specific methods that don't use brushes
    #[inline]
    pub fn set_fonts_skia(&mut self, fonts: &FontLibrary) {
        self.content.set_font_library(fonts);
        for (id, state) in &mut self.content.states {
            state.layout.dimensions.height = 0.0;
            state.layout.dimensions.width = 0.0;
            self.rich_text_repaint.insert(*id);
        }
    }

    #[inline]
    pub fn compute_layout_rescale_skia(&mut self, scale: f32) {
        self.style.scale_factor = scale;
        for (id, state) in &mut self.content.states {
            state.rescale(scale);
            state.layout.dimensions.height = 0.0;
            state.layout.dimensions.width = 0.0;
            self.rich_text_repaint.insert(*id);
        }
    }

    #[inline]
    pub fn set_rich_text_font_size_skia(&mut self, rich_text_id: &usize, font_size: f32) {
        if let Some(rte) = self.content.get_state_mut(rich_text_id) {
            rte.layout.font_size = font_size;
            rte.update_font_size();

            rte.layout.dimensions.height = 0.0;
            rte.layout.dimensions.width = 0.0;
            self.rich_text_repaint.insert(*rich_text_id);
        }
    }

    #[inline]
    pub fn set_rich_text_font_size_based_on_action_skia(
        &mut self,
        rich_text_id: &usize,
        operation: u8,
    ) {
        if let Some(rte) = self.content.get_state_mut(rich_text_id) {
            let should_update = match operation {
                0 => rte.reset_font_size(),
                2 => rte.increase_font_size(),
                1 => rte.decrease_font_size(),
                _ => false,
            };

            if should_update {
                rte.layout.dimensions.height = 0.0;
                rte.layout.dimensions.width = 0.0;
                self.rich_text_repaint.insert(*rich_text_id);
            }
        }
    }

    #[inline]
    pub fn get_rich_text_dimensions_skia(&mut self, _id: &usize) -> SugarDimensions {
        // For Skia, we'll compute dimensions differently
        // TODO: Implement proper dimension calculation using Skia
        SugarDimensions::default()
    }

    #[inline]
    pub fn compute_dimensions_skia(&mut self) {
        // Process objects to extract quads and images
        for object in &self.objects {
            match object {
                Object::Quad(composed_quad) => {
                    self.quads.push(*composed_quad);
                }
                Object::Image(image_obj) => {
                    self.images.push(image_obj.clone());
                }
                Object::RichText(_) => {
                    // RichText is already handled in compute_objects
                }
            }
        }
    }
}
