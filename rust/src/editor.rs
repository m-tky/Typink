use ropey::Rope;
use crate::vim_engine::{VimEngine, VimMode, VimAction};
use crate::highlighter::{highlight_typst, HighlightSpan};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RenderLine {
    pub text: String,
    pub spans: Vec<HighlightSpan>,
    pub is_composing: bool,
    pub start_u16: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EditorView {
    pub lines: Vec<RenderLine>,
    pub cursor_line: usize,
    pub cursor_column_u16: usize, // UTF-16 index within the line
    pub cursor_global_u16: usize, // UTF-16 index within the full buffer
    pub mode: VimMode,
}

pub struct HeadlessEditor {
    pub buffer: Rope,
    pub vim: VimEngine,
    pub composing_text: Option<String>,
    pub composing_start_u16: usize,
    pub cached_spans: Vec<HighlightSpan>,
}

impl HeadlessEditor {
    pub fn new() -> Self {
        Self {
            buffer: Rope::new(),
            vim: VimEngine::new(),
            composing_text: None,
            composing_start_u16: 0,
            cached_spans: Vec::new(),
        }
    }

    pub fn trigger_highlight(&mut self) {
        let content = self.buffer.to_string();
        self.cached_spans = highlight_typst(&content);
    }

    /// Converts a global UTF-16 index to a character index in the Rope.
    /// This is the core "bridge" logic identifying which character in Rust corresponds to a Flutter index.
    pub fn utf16_idx_to_char_idx(&self, u16_idx: usize) -> usize {
        let mut current_u16 = 0;
        let mut char_count = 0;
        for chunk in self.buffer.chunks() {
            for c in chunk.chars() {
                if current_u16 >= u16_idx {
                    return char_count;
                }
                current_u16 += c.len_utf16();
                char_count += 1;
            }
        }
        char_count
    }

    pub fn char_idx_to_utf16_idx(&self, char_idx: usize) -> usize {
        let actual_idx = char_idx.min(self.buffer.len_chars());
        let mut u16_idx = 0;
        for chunk in self.buffer.slice(..actual_idx).chunks() {
            u16_idx += chunk.encode_utf16().count();
        }
        u16_idx
    }

    pub fn set_content(&mut self, content: &str) {
        self.buffer = Rope::from_str(content);
    }

    pub fn set_cursor_u16(&mut self, cursor_u16: usize) {
        let char_pos = self.utf16_idx_to_char_idx(cursor_u16);
        let new_line = self.buffer.char_to_line(char_pos.min(self.buffer.len_chars()));
        let line_start = self.buffer.line_to_char(new_line);
        self.vim.line = new_line;
        self.vim.col = char_pos.saturating_sub(line_start);
    }

    pub fn replace_range(&mut self, start_u16: usize, end_u16: usize, text: &str, cursor_u16: Option<usize>) {
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
                let new_line = self.buffer.char_to_line(new_char_pos.min(self.buffer.len_chars()));
                let line_start = self.buffer.line_to_char(new_line);
                self.vim.line = new_line;
                self.vim.col = new_char_pos.saturating_sub(line_start);
            }
        }
    }

    pub fn handle_key(&mut self, key: &str) -> Option<VimAction> {
        let full_text: String = self.buffer.clone().into();
        let action = self.vim.handle_key(key, &full_text);

        if action.is_some() {
            // Apply side effects if needed (e.g., delete_range)
            // For now, VimAction is mostly informative for Flutter, but buffer must stay in sync.
            if let Some(a) = &action {
                if let Some(range) = &a.delete_range {
                    let start = self.buffer.line_to_char(range.start_line) + range.start_column;
                    let end = self.buffer.line_to_char(range.end_line) + range.end_column;
                    self.buffer.remove(start..end);
                }
                if let Some(text) = &a.insert_text {
                    let pos = self.buffer.line_to_char(self.vim.line) + self.vim.col;
                    self.buffer.insert(pos, text);
                }
            }
            return action;
        }

        // If Vim didn't handle the key, and we are in Insert mode, treat as literal input
        if self.vim.mode == VimMode::Insert {
            let pos = self.buffer.line_to_char(self.vim.line) + self.vim.col;
            match key {
                "Backspace" => {
                    if pos > 0 {
                        self.buffer.remove(pos - 1..pos);
                        if self.vim.col > 0 {
                            self.vim.col -= 1;
                        } else if self.vim.line > 0 {
                            self.vim.line -= 1;
                            self.vim.col = self.buffer.line(self.vim.line).len_chars().saturating_sub(1);
                        }
                    }
                }
                "Enter" => {
                    self.buffer.insert(pos, "\n");
                    self.vim.line += 1;
                    self.vim.col = 0;
                }
                k if k.chars().count() == 1 => {
                    self.buffer.insert(pos, k);
                    self.vim.col += 1;
                }
                _ => {}
            }
            return Some(self.vim.build_action());
        }

        None
    }

    pub fn get_view(&self, start_line: usize, end_line: usize) -> EditorView {
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

            // Filter spans for this line
            let mut line_spans = Vec::new();
            for span in &self.cached_spans {
                if span.end > start_u16 && span.start < end_u16 {
                    // Clip span to this line and make it relative
                    let rel_start = span.start.saturating_sub(start_u16);
                    let rel_end = (span.end.min(start_u16 + trimmed_len_u16)).saturating_sub(start_u16);
                    if rel_start < rel_end {
                        line_spans.push(HighlightSpan {
                            start: rel_start,
                            end: rel_end,
                            label: span.label.clone(),
                        });
                    }
                }
            }

            lines.push(RenderLine {
                text: trimmed_text,
                spans: line_spans,
                is_composing: false,
                start_u16,
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
        let cursor_global_u16 = self.char_idx_to_utf16_idx(cursor_line_start_char) + cursor_column_u16;

        EditorView {
            lines,
            cursor_line: self.vim.line,
            cursor_column_u16,
            cursor_global_u16,
            mode: self.vim.mode,
        }
    }
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
}
