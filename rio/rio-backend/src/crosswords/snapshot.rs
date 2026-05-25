// Grid state snapshot for PTY daemon reattach.
//
// Captures the visible terminal grid (both active and inactive buffers),
// cursor position/style, and mode flags so that TUI programs can be
// restored after a daemon reconnect.

use crate::ansi::CursorShape;
use crate::config::colors::{AnsiColor, ColorRgb, NamedColor};
use crate::crosswords::grid::Dimensions;
use crate::crosswords::pos::{Column, Line, Pos};
use crate::crosswords::square::{Flags as CellFlags, Square};
use crate::crosswords::Mode;

// Binary format version tag (bump when layout changes).
const SNAPSHOT_VERSION: u8 = 1;

/// Lightweight cell representation for serialization.
///
/// Strips out CellExtra (zerowidth chars, hyperlinks, graphics) which are
/// not practical to restore across a daemon reconnect.
#[derive(Debug, Clone, PartialEq)]
pub struct SnapshotCell {
    pub c: char,
    pub fg: AnsiColor,
    pub bg: AnsiColor,
    pub flags: u16,
}

impl SnapshotCell {
    fn from_square(sq: &Square) -> Self {
        SnapshotCell {
            c: sq.c,
            fg: sq.fg,
            bg: sq.bg,
            flags: sq.flags.bits(),
        }
    }

    fn to_square(&self) -> Square {
        Square {
            c: self.c,
            fg: self.fg,
            bg: self.bg,
            flags: CellFlags::from_bits_truncate(self.flags),
            extra: None,
        }
    }
}

/// Full snapshot of both grid buffers, cursor, and terminal modes.
#[derive(Debug, Clone, PartialEq)]
pub struct GridSnapshot {
    pub cols: usize,
    pub rows: usize,
    pub cursor_col: usize,
    pub cursor_row: i32,
    pub cursor_shape: CursorShape,
    pub mode_bits: u32,
    pub is_alt_screen: bool,
    pub active_cells: Vec<SnapshotCell>,
    pub inactive_cells: Vec<SnapshotCell>,
}

impl GridSnapshot {
    /// Capture a snapshot from the current crosswords state.
    ///
    /// Only the visible area is captured (no scrollback). Both the active
    /// and inactive grid buffers are included so that the alternate screen
    /// can be restored.
    pub fn capture<U: crate::event::EventListener>(
        cw: &super::Crosswords<U>,
    ) -> Self {
        let cols = cw.grid.columns();
        let rows = cw.grid.screen_lines();
        let mode = cw.mode;
        let is_alt = mode.contains(Mode::ALT_SCREEN);

        let active_cells = snapshot_grid_cells(&cw.grid, rows, cols);
        let inactive_cells = snapshot_grid_cells(&cw.inactive_grid, rows, cols);

        GridSnapshot {
            cols,
            rows,
            cursor_col: cw.grid.cursor.pos.col.0,
            cursor_row: cw.grid.cursor.pos.row.0,
            cursor_shape: cw.cursor_shape,
            mode_bits: mode.bits(),
            is_alt_screen: is_alt,
            active_cells,
            inactive_cells,
        }
    }

    /// Apply this snapshot onto a fresh Crosswords instance.
    ///
    /// The target should have been created with the same dimensions.
    /// If dimensions differ, the grid is resized first.
    pub fn apply<U: crate::event::EventListener>(
        &self,
        cw: &mut super::Crosswords<U>,
    ) {
        let cur_cols = cw.grid.columns();
        let cur_rows = cw.grid.screen_lines();

        if cur_cols != self.cols || cur_rows != self.rows {
            let size = super::CrosswordsSize::new(self.cols, self.rows);
            cw.resize(size);
        }

        // Restore active grid cells.
        restore_grid_cells(&mut cw.grid, self.rows, self.cols, &self.active_cells);

        // Restore inactive grid cells.
        restore_grid_cells(
            &mut cw.inactive_grid,
            self.rows,
            self.cols,
            &self.inactive_cells,
        );

        // Restore cursor.
        cw.grid.cursor.pos = Pos::new(
            Line(self.cursor_row),
            Column(self.cursor_col),
        );
        cw.cursor_shape = self.cursor_shape;

        // Restore mode flags directly.
        if let Some(mode) = Mode::from_bits(self.mode_bits) {
            cw.mode = mode;
        }

        // If the snapshot was captured with ALT_SCREEN active, but the
        // fresh Crosswords doesn't have it set, swap into alt screen.
        let currently_alt = cw.mode.contains(Mode::ALT_SCREEN);
        if self.is_alt_screen && !currently_alt {
            cw.swap_alt();
        } else if !self.is_alt_screen && currently_alt {
            cw.swap_alt();
        }
    }

