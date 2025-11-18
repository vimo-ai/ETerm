// context_grid.rs - Split 布局管理（基于 Rio 的 ContextGrid 简化版）
//
// 核心设计：
// - 使用链表结构（right/down/parent）管理 panes
// - 每个 pane 有独立的终端实例和 RichText
// - 通过计算 position 实现多 pane 渲染

use crate::TerminalHandle;
use std::collections::HashMap;
use sugarloaf::{Object, RichText};

const PADDING: f32 = 2.0;

/// Margin/Delta 结构
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Delta<T: Default> {
    pub x: T,
    pub top_y: T,
    pub bottom_y: T,
}

/// Pane 的尺寸信息
#[derive(Clone, Copy, Debug)]
pub struct PaneDimension {
    pub width: f32,
    pub height: f32,
    pub margin: Delta<f32>,
}

impl PaneDimension {
    pub fn new(width: f32, height: f32) -> Self {
        Self {
            width,
            height,
            margin: Delta::default(),
        }
    }

    pub fn update_width(&mut self, width: f32) {
        self.width = width;
    }

    pub fn update_height(&mut self, height: f32) {
        self.height = height;
    }

    pub fn update_margin(&mut self, margin: Delta<f32>) {
        self.margin = margin;
    }
}

/// 单个 Pane 的信息
pub struct ContextGridItem {
    pub pane_id: usize,
    pub terminal: Box<TerminalHandle>,
    pub rich_text_id: usize,
    rich_text_object: Object,

    // 🎯 终端网格尺寸
    pub cols: u16,  // 终端列数
    pub rows: u16,  // 终端行数

    // ❌ 删除链表关系（Swift 负责布局）
    // right: Option<usize>,
    // down: Option<usize>,
    // parent: Option<usize>,

    // ❌ 删除 dimension（Swift 负责布局）
    // pub dimension: PaneDimension,
}

impl ContextGridItem {
    pub fn new(
        pane_id: usize,
        terminal: Box<TerminalHandle>,
        rich_text_id: usize,
        cols: u16,
        rows: u16,
    ) -> Self {
        let rich_text_object = Object::RichText(RichText {
            id: rich_text_id,
            position: [0.0, 0.0],
            lines: None,
        });

        Self {
            pane_id,
            terminal,
            rich_text_id,
            rich_text_object,
            cols,
            rows,
        }
    }

    #[inline]
    pub fn position(&self) -> [f32; 2] {
        if let Object::RichText(ref rich_text) = self.rich_text_object {
            rich_text.position
        } else {
            [0.0, 0.0]
        }
    }

    /// ✅ 新增：让 Swift 设置位置
    #[inline]
    pub fn set_position(&mut self, position: [f32; 2]) {
        if let Object::RichText(ref mut rich_text) = self.rich_text_object {
            rich_text.position = position;
        }
    }

    #[inline]
    pub fn get_rich_text_object(&self) -> &Object {
        &self.rich_text_object
    }
}

/// 分隔线信息
#[derive(Debug, Clone, Copy)]
pub struct DividerInfo {
    pub pane_id_1: usize,   // 左/上 pane
    pub pane_id_2: usize,   // 右/下 pane
    pub divider_type: u8,   // 0=vertical (左右), 1=horizontal (上下)
    pub position: f32,      // 分隔线的逻辑坐标（x 或 y）
}

/// ContextGrid - 管理一个 Tab 内的所有 Split Panes
pub struct ContextGrid {
    pub width: f32,
    pub height: f32,
    pub current: usize,  // 当前激活的 pane ID
    pub margin: Delta<f32>,
    border_color: [f32; 4],
    scaled_padding: f32,
    scale: f32,
    inner: HashMap<usize, ContextGridItem>,
    pub root: Option<usize>,
    next_pane_id: usize,
}

