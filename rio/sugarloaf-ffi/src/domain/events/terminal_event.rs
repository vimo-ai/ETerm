//! Terminal Events
//!
//! 职责：定义终端事件类型
//!
//! 事件分类：
//! 1. 渲染事件（RenderEvent）：从 Parser 产生，由渲染线程消费
//! 2. 控制事件（TerminalEvent）：从 Crosswords 产生，通知上层

use rio_backend::ansi::CursorShape;
use rio_backend::config::colors::AnsiColor;
use rio_backend::crosswords::pos::{Column, Line};
use rio_backend::crosswords::square::Flags;
use std::ops::Range;

// ============================================================================
// 渲染事件（PTY -> 渲染线程）
// ============================================================================

/// 渲染事件
///
/// 从 Parser 产生，通过 SPSC 队列传递给渲染线程。
/// 设计原则：
/// - 包含足够信息让 RenderState 独立应用
/// - 避免引用外部状态
/// - 支持高效批量处理
#[derive(Debug, Clone)]
pub enum RenderEvent {
    // ===== 单元格更新 =====

    /// 批量单元格更新
    ///
    /// 一行内的连续单元格更新
    CellsUpdate {
        /// 行号（Grid Line 坐标）
        line: Line,
        /// 起始列
        start_col: Column,
        /// 单元格数据
        cells: Vec<CellData>,
    },

    /// 单个字符输入
    ///
    /// 优化路径：大多数输入是单字符
    CharInput {
        /// 行号
        line: Line,
        /// 列号
        col: Column,
        /// 字符
        c: char,
        /// 前景色
        fg: AnsiColor,
        /// 背景色
        bg: AnsiColor,
        /// 标志位
        flags: Flags,
    },

    // ===== 光标操作 =====

    /// 光标移动
    CursorMove {
        /// 新行号
        line: Line,
        /// 新列号
        col: Column,
    },

    /// 光标样式变化
    CursorStyle {
        /// 新样式
        shape: CursorShape,
    },

    /// 光标可见性变化
    CursorVisible {
        /// 是否可见
        visible: bool,
    },

    // ===== 行操作 =====

    /// 换行（LF）
    LineFeed,

    /// 回车（CR）
    CarriageReturn,

    /// 清除行
    ClearLine {
        /// 行号
        line: Line,
        /// 清除模式
        mode: LineClearMode,
    },

    /// 插入空行
    InsertLines {
        /// 起始行
        line: Line,
        /// 行数
        count: usize,
    },

    /// 删除行
    DeleteLines {
        /// 起始行
        line: Line,
        /// 行数
        count: usize,
    },

    // ===== 滚动操作 =====

    /// 向上滚动（内容上移，底部出现新行）
    ScrollUp {
        /// 滚动区域
        region: Range<Line>,
        /// 滚动行数
        lines: usize,
    },

    /// 向下滚动（内容下移，顶部出现新行）
    ScrollDown {
        /// 滚动区域
        region: Range<Line>,
        /// 滚动行数
        lines: usize,
    },

    // ===== 屏幕操作 =====

    /// 清屏
    ClearScreen {
        /// 清除模式
        mode: ScreenClearMode,
    },

    /// 调整大小
    Resize {
        /// 新列数
        cols: usize,
        /// 新行数
        rows: usize,
    },

    // ===== 属性变化 =====

    /// 设置当前属性（用于后续字符）
    SetAttribute {
        /// 前景色
        fg: AnsiColor,
        /// 背景色
        bg: AnsiColor,
        /// 标志位
        flags: Flags,
    },

    // ===== 脏区域标记 =====

    /// 标记脏区域
    Damage {
        /// 是否全屏脏
        full: bool,
        /// 脏行范围（如果不是全屏）
        lines: Option<Range<Line>>,
    },

    // ===== 备用屏幕 =====

    /// 切换到备用屏幕
    EnterAltScreen,

    /// 退出备用屏幕
    ExitAltScreen,
}

/// 单元格数据
///
/// 用于批量更新的单元格表示
#[derive(Debug, Clone)]
pub struct CellData {
    /// 字符
    pub c: char,
    /// 前景色
    pub fg: AnsiColor,
    /// 背景色
    pub bg: AnsiColor,
    /// 标志位
    pub flags: Flags,
}

impl CellData {
    /// 创建新的单元格数据
    pub fn new(c: char, fg: AnsiColor, bg: AnsiColor, flags: Flags) -> Self {
        Self { c, fg, bg, flags }
    }