    // ── Binary serialization ────────────────────────────────────────

    /// Serialize the snapshot into a compact binary representation.
    ///
    /// Layout:
    ///   [version: u8]
    ///   [cols: u32]
    ///   [rows: u32]
    ///   [cursor_col: u32]
    ///   [cursor_row: i32]
    ///   [cursor_shape: u8]
    ///   [mode_bits: u32]
    ///   [is_alt_screen: u8]
    ///   [active_cell_count: u32]
    ///   [active cells, RLE-encoded...]
    ///   [inactive_cell_count: u32]
    ///   [inactive cells, RLE-encoded...]
    ///
    /// Each RLE run:
    ///   [run_length: u16]
    ///   [char: u32]
    ///   [fg, encoded]
    ///   [bg, encoded]
    ///   [flags: u16]
    pub fn to_bytes(&self) -> Vec<u8> {
        let capacity = 32 + (self.active_cells.len() + self.inactive_cells.len()) * 16;
        let mut buf = Vec::with_capacity(capacity);

        // Header.
        buf.push(SNAPSHOT_VERSION);
        buf.extend_from_slice(&(self.cols as u32).to_le_bytes());
        buf.extend_from_slice(&(self.rows as u32).to_le_bytes());
        buf.extend_from_slice(&(self.cursor_col as u32).to_le_bytes());
        buf.extend_from_slice(&self.cursor_row.to_le_bytes());
        buf.push(cursor_shape_to_u8(self.cursor_shape));
        buf.extend_from_slice(&self.mode_bits.to_le_bytes());
        buf.push(self.is_alt_screen as u8);

        encode_cells(&self.active_cells, &mut buf);
        encode_cells(&self.inactive_cells, &mut buf);

        buf
    }

    /// Deserialize from the binary format produced by `to_bytes`.
    pub fn from_bytes(data: &[u8]) -> Result<Self, SnapshotError> {
        let mut pos = 0;

        let version = read_u8(data, &mut pos)?;
        if version != SNAPSHOT_VERSION {
            return Err(SnapshotError::UnsupportedVersion(version));
        }

        let cols = read_u32_le(data, &mut pos)? as usize;
        let rows = read_u32_le(data, &mut pos)? as usize;
        let cursor_col = read_u32_le(data, &mut pos)? as usize;
        let cursor_row = read_i32_le(data, &mut pos)?;
        let cursor_shape = cursor_shape_from_u8(read_u8(data, &mut pos)?);
        let mode_bits = read_u32_le(data, &mut pos)?;
        let is_alt_screen = read_u8(data, &mut pos)? != 0;

        let active_cells = decode_cells(data, &mut pos)?;
        let inactive_cells = decode_cells(data, &mut pos)?;

        Ok(GridSnapshot {
            cols,
            rows,
            cursor_col,
            cursor_row,
            cursor_shape,
            mode_bits,
            is_alt_screen,
            active_cells,
            inactive_cells,
        })
    }
}

// ── Private helpers ────────────────────────────────────────────────

fn snapshot_grid_cells(
    grid: &crate::crosswords::grid::Grid<Square>,
    rows: usize,
    cols: usize,
) -> Vec<SnapshotCell> {
    let mut cells = Vec::with_capacity(rows * cols);
    for row_idx in 0..rows {
        let row = &grid[Line(row_idx as i32)];
        for col_idx in 0..cols {
            let sq = &row[Column(col_idx)];
            cells.push(SnapshotCell::from_square(sq));
        }
    }
    cells
}