impl ContextGrid {
    /// 创建新的 ContextGrid（初始只有一个 pane）
    pub fn new(
        initial_pane_id: usize,
        terminal: Box<TerminalHandle>,
        rich_text_id: usize,
        width: f32,
        height: f32,
        scale: f32,
        margin: Delta<f32>,
        border_color: [f32; 4],
        cols: u16,
        rows: u16,
    ) -> Self {
        let scaled_padding = PADDING * scale;

        let mut inner = HashMap::new();
        inner.insert(
            initial_pane_id,
            ContextGridItem::new(initial_pane_id, terminal, rich_text_id, cols, rows),
        );

        Self {
            inner,
            current: initial_pane_id,
            margin,
            width,
            height,
            border_color,
            scaled_padding,
            scale,
            root: Some(initial_pane_id),
            next_pane_id: initial_pane_id + 1,
        }
    }

    /// 获取下一个 pane ID
    pub fn get_next_pane_id(&mut self) -> usize {
        let id = self.next_pane_id;
        self.next_pane_id += 1;
        id
    }

    /// 获取所有 pane 的数量
    #[inline]
    pub fn len(&self) -> usize {
        self.inner.len()
    }

    /// 获取当前激活的 pane
    #[inline]
    pub fn get_current_mut(&mut self) -> Option<&mut ContextGridItem> {
        self.inner.get_mut(&self.current)
    }

    /// 获取指定 pane
    #[inline]
    pub fn get_mut(&mut self, pane_id: usize) -> Option<&mut ContextGridItem> {
        self.inner.get_mut(&pane_id)
    }

    /// 获取所有 panes 的可变引用
    #[inline]
    pub fn get_all_panes_mut(&mut self) -> impl Iterator<Item = &mut ContextGridItem> {
        self.inner.values_mut()
    }

