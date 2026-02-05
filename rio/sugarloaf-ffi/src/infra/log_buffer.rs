//! Terminal Output Log Buffer
//!
//! Ring buffer for capturing terminal PTY output.
//! - Optional: controlled by `log_buffer_size` config (0 = disabled)
//! - Strip ANSI sequences, store plain text
//! - Handle `\r` for progress bar overwriting
//! - Thread-safe with sequence-based pagination

use std::collections::VecDeque;
use std::sync::{Arc, RwLock};

/// Single log line with sequence number
#[derive(Debug, Clone)]
pub struct LogLine {
    pub seq: u64,
    pub text: String,
}

/// Query result for log lines
#[derive(Debug, Clone)]
pub struct LogQueryResult {
    pub lines: Vec<LogLine>,
    pub next_seq: u64,
    pub has_more: bool,
    pub truncated: bool, // true if old logs were discarded
}

/// Terminal output log buffer
///
/// Thread-safe ring buffer for capturing PTY output.
/// Created only when `log_buffer_size > 0`.
pub struct LogBuffer {
    /// Maximum number of lines to keep
    max_lines: usize,

    /// Stored log lines
    lines: RwLock<VecDeque<LogLine>>,

    /// Next sequence number
    next_seq: RwLock<u64>,

    /// Current incomplete line (handling \r)
    current_line: RwLock<String>,
}

impl LogBuffer {
    /// Create a new LogBuffer
    ///
    /// # Arguments
    /// * `max_lines` - Maximum number of lines to retain (ring buffer size)
    pub fn new(max_lines: usize) -> Self {
        Self {
            max_lines,
            lines: RwLock::new(VecDeque::with_capacity(max_lines.min(1000))),
            next_seq: RwLock::new(1),
            current_line: RwLock::new(String::new()),
        }
    }

    /// Append raw PTY output data
    ///
    /// Automatically:
    /// - Strips ANSI escape sequences
    /// - Handles `\r` (carriage return) for progress bar overwriting
    /// - Commits lines on `\n`
    pub fn append(&self, data: &[u8]) {
        let text = match std::str::from_utf8(data) {
            Ok(s) => s,
            Err(_) => return, // Skip invalid UTF-8
        };

        let plain = Self::strip_ansi(text);

        let mut current = self.current_line.write().unwrap();
        let mut lines = self.lines.write().unwrap();
        let mut next_seq = self.next_seq.write().unwrap();

        let chars: Vec<char> = plain.chars().collect();
        let mut i = 0;

        while i < chars.len() {
            match chars[i] {
                '\r' => {
                    if i + 1 < chars.len() && chars[i + 1] == '\n' {
                        // \r\n (CRLF): 当作换行，提交当前行
                        let text = std::mem::take(&mut *current);
                        Self::commit_line(&mut lines, &mut next_seq, text, self.max_lines);
                        i += 2; // 跳过 \r\n
                    } else {
                        // 单独 \r: 进度条覆写，回到行首
                        current.clear();
                        i += 1;
                    }
                }
                '\n' => {
                    // 单独 \n: 提交当前行
                    let text = std::mem::take(&mut *current);
                    Self::commit_line(&mut lines, &mut next_seq, text, self.max_lines);
                    i += 1;
                }
                _ => {
                    current.push(chars[i]);
                    i += 1;
                }
            }
        }
    }

    /// Flush any incomplete line (call when terminal closes)
    pub fn flush(&self) {
        let mut current = self.current_line.write().unwrap();
        if current.is_empty() {
            return;
        }

        let mut lines = self.lines.write().unwrap();
        let mut next_seq = self.next_seq.write().unwrap();

        let text = std::mem::take(&mut *current);
        Self::commit_line(&mut lines, &mut next_seq, text, self.max_lines);
    }

    /// Clear all logs
    pub fn clear(&self) {
        let mut lines = self.lines.write().unwrap();
        let mut current = self.current_line.write().unwrap();
        lines.clear();
        current.clear();
        // Keep next_seq incrementing, don't reset
    }

