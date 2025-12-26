//! Renderable State Trait - 可渲染状态抽象
//!
//! 设计目标：
//! - 统一 TerminalState 和 RenderState 的渲染接口
//! - Renderer 可以同时使用两种 state 类型
//! - 支持渐进式迁移

use rio_backend::ansi::CursorShape;

use super::views::{
    GridView, HyperlinkHoverView, ImeView, RowView, SearchView, SelectionView,
};
use super::AbsolutePoint;

/// 可渲染状态 trait
///
/// 该 trait 抽象了 Renderer 需要的所有接口，允许使用：
/// - TerminalState（当前实现，从 Crosswords 快照）
/// - RenderState（增量同步，高效）
///
/// # 设计原则
/// - 只读接口，无可变方法
/// - 返回引用或克隆成本低的类型
/// - 与 Renderer 现有代码兼容
pub trait RenderableState {
    // ==================== Grid 接口 ====================

    /// 获取 GridView 引用
    fn grid(&self) -> &GridView;

    /// 快捷方法：获取指定屏幕行
    #[inline]
    fn row(&self, screen_line: usize) -> Option<RowView> {
        self.grid().row(screen_line)
    }

    /// 快捷方法：获取列数
    #[inline]
    fn columns(&self) -> usize {
        self.grid().columns()
    }

    /// 快捷方法：获取屏幕行数
    #[inline]
    fn lines(&self) -> usize {
        self.grid().lines()
    }

    /// 快捷方法：获取历史行数
    #[inline]
    fn history_size(&self) -> usize {
        self.grid().history_size()
    }

    /// 快捷方法：获取显示偏移
    #[inline]
    fn display_offset(&self) -> usize {
        self.grid().display_offset()
    }

    /// 快捷方法：获取行哈希
    #[inline]
    fn row_hash(&self, screen_line: usize) -> Option<u64> {
        self.grid().row_hash(screen_line)
    }

    // ==================== Cursor 接口 ====================

    /// 获取光标位置（绝对坐标）
    fn cursor_position(&self) -> AbsolutePoint;

    /// 获取光标形状
    fn cursor_shape(&self) -> CursorShape;

    /// 光标是否可见
    fn cursor_visible(&self) -> bool;

    /// 获取光标颜色 [r, g, b, a] (f32, 0.0-1.0)
    fn cursor_color(&self) -> [f32; 4];

    // ==================== 叠加层视图 ====================

    /// 获取选区视图
    fn selection(&self) -> Option<&SelectionView>;

    /// 获取搜索视图
    fn search(&self) -> Option<&SearchView>;

    /// 获取超链接悬停视图
    fn hyperlink_hover(&self) -> Option<&HyperlinkHoverView>;

    /// 获取输入法视图
    fn ime(&self) -> Option<&ImeView>;
}

// ==================== TerminalState 实现 ====================

impl RenderableState for super::TerminalState {
    fn grid(&self) -> &GridView {
        &self.grid
    }

    fn cursor_position(&self) -> AbsolutePoint {
        self.cursor.position
    }

    fn cursor_shape(&self) -> CursorShape {
        self.cursor.shape
    }

    fn cursor_visible(&self) -> bool {
        self.cursor.is_visible()
    }

    fn cursor_color(&self) -> [f32; 4] {
        self.cursor.color
    }

    fn selection(&self) -> Option<&SelectionView> {
        self.selection.as_ref()
    }

    fn search(&self) -> Option<&SearchView> {
        self.search.as_ref()
    }

    fn hyperlink_hover(&self) -> Option<&HyperlinkHoverView> {
        self.hyperlink_hover.as_ref()
    }

    fn ime(&self) -> Option<&ImeView> {
        self.ime.as_ref()
    }
}