    // ❌ 删除：split_right 和 split_down（Swift 负责 split 逻辑）
    /*
    pub fn split_right(
        &mut self,
        terminal: Box<TerminalHandle>,
        rich_text_id: usize,
    ) -> Option<usize> {
        eprintln!("[ContextGrid] split_right called, current pane: {}", self.current);
        let current_item = self.inner.get(&self.current)?;
        let old_right = current_item.right;
        let old_grid_item_height = current_item.dimension.height;
        let old_grid_item_width = current_item.dimension.width - self.margin.x;
        let new_grid_item_width = old_grid_item_width / 2.0;

        // 🎯 获取当前终端的尺寸
        let old_cols = current_item.cols;
        let old_rows = current_item.rows;
        let new_cols = old_cols / 2;

        eprintln!("[ContextGrid] old_width: {}, new_width: {}, height: {}",
                  old_grid_item_width, new_grid_item_width, old_grid_item_height);
        eprintln!("[ContextGrid] old_cols: {}, new_cols: {}, rows: {}",
                  old_cols, new_cols, old_rows);

        // 更新当前 pane 的宽度和终端尺寸
        if let Some(current_item) = self.inner.get_mut(&self.current) {
            current_item
                .dimension
                .update_width(new_grid_item_width - self.scaled_padding);

            // 重置 margin
            let mut new_margin = current_item.dimension.margin;
            new_margin.x = 0.0;
            current_item.dimension.update_margin(new_margin);

            // 🎯 调整终端尺寸
            current_item.cols = new_cols;
            let terminal_ptr = &mut *current_item.terminal as *mut crate::TerminalHandle;
            eprintln!("[ContextGrid] Resizing current pane terminal to {}x{}", new_cols, old_rows);
            crate::terminal_resize(terminal_ptr, new_cols, old_rows);
        }

        // 创建新 pane
        let new_pane_id = self.get_next_pane_id();
        let mut new_dimension = PaneDimension::new(new_grid_item_width, old_grid_item_height);

        // 如果是最后一个 pane，添加右边距
        if old_right.is_none() {
            let mut margin = Delta::default();
            margin.x = self.margin.x / 2.0;
            new_dimension.update_margin(margin);
        }

        let mut new_item = ContextGridItem::new(
            new_pane_id,
            terminal,
            rich_text_id,
            new_dimension,
            new_cols,
            old_rows,
        );

        // 🎯 调整新终端的尺寸
        let new_terminal_ptr = &mut *new_item.terminal as *mut crate::TerminalHandle;
        eprintln!("[ContextGrid] Resizing new pane terminal to {}x{}", new_cols, old_rows);
        crate::terminal_resize(new_terminal_ptr, new_cols, old_rows);

        new_item.right = old_right;
        new_item.parent = Some(self.current);

        self.inner.insert(new_pane_id, new_item);

        // 更新链表关系
        if let Some(current_item) = self.inner.get_mut(&self.current) {
            current_item.right = Some(new_pane_id);
        }

        // 更新 old_right 的 parent
        if let Some(old_right_key) = old_right {
            if let Some(old_right_item) = self.inner.get_mut(&old_right_key) {
                old_right_item.parent = Some(new_pane_id);
            }
        }

        // 设置新 pane 为激活状态
        self.current = new_pane_id;

        // 重新计算位置
        self.calculate_positions_for_affected_nodes(&[self.current, new_pane_id]);

        eprintln!("[ContextGrid] split_right completed, new pane: {}", new_pane_id);

        Some(new_pane_id)
    }

    pub fn split_down(
        &mut self,
        terminal: Box<TerminalHandle>,
        rich_text_id: usize,
    ) -> Option<usize> {
        eprintln!("[ContextGrid] split_down called, current pane: {}", self.current);
        let current_item = self.inner.get(&self.current)?;
        let old_down = current_item.down;
        let old_grid_item_height = current_item.dimension.height;
        let old_grid_item_width = current_item.dimension.width;
        let new_grid_item_height = old_grid_item_height / 2.0;

        // 🎯 获取当前终端的尺寸
        let old_cols = current_item.cols;
        let old_rows = current_item.rows;
        let new_rows = old_rows / 2;

        eprintln!("[ContextGrid] old_height: {}, new_height: {}, width: {}",
                  old_grid_item_height, new_grid_item_height, old_grid_item_width);
        eprintln!("[ContextGrid] cols: {}, old_rows: {}, new_rows: {}",
                  old_cols, old_rows, new_rows);

        // 更新当前 pane 的高度和终端尺寸
        if let Some(current_item) = self.inner.get_mut(&self.current) {
            current_item
                .dimension
                .update_height(new_grid_item_height - self.scaled_padding);

            // 🎯 调整终端尺寸
            current_item.rows = new_rows;
            let terminal_ptr = &mut *current_item.terminal as *mut crate::TerminalHandle;
            eprintln!("[ContextGrid] Resizing current pane terminal to {}x{}", old_cols, new_rows);
            crate::terminal_resize(terminal_ptr, old_cols, new_rows);
        }

        // 创建新 pane
        let new_pane_id = self.get_next_pane_id();
        let new_dimension = PaneDimension::new(old_grid_item_width, new_grid_item_height);

        let mut new_item = ContextGridItem::new(
            new_pane_id,
            terminal,
            rich_text_id,
            new_dimension,
            old_cols,
            new_rows,
        );

        // 🎯 调整新终端的尺寸
        let new_terminal_ptr = &mut *new_item.terminal as *mut crate::TerminalHandle;
        eprintln!("[ContextGrid] Resizing new pane terminal to {}x{}", old_cols, new_rows);
        crate::terminal_resize(new_terminal_ptr, old_cols, new_rows);

        new_item.down = old_down;
        new_item.parent = Some(self.current);

        self.inner.insert(new_pane_id, new_item);

        // 更新链表关系
        if let Some(current_item) = self.inner.get_mut(&self.current) {
            current_item.down = Some(new_pane_id);
        }

        // 更新 old_down 的 parent
        if let Some(old_down_key) = old_down {
            if let Some(old_down_item) = self.inner.get_mut(&old_down_key) {
                old_down_item.parent = Some(new_pane_id);
            }
        }

        // 设置新 pane 为激活状态
        self.current = new_pane_id;

        // 重新计算位置
        self.calculate_positions_for_affected_nodes(&[self.current, new_pane_id]);

        eprintln!("[ContextGrid] split_down completed, new pane: {}", new_pane_id);

        Some(new_pane_id)
    }

    /// 关闭指定 pane
    pub fn close_pane(&mut self, pane_id: usize) -> bool {
        // 不能关闭最后一个 pane
        if self.inner.len() <= 1 {
            return false;
        }

        let item = if let Some(item) = self.inner.get(&pane_id) {
            item
        } else {
            return false;
        };

        let parent = item.parent;
        let right = item.right;
        let down = item.down;

        // 删除 pane
        self.inner.remove(&pane_id);

        // 重新链接链表
        if let Some(parent_key) = parent {
            if let Some(parent_item) = self.inner.get_mut(&parent_key) {
                if parent_item.right == Some(pane_id) {
                    parent_item.right = right;
                } else if parent_item.down == Some(pane_id) {
                    parent_item.down = down;
                }
            }
        }

        // 更新 right/down 的 parent
        if let Some(right_key) = right {
            if let Some(right_item) = self.inner.get_mut(&right_key) {
                right_item.parent = parent;
            }
        }
        if let Some(down_key) = down {
            if let Some(down_item) = self.inner.get_mut(&down_key) {
                down_item.parent = parent;
            }
        }

        // 如果删除的是当前激活的 pane，切换到第一个可用的
        if self.current == pane_id {
            self.current = self.inner.keys().next().copied().unwrap_or(0);
        }

        // 如果删除的是 root，更新 root
        if self.root == Some(pane_id) {
            self.root = self.inner.keys().next().copied();
        }

        // 重新计算布局
        if let Some(root) = self.root {
            self.calculate_positions_for_affected_nodes(&[root]);
        }

        true
    }
    */