fn restore_grid_cells(
    grid: &mut crate::crosswords::grid::Grid<Square>,
    rows: usize,
    cols: usize,
    cells: &[SnapshotCell],
) {
    for (i, cell) in cells.iter().enumerate() {
        let row_idx = i / cols;
        let col_idx = i % cols;
        if row_idx >= rows {
            break;
        }
        grid[Line(row_idx as i32)][Column(col_idx)] = cell.to_square();
    }
}

// ── AnsiColor binary encoding ──────────────────────────────────────
//
// Tag byte:
//   0 => Named(variant as u8)
//   1 => Spec(r, g, b)
//   2 => Indexed(idx)

fn encode_ansi_color(color: &AnsiColor, buf: &mut Vec<u8>) {
    match color {
        AnsiColor::Named(n) => {
            buf.push(0);
            buf.push(named_color_to_u8(*n));
        }
        AnsiColor::Spec(rgb) => {
            buf.push(1);
            buf.push(rgb.r);
            buf.push(rgb.g);
            buf.push(rgb.b);
        }
        AnsiColor::Indexed(idx) => {
            buf.push(2);
            buf.push(*idx);
        }
    }
}

fn decode_ansi_color(data: &[u8], pos: &mut usize) -> Result<AnsiColor, SnapshotError> {
    let tag = read_u8(data, pos)?;
    match tag {
        0 => {
            let variant = read_u8(data, pos)?;
            let named = named_color_from_u8(variant)
                .ok_or(SnapshotError::InvalidData("unknown NamedColor variant"))?;
            Ok(AnsiColor::Named(named))
        }
        1 => {
            let r = read_u8(data, pos)?;
            let g = read_u8(data, pos)?;
            let b = read_u8(data, pos)?;
            Ok(AnsiColor::Spec(ColorRgb { r, g, b }))
        }
        2 => {
            let idx = read_u8(data, pos)?;
            Ok(AnsiColor::Indexed(idx))
        }
        _ => Err(SnapshotError::InvalidData("unknown AnsiColor tag")),
    }
}

// ── RLE cell encoding ──────────────────────────────────────────────

fn cells_attr_equal(a: &SnapshotCell, b: &SnapshotCell) -> bool {
    a.c == b.c && a.fg == b.fg && a.bg == b.bg && a.flags == b.flags
}

fn encode_cells(cells: &[SnapshotCell], buf: &mut Vec<u8>) {
    buf.extend_from_slice(&(cells.len() as u32).to_le_bytes());

    let mut i = 0;
    while i < cells.len() {
        let cell = &cells[i];
        let mut run_len: u16 = 1;
        while i + (run_len as usize) < cells.len()
            && run_len < u16::MAX
            && cells_attr_equal(cell, &cells[i + run_len as usize])
        {
            run_len += 1;
        }

        buf.extend_from_slice(&run_len.to_le_bytes());
        buf.extend_from_slice(&(cell.c as u32).to_le_bytes());
        encode_ansi_color(&cell.fg, buf);
        encode_ansi_color(&cell.bg, buf);
        buf.extend_from_slice(&cell.flags.to_le_bytes());

        i += run_len as usize;
    }
}

fn decode_cells(data: &[u8], pos: &mut usize) -> Result<Vec<SnapshotCell>, SnapshotError> {
    let total = read_u32_le(data, pos)? as usize;
    let mut cells = Vec::with_capacity(total);

    while cells.len() < total {
        let run_len = read_u16_le(data, pos)? as usize;
        let c_raw = read_u32_le(data, pos)?;
        let c = char::from_u32(c_raw)
            .ok_or(SnapshotError::InvalidData("invalid char codepoint"))?;
        let fg = decode_ansi_color(data, pos)?;
        let bg = decode_ansi_color(data, pos)?;
        let flags = read_u16_le(data, pos)?;

        let cell = SnapshotCell { c, fg, bg, flags };
        for _ in 0..run_len {
            cells.push(cell.clone());
        }
    }

    if cells.len() != total {
        return Err(SnapshotError::InvalidData("cell count mismatch after RLE decode"));
    }

    Ok(cells)
}

