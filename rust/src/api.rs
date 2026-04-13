use crate::typst_engine::TypinkWorld;
use typst::World;

pub struct TypstError {
    pub message: String,
    pub line: u32,
    pub column: u32,
}

pub struct TypstPage {
    pub image: Vec<u8>,
}

pub struct TypstCompileResult {
    pub pages: Vec<TypstPage>,
    pub errors: Vec<TypstError>,
}

pub fn hello_from_rust() -> String {
    "Hello from Rust!".to_string()
}

pub struct ExtraFile {
    pub name: String,
    pub data: Vec<u8>,
}

pub fn compile_typst(content: String, extra_files: Vec<ExtraFile>) -> TypstCompileResult {
    let mut extras = std::collections::HashMap::new();
    for file in extra_files {
        extras.insert(file.name, file.data);
    }
    
    let world = TypinkWorld::new(content, extras);
    let output = typst::compile::<typst::layout::PagedDocument>(&world).output;
    
    match output {
        Ok(paged_doc) => {
            let mut pages = Vec::new();
            for page in &paged_doc.pages {
                let canvas = typst_render::render(
                    page,
                    2.0, // 2x scaling for clarity
                );
                
                let image = canvas.encode_png().expect("PNG encoding failed");
                pages.push(TypstPage { image });
            }
            TypstCompileResult {
                pages,
                errors: Vec::new(),
            }
        }
        Err(diags) => {
            let mut errors = Vec::new();
            let source = world.source(world.main()).unwrap();
            
            for diag in diags {
                let range = source.range(diag.span).unwrap_or(0..0);
                let line = source.byte_to_line(range.start).unwrap_or(0);
                let column = source.byte_to_column(range.start).unwrap_or(0);
                
                errors.push(TypstError {
                    message: diag.message.to_string(),
                    line: line as u32,
                    column: column as u32,
                });
            }
            
            TypstCompileResult {
                pages: Vec::new(),
                errors,
            }
        }
    }
}

pub fn compile_pdf(content: String, extra_files: Vec<ExtraFile>) -> Option<Vec<u8>> {
    let mut extras = std::collections::HashMap::new();
    for file in extra_files {
        extras.insert(file.name, file.data);
    }
    
    let world = TypinkWorld::new(content, extras);
    let output = typst::compile::<typst::layout::PagedDocument>(&world).output;
    
    match output {
        Ok(paged_doc) => {
            let pdf = typst_pdf::pdf(&paged_doc, &typst_pdf::PdfOptions::default()).ok()?;
            Some(pdf)
        }
        Err(_) => None,
    }
}
use crate::editor::{HeadlessEditor, EditorView};
use crate::vim_engine::{VimAction};
use crate::highlighter::{HighlightSpan};
use once_cell::sync::Lazy;
use std::sync::Mutex;

static EDITOR: Lazy<Mutex<HeadlessEditor>> = Lazy::new(|| Mutex::new(HeadlessEditor::new()));

#[flutter_rust_bridge::frb(sync)]
pub fn get_editor_view(start_line: usize, end_line: usize) -> EditorView {
    let editor = EDITOR.lock().unwrap();
    editor.get_view(start_line, end_line)
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_key(key: String) -> Option<VimAction> {
    let mut editor = EDITOR.lock().unwrap();
    editor.handle_key(&key)
}

pub fn handle_editor_trigger_highlight() {
    let mut editor = EDITOR.lock().unwrap();
    editor.trigger_highlight();
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_replace_range(start_u16: usize, end_u16: usize, text: String, cursor_u16: Option<usize>) {
    let mut editor = EDITOR.lock().unwrap();
    editor.replace_range(start_u16, end_u16, &text, cursor_u16);
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_update_selection(cursor_u16: usize) {
    let mut editor = EDITOR.lock().unwrap();
    editor.set_cursor_u16(cursor_u16);
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_editor_content() -> String {
    let editor = EDITOR.lock().unwrap();
    editor.buffer.to_string()
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_editor_content(content: String) {
    let mut editor = EDITOR.lock().unwrap();
    editor.set_content(&content);
}