    /// 设置激活的 pane
    pub fn set_current(&mut self, pane_id: usize) -> bool {
        if self.inner.contains_key(&pane_id) {
            self.current = pane_id;
            true
        } else {
            false
        }
    }

    /// ✅ 检查 pane 是否存在
    pub fn has_pane(&self, pane_id: usize) -> bool {
        self.inner.contains_key(&pane_id)
    }

    /// ✅ 添加新的 pane（由 Swift 调用）
    pub fn add_pane(
        &mut self,
        pane_id: usize,
        terminal: Box<TerminalHandle>,
        rich_text_id: usize,
        cols: u16,
        rows: u16,
    ) {
        let item = ContextGridItem::new(pane_id, terminal, rich_text_id, cols, rows);
        self.inner.insert(pane_id, item);
        eprintln!("[ContextGrid] Added pane {} with grid {}x{}", pane_id, cols, rows);
    }

    /// ✅ 让 Swift 设置 pane 位置
    pub fn set_pane_position(&mut self, pane_id: usize, x: f32, y: f32) {
        if let Some(item) = self.inner.get_mut(&pane_id) {
            // 转换为逻辑坐标
            let logical_x = x / self.scale;
            let logical_y = y / self.scale;
            item.set_position([logical_x, logical_y]);

            eprintln!("[ContextGrid] Set pane {} position: ({}, {}) logical, ({}, {}) physical",
                      pane_id, logical_x, logical_y, x, y);
        } else {
            eprintln!("[ContextGrid] ⚠️ Pane {} not found when setting position", pane_id);
        }
    }

    /// ✅ 让 Swift 设置 pane 尺寸
    pub fn set_pane_size(&mut self, pane_id: usize, cols: u16, rows: u16) {
        if let Some(item) = self.inner.get_mut(&pane_id) {
            if item.cols != cols || item.rows != rows {
                item.cols = cols;
                item.rows = rows;

                let terminal_ptr = &mut *item.terminal as *mut TerminalHandle;
                crate::terminal_resize(terminal_ptr, cols, rows);

                eprintln!("[ContextGrid] Resized pane {} terminal: {}x{}", pane_id, cols, rows);
            }
        } else {
            eprintln!("[ContextGrid] ⚠️ Pane {} not found when setting size", pane_id);
        }
    }

