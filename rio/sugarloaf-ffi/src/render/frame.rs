//! Frame - 渲染输出数据结构
//!
//! 核心概念：
//! - **Frame**: 渲染输出 = Base Layer + Overlays
//! - **BaseLayer**: 纯内容图像（不含状态）
//! - **Overlay**: 叠加层（光标、选区、搜索高亮等）
//!
//! Overlay 分离架构的核心思想：
//!
//! ```text
//! ┌─────────────────────────────────────┐
//! │          最终 Surface               │
//! ├─────────────────────────────────────┤
//! │  Overlay N: 搜索高亮 (半透明矩形)    │  ← 状态层（每帧重绘）
//! │  Overlay 2: 选区 (半透明矩形)        │  ← 状态层（每帧重绘）
//! │  Overlay 1: 光标 (Block/Caret/...)  │  ← 状态层（每帧重绘）
//! ├─────────────────────────────────────┤
//! │  Base Layer: 纯内容 Image           │  ← 内容层（高缓存命中率）
//! │  (hash → Image, 不含任何状态)        │
//! └─────────────────────────────────────┘
//! ```
//!
//! 设计收益：
//! - **高缓存命中率**：BaseLayer 只包含文本内容，很少变化
//! - **状态分离**：光标、选区等状态不污染 BaseLayer 缓存
//! - **灵活扩展**：新增 Overlay 类型不影响现有缓存
//! - **高效渲染**：Overlay 是简单几何图形，重绘成本低
//!
//! Phase 1 设计原则：
//! - 先定义数据结构（类型、方法）
//! - 暂不包含真实图像数据（等 Phase 2 集成 Skia）
//! - 使用简单的占位类型（width/height、RGB float）
//! - 完善的文档和测试

use rio_backend::ansi::CursorShape;
use crate::domain::selection::SelectionType;

/// Frame - 渲染输出
///
/// 代表一帧完整的渲染输出，由基础内容层和叠加层组成。
///
/// # 架构说明
///
/// Frame 采用 Overlay 分离架构：
/// - **base**: 纯内容层（文本内容，不含状态）
/// - **overlays**: 状态叠加层（光标、选区、搜索高亮等）
///
/// # 渲染流程
///
/// ```text
/// TerminalState
///     ↓
/// RenderContext::render()
///     ↓
/// Frame { base, overlays }
///     ↓
/// Compositor::composite()
///     ↓
/// Final Surface
/// ```
///
/// # Phase 1 说明
///
/// 当前版本是数据结构定义阶段：
/// - BaseLayer 暂时只包含尺寸信息（width/height）
/// - Phase 2 会添加真实的图像数据（SkImage）
#[derive(Debug, Clone)]
pub struct Frame {
    /// 基础内容层（纯文本，不含状态）
    pub base: BaseLayer,
    /// 叠加层列表（光标、选区、搜索高亮等）
    pub overlays: Vec<Overlay>,
}

/// BaseLayer - 基础内容层
///
/// 包含纯文本内容的图像，不包含任何状态信息（光标、选区等）。
///
/// # 设计原则
///
/// - **纯内容**：只包含文本内容，不混入状态
/// - **高缓存命中率**：内容很少变化（只有打字、滚动时才变）
/// - **状态无关**：光标移动、选区变化不影响 BaseLayer
///
/// # Phase 1 说明
///
/// 当前版本只包含尺寸信息：
/// - `width`: 图像宽度（像素）
/// - `height`: 图像高度（像素）
///
/// Phase 2 会添加：
/// - `image: SkImage`: 真实的 Skia 图像对象
/// - 或使用 `SkSurface` 等其他 Skia 类型
#[derive(Debug, Clone)]
pub struct BaseLayer {
    /// 图像宽度（像素）
    pub width: u32,
    /// 图像高度（像素）
    pub height: u32,
    // TODO(Phase 2): 添加真实的图像数据
    // pub image: SkImage,
}