// ── CursorShape encoding ──────────────────────────────────────────

fn cursor_shape_to_u8(shape: CursorShape) -> u8 {
    match shape {
        CursorShape::Block => 0,
        CursorShape::Underline => 1,
        CursorShape::Beam => 2,
        CursorShape::Hidden => 3,
    }
}

fn cursor_shape_from_u8(v: u8) -> CursorShape {
    match v {
        0 => CursorShape::Block,
        1 => CursorShape::Underline,
        2 => CursorShape::Beam,
        3 => CursorShape::Hidden,
        _ => CursorShape::Block,
    }
}

// ── NamedColor encoding ───────────────────────────────────────────

fn named_color_from_u8(v: u8) -> Option<NamedColor> {
    Some(match v {
        0 => NamedColor::Black,
        1 => NamedColor::Red,
        2 => NamedColor::Green,
        3 => NamedColor::Yellow,
        4 => NamedColor::Blue,
        5 => NamedColor::Magenta,
        6 => NamedColor::Cyan,
        7 => NamedColor::White,
        8 => NamedColor::LightBlack,
        9 => NamedColor::LightRed,
        10 => NamedColor::LightGreen,
        11 => NamedColor::LightYellow,
        12 => NamedColor::LightBlue,
        13 => NamedColor::LightMagenta,
        14 => NamedColor::LightCyan,
        15 => NamedColor::LightWhite,
        // NamedColor has a gap: Foreground = 256 in the enum, but we pack
        // the discriminant as u8. Use 16+ for the non-palette entries.
        16 => NamedColor::Foreground,
        17 => NamedColor::Background,
        18 => NamedColor::Cursor,
        19 => NamedColor::DimBlack,
        20 => NamedColor::DimRed,
        21 => NamedColor::DimGreen,
        22 => NamedColor::DimYellow,
        23 => NamedColor::DimBlue,
        24 => NamedColor::DimMagenta,
        25 => NamedColor::DimCyan,
        26 => NamedColor::DimWhite,
        27 => NamedColor::LightForeground,
        28 => NamedColor::DimForeground,
        _ => return None,
    })
}

fn named_color_to_u8(n: NamedColor) -> u8 {
    match n {
        NamedColor::Black => 0,
        NamedColor::Red => 1,
        NamedColor::Green => 2,
        NamedColor::Yellow => 3,
        NamedColor::Blue => 4,
        NamedColor::Magenta => 5,
        NamedColor::Cyan => 6,
        NamedColor::White => 7,
        NamedColor::LightBlack => 8,
        NamedColor::LightRed => 9,
        NamedColor::LightGreen => 10,
        NamedColor::LightYellow => 11,
        NamedColor::LightBlue => 12,
        NamedColor::LightMagenta => 13,
        NamedColor::LightCyan => 14,
        NamedColor::LightWhite => 15,
        NamedColor::Foreground => 16,
        NamedColor::Background => 17,
        NamedColor::Cursor => 18,
        NamedColor::DimBlack => 19,
        NamedColor::DimRed => 20,
        NamedColor::DimGreen => 21,
        NamedColor::DimYellow => 22,
        NamedColor::DimBlue => 23,
        NamedColor::DimMagenta => 24,
        NamedColor::DimCyan => 25,
        NamedColor::DimWhite => 26,
        NamedColor::LightForeground => 27,
        NamedColor::DimForeground => 28,
    }
}

// ── Primitive readers ─────────────────────────────────────────────

fn read_u8(data: &[u8], pos: &mut usize) -> Result<u8, SnapshotError> {
    if *pos >= data.len() {
        return Err(SnapshotError::UnexpectedEof);
    }
    let v = data[*pos];
    *pos += 1;
    Ok(v)
}