    // ❌ 删除：重新计算受影响节点的位置（不再需要，Swift 负责布局）
    /*
    fn calculate_positions_for_affected_nodes(&mut self, _affected: &[usize]) {
        if let Some(root) = self.root {
            self.calculate_positions_recursive(root, 0.0, 0.0);
        }
    }

    fn calculate_positions_recursive(&mut self, pane_id: usize, x: f32, y: f32) {
        // 获取当前 pane 的信息
        let (right, down, width, height) = {
            let item = if let Some(item) = self.inner.get(&pane_id) {
                item
            } else {
                eprintln!("[ContextGrid] ⚠️ Pane {} not found in calculate_positions", pane_id);
                return;
            };
            (item.right, item.down, item.dimension.width, item.dimension.height)
        };

        // 设置当前 pane 的位置（转换为逻辑坐标）
        if let Some(item) = self.inner.get_mut(&pane_id) {
            // RichText 的 position 需要逻辑坐标，Sugarloaf 内部会乘以 scale_factor
            let logical_x = x / self.scale;
            let logical_y = y / self.scale;
            item.set_position([logical_x, logical_y]);
            eprintln!("[ContextGrid] Pane {} -> position: [{}, {}] (physical: [{}, {}]), size: [{}x{}]",
                      pane_id, logical_x, logical_y, x, y, width, height);
        }

        // 递归处理右侧 pane
        if let Some(right_id) = right {
            let next_x = x + width + self.scaled_padding;
            eprintln!("[ContextGrid] Moving right from pane {} to pane {}, next_x: {}",
                      pane_id, right_id, next_x);
            self.calculate_positions_recursive(
                right_id,
                next_x,
                y,
            );
        }

        // 递归处理下方 pane
        if let Some(down_id) = down {
            let next_y = y + height + self.scaled_padding;
            eprintln!("[ContextGrid] Moving down from pane {} to pane {}, next_y: {}",
                      pane_id, down_id, next_y);
            self.calculate_positions_recursive(
                down_id,
                x,
                next_y,
            );
        }
    }
    */

    /// ✅ 修改：objects() 不计算位置，直接使用已设置的位置
    pub fn objects(&self) -> Vec<Object> {
        eprintln!("[ContextGrid] Generating objects for {} panes", self.inner.len());
        let mut objects = Vec::new();

        // 添加所有 pane 的 RichText
        for item in self.inner.values() {
            let pos = item.position();
            eprintln!("[ContextGrid] -> Pane {} RichText at position [{}, {}]",
                      item.pane_id, pos[0], pos[1]);
            objects.push(item.get_rich_text_object().clone());
        }

        eprintln!("[ContextGrid] Total objects: {}", objects.len());
        objects
    }