    /// 创建空单元格
    pub fn empty() -> Self {
        use rio_backend::config::colors::NamedColor;
        Self {
            c: ' ',
            fg: AnsiColor::Named(NamedColor::Foreground),
            bg: AnsiColor::Named(NamedColor::Background),
            flags: Flags::empty(),
        }
    }
}

/// 行清除模式
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineClearMode {
    /// 清除光标右侧（含光标位置）
    Right,
    /// 清除光标左侧（含光标位置）
    Left,
    /// 清除整行
    All,
}

/// 屏幕清除模式
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenClearMode {
    /// 清除光标下方（含光标行）
    Below,
    /// 清除光标上方（含光标行）
    Above,
    /// 清除整个屏幕
    All,
    /// 清除历史缓冲区
    Saved,
}

// ============================================================================
// 控制事件（Crosswords -> 上层）
// ============================================================================

/// 终端控制事件
///
/// 从 Crosswords 产生，通知上层（如 FFI）。
/// 与 rio-backend 的 RioEvent 对应，但简化为只包含必要信息。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TerminalEvent {
    /// 终端响铃
    Bell,

    /// 标题变化
    Title(String),

    /// 终端退出
    Exit,

    /// 需要渲染（唤醒）
    Wakeup,

    /// 当前工作目录变化（OSC 7）
    CurrentDirectoryChanged(String),

    /// Shell 命令执行（OSC 133;C）
    CommandExecuted(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use rio_backend::config::colors::NamedColor;

    #[test]
    fn test_cell_data_new() {
        let cell = CellData::new(
            'A',
            AnsiColor::Named(NamedColor::Red),
            AnsiColor::Named(NamedColor::Background),
            Flags::BOLD,
        );
        assert_eq!(cell.c, 'A');
        assert!(cell.flags.contains(Flags::BOLD));
    }

    #[test]
    fn test_cell_data_empty() {
        let cell = CellData::empty();
        assert_eq!(cell.c, ' ');
        assert!(cell.flags.is_empty());
    }

    #[test]
    fn test_render_event_cells_update() {
        let cells = vec![
            CellData::new('H', AnsiColor::Named(NamedColor::Foreground), AnsiColor::Named(NamedColor::Background), Flags::empty()),
            CellData::new('i', AnsiColor::Named(NamedColor::Foreground), AnsiColor::Named(NamedColor::Background), Flags::empty()),
        ];
        let event = RenderEvent::CellsUpdate {
            line: Line(0),
            start_col: Column(0),
            cells,
        };

        if let RenderEvent::CellsUpdate { line, start_col, cells } = event {
            assert_eq!(line, Line(0));
            assert_eq!(start_col, Column(0));
            assert_eq!(cells.len(), 2);
            assert_eq!(cells[0].c, 'H');
            assert_eq!(cells[1].c, 'i');
        } else {
            panic!("Expected CellsUpdate event");
        }
    }

    #[test]
    fn test_render_event_cursor_move() {
        let event = RenderEvent::CursorMove {
            line: Line(5),
            col: Column(10),
        };

        if let RenderEvent::CursorMove { line, col } = event {
            assert_eq!(line, Line(5));
            assert_eq!(col, Column(10));
        } else {
            panic!("Expected CursorMove event");
        }
    }

    #[test]
    fn test_render_event_scroll() {
        let event = RenderEvent::ScrollUp {
            region: Line(0)..Line(24),
            lines: 1,
        };

        if let RenderEvent::ScrollUp { region, lines } = event {
            assert_eq!(region.start, Line(0));
            assert_eq!(region.end, Line(24));
            assert_eq!(lines, 1);
        } else {
            panic!("Expected ScrollUp event");
        }
    }

    #[test]
    fn test_terminal_event() {
        let bell = TerminalEvent::Bell;
        assert_eq!(bell, TerminalEvent::Bell);

        let title = TerminalEvent::Title("Test".to_string());
        if let TerminalEvent::Title(t) = title {
            assert_eq!(t, "Test");
        }

        let exit = TerminalEvent::Exit;
        assert_eq!(exit, TerminalEvent::Exit);

        let wakeup = TerminalEvent::Wakeup;
        assert_eq!(wakeup, TerminalEvent::Wakeup);
    }

    #[test]
    fn test_line_clear_mode() {
        assert_ne!(LineClearMode::Right, LineClearMode::Left);
        assert_ne!(LineClearMode::Left, LineClearMode::All);
    }

    #[test]
    fn test_screen_clear_mode() {
        assert_ne!(ScreenClearMode::Below, ScreenClearMode::Above);
        assert_ne!(ScreenClearMode::All, ScreenClearMode::Saved);
    }
}