    /// Query log lines
    ///
    /// # Arguments
    /// * `since` - Return lines with seq > since (None for all)
    /// * `limit` - Maximum number of lines to return
    /// * `search` - Optional search filter
    /// * `is_regex` - If true, treat `search` as a regex pattern
    /// * `case_insensitive` - If true, search is case-insensitive
    pub fn query(
        &self,
        since: Option<u64>,
        limit: usize,
        search: Option<&str>,
        is_regex: bool,
        case_insensitive: bool,
    ) -> LogQueryResult {
        let lines = self.lines.read().unwrap();
        let next_seq = *self.next_seq.read().unwrap();

        // Compile regex if needed
        let compiled_regex = if is_regex {
            search.and_then(|s| {
                regex::RegexBuilder::new(s)
                    .case_insensitive(case_insensitive)
                    .build()
                    .ok()
            })
        } else {
            None
        };

        // Filter by since
        let filtered: Vec<&LogLine> = lines
            .iter()
            .filter(|line| since.map_or(true, |s| line.seq > s))
            .filter(|line| {
                match search {
                    None => true,
                    Some(s) => {
                        if let Some(ref re) = compiled_regex {
                            re.is_match(&line.text)
                        } else if case_insensitive {
                            line.text.to_lowercase().contains(&s.to_lowercase())
                        } else {
                            line.text.contains(s)
                        }
                    }
                }
            })
            .collect();

        // Check if truncated (old logs discarded)
        let first_seq = lines.front().map_or(1, |l| l.seq);
        let truncated = first_seq > 1;

        // Check has_more
        let has_more = filtered.len() > limit;

        // Take limit
        let result_lines: Vec<LogLine> = filtered
            .into_iter()
            .take(limit)
            .cloned()
            .collect();

        LogQueryResult {
            lines: result_lines,
            next_seq,
            has_more,
            truncated,
        }
    }

    /// Get the last N lines
    pub fn tail(&self, count: usize) -> Vec<LogLine> {
        let lines = self.lines.read().unwrap();
        lines.iter().rev().take(count).cloned().collect::<Vec<_>>().into_iter().rev().collect()
    }

    /// Get current line count
    pub fn len(&self) -> usize {
        self.lines.read().unwrap().len()
    }

    /// Check if empty
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    // --- Private ---

    fn commit_line(
        lines: &mut VecDeque<LogLine>,
        next_seq: &mut u64,
        text: String,
        max_lines: usize,
    ) {
        let line = LogLine {
            seq: *next_seq,
            text,
        };
        *next_seq += 1;
        lines.push_back(line);

        // Ring buffer: drop old lines
        while lines.len() > max_lines {
            lines.pop_front();
        }
    }

    /// Strip ANSI escape sequences
    ///
    /// Handles:
    /// - CSI sequences: ESC [ ... (colors, cursor)
    /// - OSC sequences: ESC ] ... ST (window title)
    /// - Simple sequences: ESC ( , ESC ) etc.
    fn strip_ansi(text: &str) -> String {
        let mut result = String::with_capacity(text.len());
        let chars: Vec<char> = text.chars().collect();
        let mut i = 0;

        while i < chars.len() {
            if chars[i] == '\x1b' {
                // ESC
                if i + 1 < chars.len() {
                    match chars[i + 1] {
                        '[' => {
                            // CSI sequence: ESC [ ... terminator
                            i = Self::skip_csi(&chars, i + 1);
                            continue;
                        }
                        ']' => {
                            // OSC sequence: ESC ] ... ST
                            i = Self::skip_osc(&chars, i + 1);
                            continue;
                        }
                        c if c >= '\x20' && c <= '\x5f' => {
                            // Simple escape sequence
                            i += 2;
                            continue;
                        }
                        _ => {}
                    }
                }
                // Unrecognized ESC, skip it
                i += 1;
            } else {
                result.push(chars[i]);
                i += 1;
            }
        }

        result
    }

    /// Skip CSI sequence, return next position
    fn skip_csi(chars: &[char], start: usize) -> usize {
        let mut i = start + 1; // Skip '['

        // Parameter bytes: 0x30-0x3f
        while i < chars.len() {
            let c = chars[i] as u32;
            if c >= 0x30 && c <= 0x3f {
                i += 1;
            } else {
                break;
            }
        }

        // Intermediate bytes: 0x20-0x2f
        while i < chars.len() {
            let c = chars[i] as u32;
            if c >= 0x20 && c <= 0x2f {
                i += 1;
            } else {
                break;
            }
        }

        // Final byte: 0x40-0x7e
        if i < chars.len() {
            let c = chars[i] as u32;
            if c >= 0x40 && c <= 0x7e {
                i += 1;
            }
        }

        i
    }