    // ❌ 删除：resize 相关方法（Swift 负责布局和尺寸管理）
    /*
    pub fn resize(&mut self, width: f32, height: f32) {
        eprintln!("[ContextGrid] resize called: old={}x{}, new={}x{}",
                  self.width, self.height, width, height);

        // 计算缩放比例
        let width_ratio = if self.width > 0.0 { width / self.width } else { 1.0 };
        let height_ratio = if self.height > 0.0 { height / self.height } else { 1.0 };

        eprintln!("[ContextGrid] Scale ratios: width={:.2}, height={:.2}",
                  width_ratio, height_ratio);

        self.width = width;
        self.height = height;

        // 递归调整所有 pane 的尺寸
        if let Some(root) = self.root {
            self.resize_pane_recursive(root, width_ratio, height_ratio);
            self.calculate_positions_for_affected_nodes(&[root]);
        }
    }

    /// 递归调整 pane 的尺寸（保持比例）
    fn resize_pane_recursive(&mut self, pane_id: usize, width_ratio: f32, height_ratio: f32) {
        // 获取当前 pane 的链表信息
        let (right, down) = {
            let item = if let Some(item) = self.inner.get(&pane_id) {
                item
            } else {
                return;
            };
            (item.right, item.down)
        };

        // 调整当前 pane 的尺寸
        if let Some(item) = self.inner.get_mut(&pane_id) {
            let old_width = item.dimension.width;
            let old_height = item.dimension.height;
            let old_margin = item.dimension.margin;

            // 按比例缩放尺寸
            let new_width = old_width * width_ratio;
            let new_height = old_height * height_ratio;

            // 按比例缩放 margin
            let mut new_margin = old_margin;
            new_margin.x *= width_ratio;
            new_margin.top_y *= height_ratio;
            new_margin.bottom_y *= height_ratio;

            item.dimension.update_width(new_width);
            item.dimension.update_height(new_height);
            item.dimension.update_margin(new_margin);

            eprintln!("[ContextGrid] Pane {} resized: {}x{} -> {}x{}",
                      pane_id, old_width, old_height, new_width, new_height);

            // 🎯 重新计算终端网格尺寸（基于新的 pane 尺寸）
            let font_metrics = crate::global_font_metrics().unwrap_or_else(|| {
                crate::SugarloafFontMetrics::fallback(14.0)
            });

            // new_width 和 new_height 本身就是逻辑坐标，直接使用
            // 计算新的 cols 和 rows
            let new_cols = ((new_width / font_metrics.cell_width).max(1.0) as u16).max(2);
            let new_rows = ((new_height / font_metrics.line_height).max(1.0) as u16).max(1);

            eprintln!("[ContextGrid] Pane {} terminal grid: {}x{} -> {}x{}",
                      pane_id, item.cols, item.rows, new_cols, new_rows);

            // 更新终端网格尺寸
            item.cols = new_cols;
            item.rows = new_rows;

            // 调用 terminal_resize
            let terminal_ptr = &mut *item.terminal as *mut crate::TerminalHandle;
            crate::terminal_resize(terminal_ptr, new_cols, new_rows);
        }

        // 递归处理右侧 pane
        if let Some(right_id) = right {
            self.resize_pane_recursive(right_id, width_ratio, height_ratio);
        }

        // 递归处理下方 pane
        if let Some(down_id) = down {
            self.resize_pane_recursive(down_id, width_ratio, height_ratio);
        }
    }

    /// 根据坐标查找对应的 pane（用于点击切换焦点）
    /// x, y 是逻辑坐标
    pub fn get_pane_at_position(&self, x: f32, y: f32) -> Option<usize> {
        for item in self.inner.values() {
            let pos = item.position();
            let width = item.dimension.width / self.scale;  // 转换为逻辑坐标
            let height = item.dimension.height / self.scale;

            if x >= pos[0] && x < pos[0] + width &&
               y >= pos[1] && y < pos[1] + height {
                eprintln!("[ContextGrid] Click at ({}, {}) -> Pane {}", x, y, item.pane_id);
                return Some(item.pane_id);
            }
        }
        eprintln!("[ContextGrid] Click at ({}, {}) -> No pane found", x, y);
        None
    }

    /// 获取指定 pane 的位置和尺寸信息（逻辑坐标）
    pub fn get_pane_info(&self, pane_id: usize) -> Option<(f32, f32, f32, f32)> {
        self.inner.get(&pane_id).map(|item| {
            let pos = item.position();
            let width = item.dimension.width / self.scale;
            let height = item.dimension.height / self.scale;
            (pos[0], pos[1], width, height)
        })
    }

    /// 获取所有分隔线的信息
    pub fn get_dividers(&self) -> Vec<DividerInfo> {
        let mut dividers = Vec::new();

        for item in self.inner.values() {
            // 检查右侧 pane（垂直分隔线）
            if let Some(right_id) = item.right {
                if self.inner.contains_key(&right_id) {
                    // 分隔线位置 = 左 pane 的 x + width
                    let divider_x = item.position()[0] + (item.dimension.width / self.scale);
                    dividers.push(DividerInfo {
                        pane_id_1: item.pane_id,
                        pane_id_2: right_id,
                        divider_type: 0,  // vertical
                        position: divider_x,
                    });
                }
            }

            // 检查下方 pane（水平分隔线）
            if let Some(down_id) = item.down {
                if self.inner.contains_key(&down_id) {
                    // 分隔线位置 = 上 pane 的 y + height
                    let divider_y = item.position()[1] + (item.dimension.height / self.scale);
                    dividers.push(DividerInfo {
                        pane_id_1: item.pane_id,
                        pane_id_2: down_id,
                        divider_type: 1,  // horizontal
                        position: divider_y,
                    });
                }
            }
        }

        dividers
    }

    /// 调整分隔线位置（调整相邻两个 pane 的大小）
    /// delta: 正数表示向右/下移动，负数表示向左/上移动（逻辑坐标）
    pub fn resize_divider(
        &mut self,
        pane_id_1: usize,
        pane_id_2: usize,
        delta: f32,  // 逻辑坐标的偏移量
    ) -> bool {
        eprintln!("[ContextGrid] resize_divider: pane {} <-> {}, delta: {}",
                  pane_id_1, pane_id_2, delta);

        // 检查是垂直还是水平分隔线
        let is_vertical = {
            if let Some(pane_1) = self.inner.get(&pane_id_1) {
                pane_1.right == Some(pane_id_2)
            } else {
                return false;
            }
        };

        if is_vertical {
            self.resize_vertical_divider(pane_id_1, pane_id_2, delta)
        } else {
            self.resize_horizontal_divider(pane_id_1, pane_id_2, delta)
        }
    }

    /// 调整垂直分隔线（左右分割）
    fn resize_vertical_divider(
        &mut self,
        left_pane_id: usize,
        right_pane_id: usize,
        delta: f32,
    ) -> bool {
        // 最小 pane 宽度（逻辑坐标）
        const MIN_PANE_WIDTH: f32 = 100.0;

        // 获取当前尺寸
        let (left_width, right_width) = {
            let left = match self.inner.get(&left_pane_id) {
                Some(p) => p,
                None => return false,
            };
            let right = match self.inner.get(&right_pane_id) {
                Some(p) => p,
                None => return false,
            };
            (left.dimension.width / self.scale, right.dimension.width / self.scale)
        };

        // 计算新尺寸（确保不小于最小值）
        let new_left_width = (left_width + delta).max(MIN_PANE_WIDTH);
        let new_right_width = (right_width - delta).max(MIN_PANE_WIDTH);

        eprintln!("[ContextGrid] Vertical resize: left {} -> {}, right {} -> {}",
                  left_width, new_left_width, right_width, new_right_width);

        // 先计算新的列数（避免借用冲突）
        let new_left_width_pixels = new_left_width * self.scale;
        let new_right_width_pixels = new_right_width * self.scale;
        let new_left_cols = self.calculate_cols(new_left_width_pixels);
        let new_right_cols = self.calculate_cols(new_right_width_pixels);

        // 更新左 pane 尺寸
        if let Some(left_pane) = self.inner.get_mut(&left_pane_id) {
            left_pane.dimension.update_width(new_left_width_pixels);
            left_pane.cols = new_left_cols;
            let left_rows = left_pane.rows;
            let terminal_ptr = &mut *left_pane.terminal as *mut crate::TerminalHandle;
            eprintln!("[ContextGrid] Resizing left pane terminal to {}x{}", new_left_cols, left_rows);
            crate::terminal_resize(terminal_ptr, new_left_cols, left_rows);
        }

        // 更新右 pane 尺寸
        if let Some(right_pane) = self.inner.get_mut(&right_pane_id) {
            right_pane.dimension.update_width(new_right_width_pixels);
            right_pane.cols = new_right_cols;
            let right_rows = right_pane.rows;
            let terminal_ptr = &mut *right_pane.terminal as *mut crate::TerminalHandle;
            eprintln!("[ContextGrid] Resizing right pane terminal to {}x{}", new_right_cols, right_rows);
            crate::terminal_resize(terminal_ptr, new_right_cols, right_rows);
        }

        // 重新计算所有位置
        self.calculate_positions_for_affected_nodes(&[left_pane_id, right_pane_id]);

        true
    }

    /// 调整水平分隔线（上下分割）
    fn resize_horizontal_divider(
        &mut self,
        top_pane_id: usize,
        bottom_pane_id: usize,
        delta: f32,
    ) -> bool {
        // 最小 pane 高度（逻辑坐标）
        const MIN_PANE_HEIGHT: f32 = 50.0;

        // 获取当前尺寸
        let (top_height, bottom_height) = {
            let top = match self.inner.get(&top_pane_id) {
                Some(p) => p,
                None => return false,
            };
            let bottom = match self.inner.get(&bottom_pane_id) {
                Some(p) => p,
                None => return false,
            };
            (top.dimension.height / self.scale, bottom.dimension.height / self.scale)
        };

        // 计算新尺寸（确保不小于最小值）
        let new_top_height = (top_height + delta).max(MIN_PANE_HEIGHT);
        let new_bottom_height = (bottom_height - delta).max(MIN_PANE_HEIGHT);

        eprintln!("[ContextGrid] Horizontal resize: top {} -> {}, bottom {} -> {}",
                  top_height, new_top_height, bottom_height, new_bottom_height);

        // 先计算新的行数（避免借用冲突）
        let new_top_height_pixels = new_top_height * self.scale;
        let new_bottom_height_pixels = new_bottom_height * self.scale;
        let new_top_rows = self.calculate_rows(new_top_height_pixels);
        let new_bottom_rows = self.calculate_rows(new_bottom_height_pixels);

        // 更新上 pane 尺寸
        if let Some(top_pane) = self.inner.get_mut(&top_pane_id) {
            top_pane.dimension.update_height(new_top_height_pixels);
            top_pane.rows = new_top_rows;
            let top_cols = top_pane.cols;
            let terminal_ptr = &mut *top_pane.terminal as *mut crate::TerminalHandle;
            eprintln!("[ContextGrid] Resizing top pane terminal to {}x{}", top_cols, new_top_rows);
            crate::terminal_resize(terminal_ptr, top_cols, new_top_rows);
        }

        // 更新下 pane 尺寸
        if let Some(bottom_pane) = self.inner.get_mut(&bottom_pane_id) {
            bottom_pane.dimension.update_height(new_bottom_height_pixels);
            bottom_pane.rows = new_bottom_rows;
            let bottom_cols = bottom_pane.cols;
            let terminal_ptr = &mut *bottom_pane.terminal as *mut crate::TerminalHandle;
            eprintln!("[ContextGrid] Resizing bottom pane terminal to {}x{}", bottom_cols, new_bottom_rows);
            crate::terminal_resize(terminal_ptr, bottom_cols, new_bottom_rows);
        }

        // 重新计算所有位置
        self.calculate_positions_for_affected_nodes(&[top_pane_id, bottom_pane_id]);

        true
    }
    */

    // ✅ 保留：辅助方法（用于终端尺寸计算）
    fn calculate_cols(&self, width_pixels: f32) -> u16 {
        let metrics = crate::global_font_metrics().unwrap_or_else(|| {
            crate::SugarloafFontMetrics::fallback(14.0)
        });
        // metrics.cell_width 是像素值，width_pixels 也是像素值
        let cols = (width_pixels / metrics.cell_width).max(2.0) as u16;
        cols
    }

    /// 根据像素高度计算终端行数
    fn calculate_rows(&self, height_pixels: f32) -> u16 {
        let metrics = crate::global_font_metrics().unwrap_or_else(|| {
            crate::SugarloafFontMetrics::fallback(14.0)
        });
        // metrics.line_height 是像素值，height_pixels 也是像素值
        let rows = (height_pixels / metrics.line_height).max(1.0) as u16;
        rows
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_context_grid_creation() {
        // 这里需要实际的 TerminalHandle，暂时跳过
        // let grid = ContextGrid::new(...);
        // assert_eq!(grid.len(), 1);
    }
}