/// Overlay - 叠加层
///
/// 代表需要叠加在 BaseLayer 上的状态元素。
///
/// # 坐标系说明
///
/// **所有行号都使用绝对坐标**（在整个 Grid 中的位置，包括历史滚动内容）。
///
/// - `absolute_row` / `absolute_line`: 绝对行号（0-based，从 Grid 顶部开始）
/// - `col`: 列号（0-based，从行首开始）
///
/// RenderContext 负责将绝对坐标转换为屏幕坐标（减去 display_offset）。
///
/// # 示例
///
/// ```
/// // 光标在 Grid 的第 100 行，第 5 列
/// let cursor = Overlay::Cursor {
///     absolute_row: 100,
///     col: 5,
///     shape: CursorShape::Block,
/// };
///
/// // 如果 display_offset = 80，渲染时会显示在屏幕的第 20 行
/// ```
///
/// # 设计原则
///
/// - **简单几何**：每个 Overlay 是简单的几何图形（矩形、线条等）
/// - **每帧重绘**：Overlay 每帧重新计算和绘制，成本低
/// - **状态分离**：不污染 BaseLayer 缓存
///
/// # 当前支持的 Overlay 类型
///
/// - **Cursor**: 光标（Block、Beam、Underline 等）
/// - **Selection**: 选区（半透明矩形）
/// - **SearchMatch**: 搜索高亮（半透明矩形）
///
/// # 后续 Step 会添加
///
/// - **DirtyHint**: 脏区域提示（调试用）
#[derive(Debug, Clone, PartialEq)]
pub enum Overlay {
    /// 光标叠加层
    ///
    /// 包含光标的位置和形状。颜色由渲染器根据主题配置决定（Phase 2 实现）。
    ///
    /// # 字段说明
    ///
    /// - `absolute_row`: 光标所在行（绝对坐标，0-based）
    /// - `col`: 光标所在列（0-based）
    /// - `shape`: 光标形状（Block、Beam、Underline 等）
    Cursor {
        absolute_row: usize,
        col: usize,
        shape: CursorShape,
    },
    /// 选区叠加层
    ///
    /// 包含选区的起点、终点和类型。颜色由渲染器根据主题配置决定（Phase 2 实现）。
    ///
    /// # 字段说明
    ///
    /// - `start_absolute_line`: 起点行号（绝对坐标，0-based）
    /// - `start_col`: 起点列号（0-based）
    /// - `end_absolute_line`: 终点行号（绝对坐标，0-based）
    /// - `end_col`: 终点列号（0-based）
    /// - `ty`: 选区类型（Simple、Block、Lines）
    Selection {
        start_absolute_line: usize,
        start_col: usize,
        end_absolute_line: usize,
        end_col: usize,
        ty: SelectionType,
    },
    /// 搜索匹配叠加层
    ///
    /// 包含搜索匹配的位置和是否为焦点匹配。颜色由渲染器根据主题配置决定（Phase 2 实现）。
    ///
    /// # 字段说明
    ///
    /// - `start_absolute_line`: 起点行号（绝对坐标，0-based）
    /// - `start_col`: 起点列号（0-based）
    /// - `end_absolute_line`: 终点行号（绝对坐标，0-based）
    /// - `end_col`: 终点列号（0-based）
    /// - `is_focused`: 是否为当前焦点匹配（焦点匹配可以用不同颜色渲染）
    SearchMatch {
        start_absolute_line: usize,
        start_col: usize,
        end_absolute_line: usize,
        end_col: usize,
        is_focused: bool,
    },
}

impl Frame {
    /// 创建新的 Frame
    ///
    /// # 参数
    ///
    /// - `base`: 基础内容层
    /// - `overlays`: 叠加层列表
    ///
    /// # 示例
    ///
    /// ```ignore
    /// let base = BaseLayer::new(800, 600);
    /// let overlays = vec![
    ///     Overlay::Cursor { absolute_row: 10, col: 5, shape: CursorShape::Block },
    /// ];
    /// let frame = Frame::new(base, overlays);
    /// ```
    pub fn new(base: BaseLayer, overlays: Vec<Overlay>) -> Self {
        Self { base, overlays }
    }

    /// 获取 Overlay 数量
    ///
    /// 用于统计、调试和性能分析。
    #[inline]
    pub fn overlay_count(&self) -> usize {
        self.overlays.len()
    }