fn read_u16_le(data: &[u8], pos: &mut usize) -> Result<u16, SnapshotError> {
    if *pos + 2 > data.len() {
        return Err(SnapshotError::UnexpectedEof);
    }
    let v = u16::from_le_bytes([data[*pos], data[*pos + 1]]);
    *pos += 2;
    Ok(v)
}

fn read_u32_le(data: &[u8], pos: &mut usize) -> Result<u32, SnapshotError> {
    if *pos + 4 > data.len() {
        return Err(SnapshotError::UnexpectedEof);
    }
    let v = u32::from_le_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
    *pos += 4;
    Ok(v)
}

fn read_i32_le(data: &[u8], pos: &mut usize) -> Result<i32, SnapshotError> {
    if *pos + 4 > data.len() {
        return Err(SnapshotError::UnexpectedEof);
    }
    let v = i32::from_le_bytes([data[*pos], data[*pos + 1], data[*pos + 2], data[*pos + 3]]);
    *pos += 4;
    Ok(v)
}

// ── Error type ────────────────────────────────────────────────────

#[derive(Debug)]
pub enum SnapshotError {
    UnsupportedVersion(u8),
    UnexpectedEof,
    InvalidData(&'static str),
}

impl std::fmt::Display for SnapshotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SnapshotError::UnsupportedVersion(v) => {
                write!(f, "unsupported snapshot version: {v}")
            }
            SnapshotError::UnexpectedEof => write!(f, "unexpected end of snapshot data"),
            SnapshotError::InvalidData(msg) => write!(f, "invalid snapshot data: {msg}"),
        }
    }
}

impl std::error::Error for SnapshotError {}

