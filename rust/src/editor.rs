use crate::highlighter::{highlight_typst, HighlightSpan};
use crate::vim_engine::{VimAction, VimEngine, VimMode};
use ropey::Rope;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RenderLine {
    pub text: String,
    pub spans: Vec<HighlightSpan>,
    pub is_composing: bool,
    pub start_u16: usize,
    pub end_u16: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EditorView {
    pub lines: Vec<RenderLine>,
    pub start_line: usize,
    pub cursor_line: usize,
    pub cursor_column_u16: usize, // UTF-16 index within the line
    pub cursor_global_u16: usize, // UTF-16 index within the full buffer
    pub selection_start_line: Option<usize>,
    pub selection_start_column_u16: Option<usize>,
    pub mode: VimMode,
    pub command_text: Option<String>,
    pub search_query: Option<String>,
    pub signal: Option<String>,
    pub yank_text: Option<String>,
}

use crate::typst_engine::TypinkWorld;
use std::collections::HashMap;

pub struct HeadlessEditor {
    pub buffer: Rope,
    pub vim: VimEngine,
    pub composing_text: Option<String>,
    pub composing_start_u16: usize,
    pub cached_spans: Vec<HighlightSpan>,
    pub world: Option<TypinkWorld>,
    pub preloaded_fonts: Vec<crate::typst_engine::FontFileData>,
    pub history: VecDeque<(String, usize, usize)>,
    pub redo_stack: VecDeque<(String, usize, usize)>,
    pub last_yank: Option<String>,
}

#[allow(clippy::new_without_default)]
impl HeadlessEditor {
    pub fn new() -> Self {
        Self {
            buffer: Rope::new(),
            vim: VimEngine::new(),
            composing_text: None,
            composing_start_u16: 0,
            cached_spans: Vec::new(),
            world: None,
            preloaded_fonts: Vec::new(),
            history: VecDeque::new(),
            redo_stack: VecDeque::new(),
            last_yank: None,
        }
    }

    pub fn save(&self, path: &str) -> std::io::Result<()> {
        let content = self.buffer.to_string();
        std::fs::write(path, content)
    }

    pub fn load(&mut self, path: &str) -> std::io::Result<()> {
        let content = std::fs::read_to_string(path)?;
        self.buffer = Rope::from_str(&content);
        self.trigger_highlight();
        Ok(())
    }

    pub fn export_pdf(&mut self, path: &str) -> Result<(), String> {
        let content = self.buffer.to_string();

        // Ensure world is initialized
        if self.world.is_none() {
            self.world = Some(TypinkWorld::new(
                content.clone(),
                HashMap::new(),
                self.preloaded_fonts.clone(),
            ));
        } else if let Some(w) = self.world.as_ref() {
            w.set_main_content(content);
        }

        let world = self.world.as_ref().ok_or("World not initialized")?;
        let document = typst::compile(world)
            .output
            .map_err(|e| format!("Compilation failed with {} errors", e.len()))?;

        let pdf = typst_pdf::pdf(&document, &typst_pdf::PdfOptions::default())
            .map_err(|e| format!("PDF generation failed: {:?}", e))?;
        std::fs::write(path, pdf).map_err(|e| e.to_string())?;

        Ok(())
    }

    pub fn trigger_highlight(&mut self) {
        let content = self.buffer.to_string();
        self.cached_spans = highlight_typst(&content);
    }

    /// Converts a global UTF-16 index to a character index in the Rope.
    /// Uses line-based jumping to optimize common lookups.
    pub fn utf16_idx_to_char_idx(&self, u16_idx: usize) -> usize {
        let total_chars = self.buffer.len_chars();
        if u16_idx == 0 {
            return 0;
        }

        // Estimate line using byte_to_line (since we don't have u16_to_line)
        // For Typst files, UTF-8 byte idx is usually close to UTF-16 idx
        // But to be safe and efficient, we can't jump directly by u16.
        // However, we can iterate by lines which is much faster than chars.

        let mut current_u16 = 0;
        let mut char_count = 0;

        for i in 0..self.buffer.len_lines() {
            let line = self.buffer.line(i);
            let line_u16_len: usize = line.chars().map(|c| c.len_utf16()).sum();

            if current_u16 + line_u16_len > u16_idx {
                // The target is in this line
                for c in line.chars() {
                    if current_u16 >= u16_idx {
                        return char_count;
                    }
                    current_u16 += c.len_utf16();
                    char_count += 1;
                }
                return char_count;
            }

            current_u16 += line_u16_len;
            char_count += line.len_chars();
        }

        char_count.min(total_chars)
    }

    pub fn char_idx_to_utf16_idx(&self, char_idx: usize) -> usize {
        let actual_idx = char_idx.min(self.buffer.len_chars());
        if actual_idx == 0 {
            return 0;
        }

        let target_line = self.buffer.char_to_line(actual_idx);
        let mut u16_idx = 0;

        // Count UTF-16 for preceding lines
        for i in 0..target_line {
            let line = self.buffer.line(i);
            u16_idx += line.chars().map(|c| c.len_utf16()).sum::<usize>();
        }

        // Count UTF-16 within the target line
        let line_start_char = self.buffer.line_to_char(target_line);
        let chars_in_target_line = actual_idx - line_start_char;
        let line = self.buffer.line(target_line);
        u16_idx += line
            .chars()
            .take(chars_in_target_line)
            .map(|c| c.len_utf16())
            .sum::<usize>();

        u16_idx
    }

    pub fn utf16_idx_to_byte_idx(&self, u16_idx: usize) -> usize {
        let char_idx = self.utf16_idx_to_char_idx(u16_idx);
        self.buffer
            .char_to_byte(char_idx.min(self.buffer.len_chars()))
    }

    pub fn set_content(&mut self, content: &str) {
        self.buffer = Rope::from_str(content);
        self.vim.snap_cursor_to_valid(&self.buffer);
        self.trigger_highlight();
    }

    pub fn set_cursor_u16(&mut self, cursor_u16: usize) {
        let char_pos = self.utf16_idx_to_char_idx(cursor_u16);
        let new_line = self
            .buffer
            .char_to_line(char_pos.min(self.buffer.len_chars()));
        let line_start = self.buffer.line_to_char(new_line);
        self.vim.line = new_line;
        self.vim.col = char_pos.saturating_sub(line_start);
        self.vim.snap_cursor_to_valid(&self.buffer);
    }

    pub fn replace_range(
        &mut self,
        start_u16: usize,
        end_u16: usize,
        text: &str,
        cursor_u16: Option<usize>,
    ) {
        // Record undo history
        let current = (self.buffer.to_string(), self.vim.line, self.vim.col);
        if self.history.back().map(|h| &h.0) != Some(&current.0) {
            self.history.push_back(current);
            if self.history.len() > 100 {
                self.history.pop_front();
            }
            self.redo_stack.clear();
        }

        let start_char = self.utf16_idx_to_char_idx(start_u16);
        let end_char = self.utf16_idx_to_char_idx(end_u16);

        // Remove old range and insert new text
        if start_char <= end_char && end_char <= self.buffer.len_chars() {
            self.buffer.remove(start_char..end_char);
            self.buffer.insert(start_char, text);

            if let Some(c_u16) = cursor_u16 {
                self.set_cursor_u16(c_u16);
            } else {
                let new_char_pos = start_char + text.chars().count();
                let new_line = self
                    .buffer
                    .char_to_line(new_char_pos.min(self.buffer.len_chars()));
                let line_start = self.buffer.line_to_char(new_line);
                self.vim.line = new_line;
                self.vim.col = new_char_pos.saturating_sub(line_start);
            }
            self.trigger_highlight();
        }
    }
    pub fn set_vim_register(&mut self, text: String) {
        self.vim.set_register(text);
    }

    pub fn set_cursor(&mut self, line: usize, col: usize) {
        self.vim.line = line.min(self.buffer.len_lines().saturating_sub(1));
        let line_len = self.buffer.line(self.vim.line).len_chars();
        self.vim.col = col.min(line_len);
    }

    pub fn handle_key(&mut self, key: &str) -> Option<VimAction> {
        let (prev_line, prev_col) = (self.vim.line, self.vim.col);
        let old_content = if key == "u" || key == "\x12" {
            None
        } else {
            Some((self.buffer.to_string(), prev_line, prev_col))
        };
        let action = self.vim.handle_key(key, &self.buffer);

        if let Some(a) = action {
            // Handle replay_keys (recursive playback with live buffer updates)
            if let Some(keys) = a.replay_keys {
                let mut last_res = None;
                for k in keys {
                    last_res = self.handle_key(&k);
                }
                return last_res;
            }

            if let Some(signal) = &a.signal {
                if signal == "undo" {
                    self.undo();
                    return Some(a);
                } else if signal == "redo" {
                    self.redo();
                    return Some(a);
                }
            }

            // Record history before destructive Vim operations
            if a.delete_range.is_some() || a.insert_text.is_some() {
                if let Some(orig) = old_content {
                    if self.history.back().map(|h| &h.0) != Some(&orig.0) {
                        self.history.push_back(orig);
                        if self.history.len() > 100 {
                            self.history.pop_front();
                        }
                        self.redo_stack.clear();
                    }
                }
            }

            if let Some(range) = &a.delete_range {
                let start = self.buffer.line_to_char(range.start_line) + range.start_column;
                let end = self.buffer.line_to_char(range.end_line) + range.end_column;
                if start <= end && end <= self.buffer.len_chars() {
                    self.buffer.remove(start..end);
                }

                if let Some(text) = &a.insert_text {
                    self.buffer.insert(start, text);
                }
            } else if let Some(text) = &a.insert_text {
                let pos = self.buffer.line_to_char(prev_line) + prev_col;
                self.buffer.insert(pos, text);
            }

            self.trigger_highlight();
            if let Some(yank) = &a.yank_text {
                self.last_yank = Some(yank.clone());
            }
            return Some(a);
        }

        // If Vim didn't handle the key (returned None), and we are in Insert mode,
        // treat as literal character input if applicable.
        if self.vim.mode == VimMode::Insert && key.len() == 1 {
            let c = key.chars().next().unwrap();
            if !c.is_control() {
                let pos = self.buffer.line_to_char(prev_line) + prev_col;
                self.buffer.insert(pos, key);
                self.vim.col += 1;
                self.trigger_highlight();
                return Some(self.vim.build_action());
            }
        }

        None
    }

    pub fn get_view(&mut self, start_line: usize, end_line: usize) -> EditorView {
        let mut lines = Vec::new();
        let total_lines = self.buffer.len_lines();
        let end = end_line.min(total_lines);

        for i in start_line..end {
            let line = self.buffer.line(i);
            let start_char = self.buffer.line_to_char(i);
            let start_u16 = self.char_idx_to_utf16_idx(start_char);
            let end_u16 = start_u16 + line.to_string().encode_utf16().count();

            let trimmed_text = line.to_string().trim_end_matches(['\r', '\n']).to_string();
            let trimmed_len_u16 = trimmed_text.encode_utf16().count();

            // Filter spans for this line using binary search to jump to the first relevant span
            let mut line_spans = Vec::new();
            let first_span_idx = self
                .cached_spans
                .binary_search_by_key(&start_u16, |s| s.end)
                .unwrap_or_else(|e| e);

            for span in self.cached_spans.iter().skip(first_span_idx) {
                if span.start >= end_u16 {
                    break; // Spans are sorted, so we can stop here
                }

                // Clip span to this line and make it relative
                let rel_start = span.start.saturating_sub(start_u16);
                let rel_end = (span.end.min(start_u16 + trimmed_len_u16)).saturating_sub(start_u16);
                if rel_start < rel_end {
                    line_spans.push(HighlightSpan {
                        start: rel_start,
                        end: rel_end,
                        label: span.label.clone(),
                        bold: span.bold,
                        italic: span.italic,
                        heading_level: span.heading_level,
                    });
                }
            }

            lines.push(RenderLine {
                text: trimmed_text,
                spans: line_spans,
                is_composing: false,
                start_u16,
                end_u16,
            });
        }

        // Calculate cursor UTF-16 col purely for the current line
        let cursor_line_text = self.buffer.line(self.vim.line).to_string();
        let mut cursor_column_u16 = 0;
        for (i, c) in cursor_line_text.chars().enumerate() {
            if i >= self.vim.col {
                break;
            }
            cursor_column_u16 += c.len_utf16();
        }

        let cursor_line_start_char = self.buffer.line_to_char(self.vim.line);
        let cursor_global_u16 =
            self.char_idx_to_utf16_idx(cursor_line_start_char) + cursor_column_u16;

        let mut selection_start_line = None;
        let mut selection_start_column_u16 = None;

        if let Some((s_line, s_col_char)) = self.vim.selection_start {
            selection_start_line = Some(s_line);

            // Calculate UTF-16 column for selection start
            if s_line < self.buffer.len_lines() {
                let s_line_text = self.buffer.line(s_line).to_string();
                let mut s_col_u16 = 0;
                for (i, c) in s_line_text.chars().enumerate() {
                    if i >= s_col_char {
                        break;
                    }
                    s_col_u16 += c.len_utf16();
                }
                selection_start_column_u16 = Some(s_col_u16);
            }
        }

        EditorView {
            lines,
            start_line,
            cursor_line: self.vim.line,
            cursor_column_u16,
            cursor_global_u16,
            selection_start_line,
            selection_start_column_u16,
            mode: self.vim.mode,
            command_text: self.vim.build_action().command_text,
            search_query: if self.vim.mode == VimMode::Search {
                Some(self.vim.command_buffer.clone())
            } else {
                self.vim.last_search.clone()
            },
            signal: self.vim.build_action().signal,
            yank_text: self.last_yank.take(),
        }
    }

    pub fn undo(&mut self) {
        if let Some((content, line, col)) = self.history.pop_back() {
            self.redo_stack
                .push_back((self.buffer.to_string(), self.vim.line, self.vim.col));
            self.buffer = Rope::from_str(&content);
            self.vim.line = line;
            self.vim.col = col;
            self.vim.snap_cursor_to_valid(&self.buffer);
            self.trigger_highlight();
        }
    }

    pub fn redo(&mut self) {
        if let Some((content, line, col)) = self.redo_stack.pop_back() {
            self.history
                .push_back((self.buffer.to_string(), self.vim.line, self.vim.col));
            self.buffer = Rope::from_str(&content);
            self.vim.line = line;
            self.vim.col = col;
            self.vim.snap_cursor_to_valid(&self.buffer);
            self.trigger_highlight();
        }
    }

    pub fn get_completions(
        &mut self,
        content: String,
        offset_u16: usize,
    ) -> Vec<crate::api::TypstCompletion> {
        // Ensure world is initialized and updated
        if self.world.is_none() {
            self.world = Some(TypinkWorld::new(
                content.clone(),
                HashMap::new(),
                self.preloaded_fonts.clone(),
            ));
        } else if let Some(w) = self.world.as_ref() {
            w.set_main_content(content.clone());
        }

        let world = match self.world.as_ref() {
            Some(w) => w,
            None => return Vec::new(),
        };
        use typst::World;
        let source = world.source(world.main()).unwrap();

        // IMPORTANT: Calculate byte offset from the content string themselves,
        // NOT from self.buffer, because they might be out of sync during IME/fast typing.
        let byte_offset = utf16_to_byte_offset(&content, offset_u16);

        let completions = typst_ide::autocomplete(world, None, &source, byte_offset, false);

        completions
            .map(|(_, items)| {
                items
                    .into_iter()
                    .map(|item| crate::api::TypstCompletion {
                        label: item.label.to_string(),
                        apply: item.apply.map(|a| a.to_string()),
                        detail: item.detail.map(|d| d.to_string()),
                        kind: format!("{:?}", item.kind),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}

/// Safely converts a UTF-16 index to a UTF-8 byte offset within a string.
/// This ensures we always land on a character boundary.
fn utf16_to_byte_offset(text: &str, target_u16: usize) -> usize {
    let mut current_u16 = 0;
    let mut current_byte = 0;
    for c in text.chars() {
        if current_u16 >= target_u16 {
            break;
        }
        current_u16 += c.len_utf16();
        current_byte += c.len_utf8();
    }
    current_byte
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_editor_insert_and_backspace() {
        let mut editor = HeadlessEditor::new();
        editor.set_content("");

        // Switch to insert mode
        editor.handle_key("i");
        assert_eq!(editor.vim.mode, VimMode::Insert);

        // Type "Hello"
        for c in "Hello".chars() {
            editor.handle_key(&c.to_string());
        }

        // Assert content
        assert_eq!(editor.buffer.to_string(), "Hello");

        // Backspace
        editor.handle_key("Backspace");
        assert_eq!(editor.buffer.to_string(), "Hell");
        assert_eq!(editor.vim.col, 4);
    }

    #[test]
    fn test_editor_replace_range_ime() {
        let mut editor = HeadlessEditor::new();
        editor.set_content("Hello");

        // Simulate IME replacing "ll" with "y"
        // H = 1, e = 1, l = 1, l = 1 (UTF-16 indices)
        // replace range 2..4 with "y" -> "Heyo"
        editor.replace_range(2, 4, "y", Some(3));
        assert_eq!(editor.buffer.to_string(), "Heyo");
        assert_eq!(editor.vim.col, 3);
    }

    #[test]
    fn test_editor_vim_navigation() {
        let mut editor = HeadlessEditor::new();
        editor.set_content("Line 1\nLine 2\nLine 3");

        // Move down
        editor.handle_key("j");
        assert_eq!(editor.vim.line, 1);

        // Move right
        editor.handle_key("l");
        assert_eq!(editor.vim.col, 1);
    }

    #[test]
    fn test_editor_word_movements() {
        let mut editor = HeadlessEditor::new();
        editor.set_content("Hello world typink");

        // 'w' to next word
        editor.handle_key("w");
        assert_eq!(editor.vim.col, 6); // start of 'world'

        // 'e' to end of word
        editor.handle_key("e");
        assert_eq!(editor.vim.col, 10); // end of 'world'

        // 'b' to back
        editor.handle_key("b");
        assert_eq!(editor.vim.col, 6);
    }

    #[test]
    fn test_editor_line_operations() {
        let mut editor = HeadlessEditor::new();
        editor.set_content("Line 1\nLine 2\nLine 3");

        // 'dd' to delete line
        editor.handle_key("d");
        editor.handle_key("d");
        assert_eq!(editor.buffer.to_string(), "Line 2\nLine 3");

        // 'p' to paste
        editor.handle_key("p");
        assert_eq!(editor.buffer.to_string(), "Line 2\nLine 1\nLine 3");
    }

    #[test]
    fn test_editor_visual_mode() {
        let mut editor = HeadlessEditor::new();
        editor.set_content("Hello");

        // 'v' to enter visual mode
        editor.handle_key("v");
        assert_eq!(editor.vim.mode, VimMode::Visual);

        // 'l' to expand selection
        editor.handle_key("l");
        // In real vim-engine we'd check selection, for now just ensure mode
        assert_eq!(editor.vim.mode, VimMode::Visual);
    }

    #[test]
    fn test_utf16_to_byte_offset_japanese() {
        let text = "カオス乱流"; // 'カオス' (3 chars, 3*3=9 bytes, 3*1=3 u16)
                                 // '乱流' (2 chars, 2*3=6 bytes, 2*1=2 u16)

        // Offset 3 (after カオス) should be byte 9
        assert_eq!(utf16_to_byte_offset(text, 3), 9);

        // Offset 4 (after 乱) should be byte 12 (9 + 3)
        assert_eq!(utf16_to_byte_offset(text, 4), 12);

        // Offset 5 (after 流) should be byte 15 (12 + 3)
        assert_eq!(utf16_to_byte_offset(text, 5), 15);
    }

    #[test]
    fn test_get_completions_sync_safety() {
        let mut editor = HeadlessEditor::new();
        editor.set_content("initial content"); // buffer is now "initial content"

        // Now call get_completions with DIFFERENT content but Same offset
        // If it use's editor's buffer for offset, it might panic or return wrong results
        let content = "カオス乱流".to_string();
        let offset_u16 = 4; // After '乱'

        // Should NOT panic even if editor.buffer is totally different
        let completions = editor.get_completions(content, offset_u16);
        // We just care that it didn't panic.
        drop(completions);
    }
}