    /// 判断是否有 Overlay
    #[inline]
    pub fn has_overlays(&self) -> bool {
        !self.overlays.is_empty()
    }
}

impl BaseLayer {
    /// 创建新的 BaseLayer
    ///
    /// # 参数
    ///
    /// - `width`: 图像宽度（像素）
    /// - `height`: 图像高度（像素）
    ///
    /// # Phase 1 说明
    ///
    /// 当前只存储尺寸信息，Phase 2 会接受真实的图像对象。
    ///
    /// # 示例
    ///
    /// ```ignore
    /// let base = BaseLayer::new(800, 600);
    /// assert_eq!(base.width, 800);
    /// assert_eq!(base.height, 600);
    /// ```
    pub fn new(width: u32, height: u32) -> Self {
        Self { width, height }
    }

    /// 获取图像尺寸（宽度, 高度）
    #[inline]
    pub fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    /// 测试：验证可以构造 Frame
    #[test]
    fn test_frame_construction() {
        let base = BaseLayer::new(800, 600);
        let overlays = vec![];
        let frame = Frame::new(base, overlays);

        // 验证基本属性
        assert_eq!(frame.base.width, 800);
        assert_eq!(frame.base.height, 600);
        assert_eq!(frame.overlay_count(), 0);
        assert!(!frame.has_overlays());
    }

    /// 测试：验证可以添加光标 overlay
    #[test]
    fn test_frame_with_cursor_overlay() {
        let base = BaseLayer::new(1024, 768);
        let cursor = Overlay::Cursor {
            absolute_row: 10,
            col: 5,
            shape: CursorShape::Block,
        };
        let overlays = vec![cursor];
        let frame = Frame::new(base, overlays);

        // 验证 overlay
        assert_eq!(frame.overlay_count(), 1);
        assert!(frame.has_overlays());

        // 验证 cursor overlay 的内容
        match &frame.overlays[0] {
            Overlay::Cursor { absolute_row, col, shape } => {
                assert_eq!(*absolute_row, 10);
                assert_eq!(*col, 5);
                assert_eq!(*shape, CursorShape::Block);
            }
            _ => panic!("Expected Cursor overlay"),
        }
    }

    /// 测试：验证 overlay 计数
    #[test]
    fn test_frame_overlay_count() {
        let base = BaseLayer::new(800, 600);

        // 0 个 overlay
        let frame0 = Frame::new(base.clone(), vec![]);
        assert_eq!(frame0.overlay_count(), 0);
        assert!(!frame0.has_overlays());

        // 1 个 overlay
        let cursor1 = Overlay::Cursor {
            absolute_row: 0,
            col: 0,
            shape: CursorShape::Beam,
        };
        let frame1 = Frame::new(base.clone(), vec![cursor1]);
        assert_eq!(frame1.overlay_count(), 1);
        assert!(frame1.has_overlays());

        // 3 个 overlays
        let cursor2 = Overlay::Cursor {
            absolute_row: 1,
            col: 1,
            shape: CursorShape::Underline,
        };
        let cursor3 = Overlay::Cursor {
            absolute_row: 2,
            col: 2,
            shape: CursorShape::Block,
        };
        let frame3 = Frame::new(
            base,
            vec![
                Overlay::Cursor {
                    absolute_row: 0,
                    col: 0,
                    shape: CursorShape::Beam,
                },
                cursor2,
                cursor3,
            ],
        );
        assert_eq!(frame3.overlay_count(), 3);
        assert!(frame3.has_overlays());
    }

    /// 测试：验证 BaseLayer 尺寸
    #[test]
    fn test_base_layer_dimensions() {
        let base1 = BaseLayer::new(800, 600);
        assert_eq!(base1.width, 800);
        assert_eq!(base1.height, 600);
        assert_eq!(base1.dimensions(), (800, 600));

        let base2 = BaseLayer::new(1920, 1080);
        assert_eq!(base2.width, 1920);
        assert_eq!(base2.height, 1080);
        assert_eq!(base2.dimensions(), (1920, 1080));
    }