    /// Skip OSC sequence, return next position
    fn skip_osc(chars: &[char], start: usize) -> usize {
        let mut i = start + 1; // Skip ']'

        // Find terminator: BEL (0x07) or ST (ESC \)
        while i < chars.len() {
            if chars[i] == '\x07' {
                // BEL
                return i + 1;
            } else if chars[i] == '\x1b' && i + 1 < chars.len() && chars[i + 1] == '\\' {
                // ST (ESC \)
                return i + 2;
            }
            i += 1;
        }

        i
    }
}

// Thread-safe wrapper for optional LogBuffer
pub type SharedLogBuffer = Option<Arc<LogBuffer>>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_append() {
        let buffer = LogBuffer::new(100);
        buffer.append(b"line1\n");
        buffer.append(b"line2\n");
        buffer.append(b"line3\n");

        assert_eq!(buffer.len(), 3);
    }

    #[test]
    fn test_ring_buffer() {
        let buffer = LogBuffer::new(3);

        for i in 1..=5 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        assert_eq!(buffer.len(), 3);

        let lines = buffer.tail(3);
        assert_eq!(lines[0].text, "line3");
        assert_eq!(lines[1].text, "line4");
        assert_eq!(lines[2].text, "line5");
    }

    #[test]
    fn test_strip_ansi_colors() {
        let buffer = LogBuffer::new(100);
        // Red text: \x1b[31mERROR\x1b[0m
        buffer.append(b"\x1b[31mERROR\x1b[0m: failed\n");

        let lines = buffer.tail(1);
        assert_eq!(lines[0].text, "ERROR: failed");
    }

    #[test]
    fn test_carriage_return() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"Progress: 10%\r");
        buffer.append(b"Progress: 50%\r");
        buffer.append(b"Progress: 100%\n");

        assert_eq!(buffer.len(), 1);
        assert_eq!(buffer.tail(1)[0].text, "Progress: 100%");
    }

    #[test]
    fn test_query_since() {
        let buffer = LogBuffer::new(100);

        for i in 1..=5 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        let result = buffer.query(Some(2), 100, None, false, true);
        assert_eq!(result.lines.len(), 3); // seq 3, 4, 5
        assert_eq!(result.lines[0].seq, 3);
    }

    #[test]
    fn test_query_search() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"INFO: starting\n");
        buffer.append(b"ERROR: failed\n");
        buffer.append(b"INFO: done\n");

        let result = buffer.query(None, 100, Some("error"), false, true);
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.lines[0].text, "ERROR: failed");
    }

    #[test]
    fn test_query_regex() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"INFO: starting server\n");
        buffer.append(b"ERROR: connection failed\n");
        buffer.append(b"WARN: timeout 30s\n");
        buffer.append(b"ERROR: disk full\n");

        // Regex: match lines with "ERROR" followed by any word
        let result = buffer.query(None, 100, Some(r"ERROR:.*failed"), true, false);
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.lines[0].text, "ERROR: connection failed");

        // Case-insensitive regex
        let result = buffer.query(None, 100, Some(r"error"), true, true);
        assert_eq!(result.lines.len(), 2);

        // Case-sensitive regex (no match for lowercase)
        let result = buffer.query(None, 100, Some(r"error"), true, false);
        assert_eq!(result.lines.len(), 0);
    }

    #[test]
    fn test_query_case_sensitive() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"ERROR: failed\n");
        buffer.append(b"error: also failed\n");

        // Case-insensitive (default backward compat)
        let result = buffer.query(None, 100, Some("error"), false, true);
        assert_eq!(result.lines.len(), 2);

        // Case-sensitive
        let result = buffer.query(None, 100, Some("error"), false, false);
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.lines[0].text, "error: also failed");
    }

    #[test]
    fn test_query_invalid_regex_fallback() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"test [invalid pattern\n");
        buffer.append(b"normal line\n");

        // Invalid regex falls back to plain text search
        let result = buffer.query(None, 100, Some("[invalid"), true, false);
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.lines[0].text, "test [invalid pattern");
    }

    #[test]
    fn test_truncated_flag() {
        let buffer = LogBuffer::new(3);

        for i in 1..=5 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        let result = buffer.query(None, 100, None, false, true);
        assert!(result.truncated);
    }

    #[test]
    fn test_unicode() {
        let buffer = LogBuffer::new(100);
        buffer.append("日志：成功 ✅\n".as_bytes());
        buffer.append("🚀 Launched\n".as_bytes());

        assert_eq!(buffer.len(), 2);
        assert_eq!(buffer.tail(1)[0].text, "🚀 Launched");
    }
}
