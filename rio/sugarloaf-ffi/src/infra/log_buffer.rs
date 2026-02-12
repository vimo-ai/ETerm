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
    pub truncated: bool,         // true if old logs were discarded by ring buffer
    pub boundary_seq: Option<u64>, // current run start seq (if mark_boundary was called)
    pub boundary_valid: bool,    // true if boundary_seq is still within the buffer
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

    /// Partial UTF-8 bytes from previous append (max 3 bytes for a 4-byte sequence)
    partial_utf8: RwLock<Vec<u8>>,

    /// Run boundary: seq of the first line in the current run
    /// Set by mark_boundary(), used by current_run queries
    boundary_seq: RwLock<Option<u64>>,
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
            partial_utf8: RwLock::new(Vec::with_capacity(4)),
            boundary_seq: RwLock::new(None),
        }
    }

    /// Append raw PTY output data
    ///
    /// Automatically:
    /// - Strips ANSI escape sequences
    /// - Handles `\r` (carriage return) for progress bar overwriting
    /// - Commits lines on `\n`
    pub fn append(&self, data: &[u8]) {
        let mut partial = self.partial_utf8.write().unwrap();

        // Prepend any leftover partial UTF-8 bytes from the previous call
        let combined: std::borrow::Cow<[u8]> = if partial.is_empty() {
            std::borrow::Cow::Borrowed(data)
        } else {
            let mut buf = std::mem::take(&mut *partial);
            buf.extend_from_slice(data);
            std::borrow::Cow::Owned(buf)
        };

        // Decode as much valid UTF-8 as possible, save trailing incomplete bytes
        let (text, remainder) = match std::str::from_utf8(&combined) {
            Ok(s) => (s, &[] as &[u8]),
            Err(e) => {
                let valid_up_to = e.valid_up_to();
                let valid_str = unsafe { std::str::from_utf8_unchecked(&combined[..valid_up_to]) };
                match e.error_len() {
                    Some(len) => {
                        // Invalid byte sequence (not just incomplete): skip it, save the rest as new data
                        // Recurse on the remaining bytes after the invalid sequence
                        let after_invalid = valid_up_to + len;
                        if after_invalid < combined.len() {
                            // Save valid part, process remainder separately
                            partial.extend_from_slice(&combined[after_invalid..]);
                        }
                        (valid_str, &[] as &[u8])
                    }
                    None => {
                        // Incomplete UTF-8 at the end: save for next append
                        (valid_str, &combined[valid_up_to..])
                    }
                }
            }
        };

        if !remainder.is_empty() {
            partial.extend_from_slice(remainder);
        }

        // Drop partial lock before acquiring other locks
        drop(partial);

        if text.is_empty() {
            return;
        }

        let plain = Self::strip_ansi(text);

        let mut current = self.current_line.write().unwrap();
        let mut lines = self.lines.write().unwrap();
        let mut next_seq = self.next_seq.write().unwrap();

        let chars: Vec<char> = plain.chars().collect();
        let mut i = 0;

        while i < chars.len() {
            match chars[i] {
                '\r' => {
                    // Skip consecutive \r's, find the terminal \r before \n or content
                    let mut j = i;
                    while j < chars.len() && chars[j] == '\r' {
                        j += 1;
                    }
                    // j now points to the first non-\r character (or end)
                    if j < chars.len() && chars[j] == '\n' {
                        // \r+\n (CRLF variant): commit current line
                        let text = std::mem::take(&mut *current);
                        Self::commit_line(&mut lines, &mut next_seq, text, self.max_lines);
                        i = j + 1; // skip past \n
                    } else {
                        // \r without following \n: progress bar overwrite, reset to line start
                        current.clear();
                        i = j;
                    }
                }
                '\n' => {
                    // Standalone \n: commit current line
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

    /// Mark current position as a run boundary
    ///
    /// Flushes any incomplete line first, then records next_seq as the
    /// start of a new run. Used to distinguish "current run" from history.
    ///
    /// Returns the boundary seq value.
    pub fn mark_boundary(&self) -> u64 {
        self.flush();
        let seq = *self.next_seq.read().unwrap();
        *self.boundary_seq.write().unwrap() = Some(seq);
        seq
    }

    /// Get the current boundary seq (if set)
    pub fn boundary_seq(&self) -> Option<u64> {
        *self.boundary_seq.read().unwrap()
    }

    /// Query log lines
    ///
    /// # Arguments
    /// * `after` - Return lines with seq > after (None for no lower bound)
    /// * `before` - Return lines with seq < before (None for no upper bound)
    /// * `limit` - Maximum number of lines to return
    /// * `search` - Optional search filter
    /// * `is_regex` - If true, treat `search` as a regex pattern
    /// * `case_insensitive` - If true, search is case-insensitive
    /// * `backward` - If true, scan from tail and return most recent matches
    pub fn query(
        &self,
        after: Option<u64>,
        before: Option<u64>,
        limit: usize,
        search: Option<&str>,
        is_regex: bool,
        case_insensitive: bool,
        backward: bool,
    ) -> LogQueryResult {
        let lines = self.lines.read().unwrap();
        let next_seq = *self.next_seq.read().unwrap();
        let boundary = *self.boundary_seq.read().unwrap();

        // Boundary validity: boundary must be >= first seq in buffer
        let first_seq = lines.front().map_or(next_seq, |l| l.seq);
        let boundary_valid = boundary.map_or(false, |b| b >= first_seq);

        // Check if old logs were discarded by ring buffer
        let truncated = first_seq > 1;

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

        // Build filter closure
        let matches = |line: &&LogLine| -> bool {
            if after.map_or(false, |a| line.seq <= a) { return false; }
            if before.map_or(false, |b| line.seq >= b) { return false; }
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
        };

        let (result_lines, has_more) = if backward {
            // Reverse scan: collect from tail, then reverse to chronological order
            let mut collected: Vec<LogLine> = Vec::with_capacity(limit + 1);
            let mut total_matched = 0usize;
            for line in lines.iter().rev() {
                if matches(&line) {
                    total_matched += 1;
                    if collected.len() < limit {
                        collected.push(line.clone());
                    } else {
                        // We found more than limit, so has_more = true
                        break;
                    }
                }
            }
            let has_more = total_matched > limit;
            collected.reverse(); // chronological order
            (collected, has_more)
        } else {
            // Forward scan (original behavior)
            let mut collected: Vec<LogLine> = Vec::with_capacity(limit);
            let mut total_matched = 0usize;
            for line in lines.iter() {
                if matches(&line) {
                    total_matched += 1;
                    if collected.len() < limit {
                        collected.push(line.clone());
                    } else {
                        break;
                    }
                }
            }
            let has_more = total_matched > limit;
            (collected, has_more)
        };

        LogQueryResult {
            lines: result_lines,
            next_seq,
            has_more,
            truncated,
            boundary_seq: boundary,
            boundary_valid,
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
    fn test_double_cr_lf() {
        // simctl --console-pty outputs \r\r\n (PTY ONLCR converts \n→\r\n, plus app's own \r)
        let buffer = LogBuffer::new(100);

        buffer.append("line1\r\r\nline2\r\r\n".as_bytes());

        assert_eq!(buffer.len(), 2);
        assert_eq!(buffer.tail(2)[0].text, "line1");
        assert_eq!(buffer.tail(2)[1].text, "line2");
    }

    #[test]
    fn test_double_cr_lf_with_emoji() {
        // Real simctl --console-pty output pattern
        let buffer = LogBuffer::new(100);

        let input = "✅ [AuthService] Token OK\r\r\n🔐 [TLS] mTLS enabled\r\r\n";
        buffer.append(input.as_bytes());

        assert_eq!(buffer.len(), 2);
        assert_eq!(buffer.tail(2)[0].text, "✅ [AuthService] Token OK");
        assert_eq!(buffer.tail(2)[1].text, "🔐 [TLS] mTLS enabled");
    }

    #[test]
    fn test_query_since() {
        let buffer = LogBuffer::new(100);

        for i in 1..=5 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        let result = buffer.query(Some(2), None, 100, None, false, true, false);
        assert_eq!(result.lines.len(), 3); // seq 3, 4, 5
        assert_eq!(result.lines[0].seq, 3);
    }

    #[test]
    fn test_query_search() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"INFO: starting\n");
        buffer.append(b"ERROR: failed\n");
        buffer.append(b"INFO: done\n");

        let result = buffer.query(None, None, 100, Some("error"), false, true, false);
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
        let result = buffer.query(None, None, 100, Some(r"ERROR:.*failed"), true, false, false);
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.lines[0].text, "ERROR: connection failed");

        // Case-insensitive regex
        let result = buffer.query(None, None, 100, Some(r"error"), true, true, false);
        assert_eq!(result.lines.len(), 2);

        // Case-sensitive regex (no match for lowercase)
        let result = buffer.query(None, None, 100, Some(r"error"), true, false, false);
        assert_eq!(result.lines.len(), 0);
    }

    #[test]
    fn test_query_case_sensitive() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"ERROR: failed\n");
        buffer.append(b"error: also failed\n");

        // Case-insensitive (default backward compat)
        let result = buffer.query(None, None, 100, Some("error"), false, true, false);
        assert_eq!(result.lines.len(), 2);

        // Case-sensitive
        let result = buffer.query(None, None, 100, Some("error"), false, false, false);
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.lines[0].text, "error: also failed");
    }

    #[test]
    fn test_query_invalid_regex_fallback() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"test [invalid pattern\n");
        buffer.append(b"normal line\n");

        // Invalid regex falls back to plain text search
        let result = buffer.query(None, None, 100, Some("[invalid"), true, false, false);
        assert_eq!(result.lines.len(), 1);
        assert_eq!(result.lines[0].text, "test [invalid pattern");
    }

    #[test]
    fn test_truncated_flag() {
        let buffer = LogBuffer::new(3);

        for i in 1..=5 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        let result = buffer.query(None, None, 100, None, false, true, false);
        assert!(result.truncated);
    }

    #[test]
    fn test_query_backward() {
        let buffer = LogBuffer::new(100);

        for i in 1..=10 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        // Backward query: last 3 lines
        let result = buffer.query(None, None, 3, None, false, true, true);
        assert_eq!(result.lines.len(), 3);
        assert_eq!(result.lines[0].text, "line8");
        assert_eq!(result.lines[1].text, "line9");
        assert_eq!(result.lines[2].text, "line10");
        assert!(result.has_more);
    }

    #[test]
    fn test_query_backward_with_search() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"ERROR: first\n");
        buffer.append(b"INFO: ok\n");
        buffer.append(b"ERROR: second\n");
        buffer.append(b"INFO: ok\n");
        buffer.append(b"ERROR: third\n");

        // Backward search: last 2 ERRORs
        let result = buffer.query(None, None, 2, Some("ERROR"), false, true, true);
        assert_eq!(result.lines.len(), 2);
        assert_eq!(result.lines[0].text, "ERROR: second");
        assert_eq!(result.lines[1].text, "ERROR: third");
        assert!(result.has_more); // "ERROR: first" still exists
    }

    #[test]
    fn test_query_before() {
        let buffer = LogBuffer::new(100);

        for i in 1..=5 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        // Lines with seq < 4 (i.e. seq 1, 2, 3)
        let result = buffer.query(None, Some(4), 100, None, false, true, false);
        assert_eq!(result.lines.len(), 3);
        assert_eq!(result.lines[2].text, "line3");
    }

    #[test]
    fn test_query_after_and_before() {
        let buffer = LogBuffer::new(100);

        for i in 1..=10 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        // Lines with 3 < seq < 8 (i.e. seq 4, 5, 6, 7)
        let result = buffer.query(Some(3), Some(8), 100, None, false, true, false);
        assert_eq!(result.lines.len(), 4);
        assert_eq!(result.lines[0].text, "line4");
        assert_eq!(result.lines[3].text, "line7");
    }

    #[test]
    fn test_mark_boundary() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"old line 1\n");
        buffer.append(b"old line 2\n");

        let boundary = buffer.mark_boundary();
        assert_eq!(boundary, 3); // next_seq after 2 lines

        buffer.append(b"new line 1\n");
        buffer.append(b"new line 2\n");

        assert_eq!(buffer.boundary_seq(), Some(3));

        // Query with after=boundary should only get new lines
        let result = buffer.query(Some(boundary - 1), None, 100, None, false, true, false);
        assert_eq!(result.lines.len(), 2);
        assert_eq!(result.lines[0].text, "new line 1");
        assert_eq!(result.boundary_seq, Some(3));
        assert!(result.boundary_valid);
    }

    #[test]
    fn test_boundary_valid_after_ring_buffer_eviction() {
        let buffer = LogBuffer::new(3);

        buffer.append(b"line1\n");
        let boundary = buffer.mark_boundary();
        assert_eq!(boundary, 2);

        // Fill buffer past capacity, evicting the boundary
        for i in 2..=10 {
            buffer.append(format!("line{}\n", i).as_bytes());
        }

        let result = buffer.query(None, None, 100, None, false, true, false);
        assert_eq!(result.boundary_seq, Some(2));
        assert!(!result.boundary_valid); // boundary evicted
    }

    #[test]
    fn test_boundary_with_backward_query() {
        let buffer = LogBuffer::new(100);

        buffer.append(b"old1\n");
        buffer.append(b"old2\n");
        let boundary = buffer.mark_boundary();

        buffer.append(b"new1\n");
        buffer.append(b"new2\n");
        buffer.append(b"new3\n");

        // Backward query within current run (after = boundary - 1)
        let result = buffer.query(Some(boundary - 1), None, 2, None, false, true, true);
        assert_eq!(result.lines.len(), 2);
        assert_eq!(result.lines[0].text, "new2");
        assert_eq!(result.lines[1].text, "new3");
    }

    #[test]
    fn test_unicode() {
        let buffer = LogBuffer::new(100);
        buffer.append("日志：成功 ✅\n".as_bytes());
        buffer.append("🚀 Launched\n".as_bytes());

        assert_eq!(buffer.len(), 2);
        assert_eq!(buffer.tail(1)[0].text, "🚀 Launched");
    }

    #[test]
    fn test_partial_utf8_split() {
        let buffer = LogBuffer::new(100);

        // ✅ is U+2705, UTF-8: E2 9C 85 (3 bytes)
        // Split in the middle of the emoji
        let full = "✅ OK\n".as_bytes();
        assert_eq!(full[0], 0xE2);

        // First chunk: partial emoji (2 of 3 bytes)
        buffer.append(&full[..2]);
        // Second chunk: remaining emoji byte + rest of line
        buffer.append(&full[2..]);

        assert_eq!(buffer.len(), 1);
        assert_eq!(buffer.tail(1)[0].text, "✅ OK");
    }

    #[test]
    fn test_partial_utf8_4byte_emoji() {
        let buffer = LogBuffer::new(100);

        // 🚀 is U+1F680, UTF-8: F0 9F 9A 80 (4 bytes)
        let full = "🚀 Launch\n".as_bytes();

        // Split after 1 byte of the 4-byte emoji
        buffer.append(&full[..1]);
        buffer.append(&full[1..]);

        assert_eq!(buffer.len(), 1);
        assert_eq!(buffer.tail(1)[0].text, "🚀 Launch");
    }

    #[test]
    fn test_partial_utf8_chinese() {
        let buffer = LogBuffer::new(100);

        // 日 is U+65E5, UTF-8: E6 97 A5 (3 bytes)
        let full = "日志成功\n".as_bytes();

        // Split between two Chinese characters
        // 日(3) + 志(3) = 6 bytes, split at 4 (middle of 志)
        buffer.append(&full[..4]);
        buffer.append(&full[4..]);

        assert_eq!(buffer.len(), 1);
        assert_eq!(buffer.tail(1)[0].text, "日志成功");
    }

    #[test]
    fn test_partial_utf8_multiple_lines() {
        let buffer = LogBuffer::new(100);

        // Simulate real app output with emoji split across chunks
        let line1 = "✅ [Auth] Token OK\n";
        let line2 = "🔐 [TLS] mTLS enabled\n";
        let combined = format!("{}{}", line1, line2);
        let bytes = combined.as_bytes();

        // Split in the middle of 🔐 (F0 9F 94 90, 4 bytes)
        let split_point = line1.len() + 2; // 2 bytes into 🔐
        buffer.append(&bytes[..split_point]);
        buffer.append(&bytes[split_point..]);

        assert_eq!(buffer.len(), 2);
        assert_eq!(buffer.tail(2)[0].text, "✅ [Auth] Token OK");
        assert_eq!(buffer.tail(2)[1].text, "🔐 [TLS] mTLS enabled");
    }
}