    /// 测试：验证不同光标形状
    #[test]
    fn test_overlay_cursor_shapes() {
        let shapes = vec![
            CursorShape::Block,
            CursorShape::Beam,
            CursorShape::Underline,
            CursorShape::Hidden,
        ];

        for (idx, shape) in shapes.iter().enumerate() {
            let cursor = Overlay::Cursor {
                absolute_row: idx,
                col: idx,
                shape: *shape,
            };

            match cursor {
                Overlay::Cursor { shape: s, .. } => {
                    assert_eq!(s, *shape);
                }
                _ => panic!("Expected Cursor overlay"),
            }
        }
    }

    /// 测试：验证 Overlay 的 PartialEq
    #[test]
    fn test_overlay_equality() {
        let cursor1 = Overlay::Cursor {
            absolute_row: 10,
            col: 5,
            shape: CursorShape::Block,
        };
        let cursor2 = Overlay::Cursor {
            absolute_row: 10,
            col: 5,
            shape: CursorShape::Block,
        };
        let cursor3 = Overlay::Cursor {
            absolute_row: 10,
            col: 6,
            shape: CursorShape::Block,
        }; // 不同的 col

        assert_eq!(cursor1, cursor2);
        assert_ne!(cursor1, cursor3);
    }

    /// 测试：验证可以添加选区 overlay
    #[test]
    fn test_frame_with_selection_overlay() {
        let base = BaseLayer::new(1024, 768);
        let selection = Overlay::Selection {
            start_absolute_line: 0,
            start_col: 0,
            end_absolute_line: 5,
            end_col: 20,
            ty: SelectionType::Simple,
        };
        let overlays = vec![selection];
        let frame = Frame::new(base, overlays);

        // 验证 overlay
        assert_eq!(frame.overlay_count(), 1);
        assert!(frame.has_overlays());

        // 验证 selection overlay 的内容
        match &frame.overlays[0] {
            Overlay::Selection { start_absolute_line, start_col, end_absolute_line, end_col, ty } => {
                assert_eq!(*start_absolute_line, 0);
                assert_eq!(*start_col, 0);
                assert_eq!(*end_absolute_line, 5);
                assert_eq!(*end_col, 20);
                assert_eq!(*ty, SelectionType::Simple);
            }
            _ => panic!("Expected Selection overlay"),
        }
    }

    /// 测试：验证 Selection overlay 构造
    #[test]
    fn test_overlay_selection_construction() {
        // Simple 类型选区
        let simple = Overlay::Selection {
            start_absolute_line: 0,
            start_col: 0,
            end_absolute_line: 10,
            end_col: 30,
            ty: SelectionType::Simple,
        };

        match simple {
            Overlay::Selection { ty, .. } => {
                assert_eq!(ty, SelectionType::Simple);
            }
            _ => panic!("Expected Selection overlay"),
        }

        // Block 类型选区
        let block = Overlay::Selection {
            start_absolute_line: 5,
            start_col: 10,
            end_absolute_line: 15,
            end_col: 20,
            ty: SelectionType::Block,
        };

        match block {
            Overlay::Selection { ty, .. } => {
                assert_eq!(ty, SelectionType::Block);
            }
            _ => panic!("Expected Selection overlay"),
        }

        // Lines 类型选区
        let lines = Overlay::Selection {
            start_absolute_line: 2,
            start_col: 0,
            end_absolute_line: 8,
            end_col: 79,
            ty: SelectionType::Lines,
        };

        match lines {
            Overlay::Selection { ty, .. } => {
                assert_eq!(ty, SelectionType::Lines);
            }
            _ => panic!("Expected Selection overlay"),
        }
    }

    /// 测试：验证多个 overlay（光标 + 选区）
    #[test]
    fn test_frame_with_cursor_and_selection() {
        let base = BaseLayer::new(800, 600);

        let cursor = Overlay::Cursor {
            absolute_row: 10,
            col: 5,
            shape: CursorShape::Block,
        };

        let selection = Overlay::Selection {
            start_absolute_line: 0,
            start_col: 0,
            end_absolute_line: 5,
            end_col: 20,
            ty: SelectionType::Simple,
        };

        let overlays = vec![selection, cursor];
        let frame = Frame::new(base, overlays);

        // 验证有两个 overlays
        assert_eq!(frame.overlay_count(), 2);
        assert!(frame.has_overlays());

        // 验证第一个是 selection
        match &frame.overlays[0] {
            Overlay::Selection { .. } => {},
            _ => panic!("Expected Selection overlay at index 0"),
        }

        // 验证第二个是 cursor
        match &frame.overlays[1] {
            Overlay::Cursor { .. } => {},
            _ => panic!("Expected Cursor overlay at index 1"),
        }
    }