// ── Tests ─────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ansi::CursorShape;
    use crate::config::colors::{AnsiColor, NamedColor};
    use crate::crosswords::pos::{Column, Line};
    use crate::crosswords::{Crosswords, CrosswordsSize, Mode};
    use crate::event::VoidListener;

    fn make_crosswords(cols: usize, rows: usize) -> Crosswords<VoidListener> {
        let size = CrosswordsSize::new(cols, rows);
        let window_id = crate::event::WindowId::from(0);
        Crosswords::new(size, CursorShape::Block, VoidListener {}, window_id, 0)
    }

    #[test]
    fn round_trip_empty_grid() {
        let cw = make_crosswords(80, 24);
        let snap = GridSnapshot::capture(&cw);

        let bytes = snap.to_bytes();
        let restored = GridSnapshot::from_bytes(&bytes).expect("deserialization failed");

        assert_eq!(snap.cols, restored.cols);
        assert_eq!(snap.rows, restored.rows);
        assert_eq!(snap.cursor_col, restored.cursor_col);
        assert_eq!(snap.cursor_row, restored.cursor_row);
        assert_eq!(snap.cursor_shape, restored.cursor_shape);
        assert_eq!(snap.mode_bits, restored.mode_bits);
        assert_eq!(snap.is_alt_screen, restored.is_alt_screen);
        assert_eq!(snap.active_cells.len(), restored.active_cells.len());
        assert_eq!(snap.inactive_cells.len(), restored.inactive_cells.len());
        assert_eq!(snap, restored);
    }

    #[test]
    fn round_trip_with_content() {
        let mut cw = make_crosswords(10, 5);

        // Write some content into the grid.
        cw.grid[Line(0)][Column(0)].c = 'H';
        cw.grid[Line(0)][Column(1)].c = 'i';
        cw.grid[Line(0)][Column(0)].fg =
            AnsiColor::Spec(ColorRgb { r: 255, g: 0, b: 0 });
        cw.grid[Line(1)][Column(0)].c = '$';
        cw.grid[Line(1)][Column(0)].flags = CellFlags::BOLD;

        // Move cursor.
        cw.grid.cursor.pos = Pos::new(Line(2), Column(5));
        cw.cursor_shape = CursorShape::Beam;

        let snap = GridSnapshot::capture(&cw);
        let bytes = snap.to_bytes();
        let restored = GridSnapshot::from_bytes(&bytes).expect("deserialization failed");

        assert_eq!(snap, restored);
        assert_eq!(restored.cursor_col, 5);
        assert_eq!(restored.cursor_row, 2);
        assert_eq!(restored.cursor_shape, CursorShape::Beam);

        // Verify specific cells survived the round trip.
        assert_eq!(restored.active_cells[0].c, 'H');
        assert_eq!(
            restored.active_cells[0].fg,
            AnsiColor::Spec(ColorRgb { r: 255, g: 0, b: 0 })
        );
        assert_eq!(restored.active_cells[10].c, '$');
        assert_eq!(
            restored.active_cells[10].flags,
            CellFlags::BOLD.bits()
        );
    }

    #[test]
    fn round_trip_alt_screen() {
        let mut cw = make_crosswords(10, 5);

        // Switch to alternate screen.
        cw.swap_alt();
        assert!(cw.mode().contains(Mode::ALT_SCREEN));

        // Write something on the alt screen.
        cw.grid[Line(0)][Column(0)].c = 'A';

        let snap = GridSnapshot::capture(&cw);
        assert!(snap.is_alt_screen);
        assert_ne!(snap.mode_bits & Mode::ALT_SCREEN.bits(), 0);

        let bytes = snap.to_bytes();
        let restored = GridSnapshot::from_bytes(&bytes).expect("deserialization failed");

        assert!(restored.is_alt_screen);
        assert_eq!(restored.active_cells[0].c, 'A');
        assert_eq!(snap, restored);
    }

    #[test]
    fn snapshot_apply_restores_cells() {
        let mut cw = make_crosswords(10, 5);
        cw.grid[Line(0)][Column(0)].c = 'X';
        cw.grid[Line(0)][Column(1)].c = 'Y';
        cw.grid.cursor.pos = Pos::new(Line(3), Column(7));
        cw.cursor_shape = CursorShape::Underline;

        let snap = GridSnapshot::capture(&cw);

        // Create a fresh Crosswords and apply the snapshot.
        let mut cw2 = make_crosswords(10, 5);
        snap.apply(&mut cw2);

        assert_eq!(cw2.grid[Line(0)][Column(0)].c, 'X');
        assert_eq!(cw2.grid[Line(0)][Column(1)].c, 'Y');
        assert_eq!(cw2.grid.cursor.pos.col, Column(7));
        assert_eq!(cw2.grid.cursor.pos.row, Line(3));
        assert_eq!(cw2.cursor_shape, CursorShape::Underline);
    }

    #[test]
    fn rle_compresses_empty_grid() {
        let cw = make_crosswords(80, 24);
        let snap = GridSnapshot::capture(&cw);
        let bytes = snap.to_bytes();

        // An 80x24 grid of identical empty cells should compress well with RLE.
        // Without RLE: 80*24 * ~12 bytes/cell = ~23KB per grid.
        // With RLE: a handful of runs. Should be well under 1KB.
        assert!(
            bytes.len() < 500,
            "RLE should compress empty grid to <500 bytes, got {}",
            bytes.len()
        );
    }

    #[test]
    fn invalid_version_rejected() {
        let mut data = vec![0u8; 32];
        data[0] = 99; // bogus version
        let err = GridSnapshot::from_bytes(&data).unwrap_err();
        assert!(matches!(err, SnapshotError::UnsupportedVersion(99)));
    }

    #[test]
    fn truncated_data_rejected() {
        let err = GridSnapshot::from_bytes(&[SNAPSHOT_VERSION]).unwrap_err();
        assert!(matches!(err, SnapshotError::UnexpectedEof));
    }

    #[test]
    fn named_color_round_trip() {
        // Ensure all NamedColor variants survive encoding.
        let colors = [
            NamedColor::Black,
            NamedColor::Red,
            NamedColor::Foreground,
            NamedColor::Background,
            NamedColor::DimForeground,
            NamedColor::LightForeground,
            NamedColor::Cursor,
        ];
        for nc in colors {
            let encoded = named_color_to_u8(nc);
            let decoded = named_color_from_u8(encoded).unwrap();
            assert_eq!(nc, decoded);
        }
    }
}
