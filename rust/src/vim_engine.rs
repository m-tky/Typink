use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VimMode {
    Normal,
    Insert,
    Visual,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VimAction {
    pub mode: VimMode,
    pub cursor_line: usize,
    pub cursor_column: usize,
    pub selection_start_line: Option<usize>,
    pub selection_start_column: Option<usize>,
    pub delete_range: Option<VimRange>,
    pub insert_text: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VimRange {
    pub start_line: usize,
    pub start_column: usize,
    pub end_line: usize,
    pub end_column: usize,
}

pub struct VimEngine {
    pub mode: VimMode,
    pub line: usize,
    pub col: usize,
    pub selection_start: Option<(usize, usize)>,
    pub register: String,
    pub pending_operator: Option<char>,
}

impl VimEngine {
    pub fn new() -> Self {
        Self {
            mode: VimMode::Normal,
            line: 0,
            col: 0,
            selection_start: None,
            register: String::new(),
            pending_operator: None,
        }
    }

    pub fn handle_key(&mut self, key: &str, content: &str) -> Option<VimAction> {
        match self.mode {
            VimMode::Normal => self.handle_normal(key, content),
            VimMode::Insert => self.handle_insert(key),
            VimMode::Visual => self.handle_visual(key, content),
        }
    }

    fn handle_normal(&mut self, key: &str, content: &str) -> Option<VimAction> {
        let lines: Vec<&str> = content.lines().collect();
        let current_line_content = lines.get(self.line).copied().unwrap_or("");

        // Handle operator pending mode (dd, yy)
        if let Some(op) = self.pending_operator {
            self.pending_operator = None;
            if op == 'd' && key == "d" {
                // Delete line
                self.register = format!("{}\n", current_line_content);
                let mut action = self.build_action();
                
                if lines.len() > 1 {
                    if self.line + 1 < lines.len() {
                        // Not the last line, delete this line and its newline
                        action.delete_range = Some(VimRange {
                            start_line: self.line,
                            start_column: 0,
                            end_line: self.line + 1,
                            end_column: 0,
                        });
                    } else {
                        // Last line, delete from previous newline to end
                        action.delete_range = Some(VimRange {
                            start_line: self.line - 1,
                            start_column: lines[self.line - 1].chars().count(),
                            end_line: self.line,
                            end_column: current_line_content.chars().count(),
                        });
                        self.line -= 1;
                        action.cursor_line = self.line;
                    }
                } else {
                    // Only one line, just clear it
                    action.delete_range = Some(VimRange {
                        start_line: 0,
                        start_column: 0,
                        end_line: 0,
                        end_column: current_line_content.chars().count(),
                    });
                    self.col = 0;
                    action.cursor_column = 0;
                }
                return Some(action);
            } else if op == 'y' && key == "y" {
                // Yank line
                self.register = format!("{}\n", current_line_content);
                return Some(self.build_action());
            }
        }

        match key {
            "h" => {
                if self.col > 0 { self.col -= 1; }
            }
            "j" => {
                if self.line + 1 < lines.len() {
                    self.line += 1;
                    let next_line_len = lines[self.line].chars().count();
                    if self.col >= next_line_len {
                        self.col = if next_line_len > 0 { next_line_len - 1 } else { 0 };
                    }
                }
            }
            "k" => {
                if self.line > 0 {
                    self.line -= 1;
                    let prev_line_len = lines[self.line].chars().count();
                    if self.col >= prev_line_len {
                        self.col = if prev_line_len > 0 { prev_line_len - 1 } else { 0 };
                    }
                }
            }
            "l" => {
                let current_len = current_line_content.chars().count();
                if self.col + 1 < current_len { self.col += 1; }
            }
            "i" => {
                self.mode = VimMode::Insert;
                return Some(self.build_action());
            }
            "a" => {
                self.mode = VimMode::Insert;
                let current_len = current_line_content.chars().count();
                if self.col < current_len { self.col += 1; }
                return Some(self.build_action());
            }
            "o" => {
                self.mode = VimMode::Insert;
                self.line += 1;
                self.col = 0;
                let mut action = self.build_action();
                action.insert_text = Some("\n".to_string());
                return Some(action);
            }
            "w" => {
                let text = current_line_content.chars().collect::<Vec<char>>();
                let mut i = self.col;
                // skip current chars then skip spaces
                while i < text.len() && !text[i].is_whitespace() { i += 1; }
                while i < text.len() && text[i].is_whitespace() { i += 1; }
                self.col = i.min(text.len().saturating_sub(1));
            }
            "e" => {
                let text = current_line_content.chars().collect::<Vec<char>>();
                let mut i = self.col;
                if i + 1 < text.len() && text[i+1].is_whitespace() { i += 1; }
                while i < text.len() && text[i].is_whitespace() { i += 1; }
                while i + 1 < text.len() && !text[i+1].is_whitespace() { i += 1; }
                self.col = i.min(text.len().saturating_sub(1));
            }
            "b" => {
                let text = current_line_content.chars().collect::<Vec<char>>();
                let mut i = self.col;
                if i > 0 && text[i-1].is_whitespace() { i -= 1; }
                while i > 0 && text[i].is_whitespace() { i -= 1; }
                while i > 0 && !text[i-1].is_whitespace() { i -= 1; }
                self.col = i;
            }
            "d" => {
                self.pending_operator = Some('d');
            }
            "y" => {
                self.pending_operator = Some('y');
            }
            "p" => {
                if !self.register.is_empty() {
                    let mut action = self.build_action();
                    action.insert_text = Some(self.register.clone());
                    if self.register.ends_with('\n') {
                        self.line += 1;
                        self.col = 0;
                        action.cursor_line = self.line;
                        action.cursor_column = self.col;
                    }
                    return Some(action);
                }
            }
            "x" => {
                let current_len = current_line_content.chars().count();
                if current_len > 0 {
                    let mut action = self.build_action();
                    action.delete_range = Some(VimRange {
                        start_line: self.line,
                        start_column: self.col,
                        end_line: self.line,
                        end_column: self.col + 1,
                    });
                    return Some(action);
                }
            }
            "v" => {
                self.mode = VimMode::Visual;
                self.selection_start = Some((self.line, self.col));
            }
            "0" => {
                self.col = 0;
            }
            "$" => {
                let current_len = current_line_content.encode_utf16().count();
                self.col = if current_len > 0 { current_len - 1 } else { 0 };
            }
            _ => return None,
        }

        Some(self.build_action())
    }

    fn handle_insert(&mut self, key: &str) -> Option<VimAction> {
        if key == "Escape" {
            self.mode = VimMode::Normal;
            if self.col > 0 { self.col -= 1; }
            return Some(self.build_action());
        }
        None
    }

    fn handle_visual(&mut self, key: &str, content: &str) -> Option<VimAction> {
        if key == "Escape" || key == "v" {
            self.mode = VimMode::Normal;
            self.selection_start = None;
            return Some(self.build_action());
        }
        
        // Use normal movements but update selection state
        let action = self.handle_normal(key, content);
        if let Some(mut a) = action {
            if let Some((sl, sc)) = self.selection_start {
                a.selection_start_line = Some(sl);
                a.selection_start_column = Some(sc);
            }
            return Some(a);
        }
        None
    }

    pub fn build_action(&self) -> VimAction {
        VimAction {
            mode: self.mode,
            cursor_line: self.line,
            cursor_column: self.col,
            selection_start_line: self.selection_start.map(|(l, _)| l),
            selection_start_column: self.selection_start.map(|(_, c)| c),
            delete_range: None,
            insert_text: None,
        }
    }
}