    /// 测试：验证可以添加搜索 overlay
    #[test]
    fn test_frame_with_search_overlay() {
        let base = BaseLayer::new(1024, 768);
        let search = Overlay::SearchMatch {
            start_absolute_line: 0,
            start_col: 0,
            end_absolute_line: 0,
            end_col: 5,
            is_focused: true,
        };
        let overlays = vec![search];
        let frame = Frame::new(base, overlays);

        // 验证 overlay
        assert_eq!(frame.overlay_count(), 1);
        assert!(frame.has_overlays());

        // 验证 search overlay 的内容
        match &frame.overlays[0] {
            Overlay::SearchMatch { start_absolute_line, start_col, end_absolute_line, end_col, is_focused } => {
                assert_eq!(*start_absolute_line, 0);
                assert_eq!(*start_col, 0);
                assert_eq!(*end_absolute_line, 0);
                assert_eq!(*end_col, 5);
                assert!(is_focused);
            }
            _ => panic!("Expected SearchMatch overlay"),
        }
    }

    /// 测试：验证焦点和非焦点的搜索 overlay
    #[test]
    fn test_overlay_search_focused_and_normal() {
        // 焦点匹配
        let focused = Overlay::SearchMatch {
            start_absolute_line: 0,
            start_col: 0,
            end_absolute_line: 0,
            end_col: 5,
            is_focused: true,
        };

        match focused {
            Overlay::SearchMatch { is_focused, .. } => {
                assert!(is_focused);
            }
            _ => panic!("Expected SearchMatch overlay"),
        }

        // 非焦点匹配
        let normal = Overlay::SearchMatch {
            start_absolute_line: 1,
            start_col: 10,
            end_absolute_line: 1,
            end_col: 15,
            is_focused: false,
        };

        match normal {
            Overlay::SearchMatch { is_focused, .. } => {
                assert!(!is_focused);
            }
            _ => panic!("Expected SearchMatch overlay"),
        }
    }

    /// 测试：验证多个搜索 overlay（焦点 + 非焦点）
    #[test]
    fn test_frame_with_multiple_search_overlays() {
        let base = BaseLayer::new(800, 600);

        let search1 = Overlay::SearchMatch {
            start_absolute_line: 0,
            start_col: 0,
            end_absolute_line: 0,
            end_col: 5,
            is_focused: false,
        };

        let search2 = Overlay::SearchMatch {
            start_absolute_line: 1,
            start_col: 10,
            end_absolute_line: 1,
            end_col: 15,
            is_focused: true,
        };

        let search3 = Overlay::SearchMatch {
            start_absolute_line: 3,
            start_col: 5,
            end_absolute_line: 3,
            end_col: 10,
            is_focused: false,
        };

        let overlays = vec![search1, search2, search3];
        let frame = Frame::new(base, overlays);

        // 验证有三个 overlays
        assert_eq!(frame.overlay_count(), 3);
        assert!(frame.has_overlays());

        // 验证第二个是焦点匹配
        match &frame.overlays[1] {
            Overlay::SearchMatch { is_focused, .. } => {
                assert!(is_focused);
            }
            _ => panic!("Expected SearchMatch overlay at index 1"),
        }

        // 验证第一个和第三个不是焦点
        match &frame.overlays[0] {
            Overlay::SearchMatch { is_focused, .. } => {
                assert!(!is_focused);
            }
            _ => panic!("Expected SearchMatch overlay at index 0"),
        }

        match &frame.overlays[2] {
            Overlay::SearchMatch { is_focused, .. } => {
                assert!(!is_focused);
            }
            _ => panic!("Expected SearchMatch overlay at index 2"),
        }
    }
}
