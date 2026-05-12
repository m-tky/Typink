#![allow(unexpected_cfgs)]

use crate::editor::{EditorView, HeadlessEditor};
use crate::typst_engine::{FontFileData, TypinkWorld};
use crate::vim_engine::VimAction;
use once_cell::sync::Lazy;
use std::sync::{Mutex, MutexGuard};
use typst::World;

static EDITOR: Lazy<Mutex<HeadlessEditor>> = Lazy::new(|| Mutex::new(HeadlessEditor::new()));
static COMPILE_WORLD: Lazy<Mutex<Option<TypinkWorld>>> = Lazy::new(|| Mutex::new(None));

fn lock_editor() -> MutexGuard<'static, HeadlessEditor> {
    match EDITOR.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let guard = poisoned.into_inner();
            #[cfg(target_os = "android")]
            log::warn!("EDITOR lock poisoned! Attempting to recover...");
            eprintln!("RUST_WARNING: EDITOR lock poisoned! Attempting to recover...");
            guard
        }
    }
}

fn lock_compile_world() -> MutexGuard<'static, Option<TypinkWorld>> {
    match COMPILE_WORLD.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

pub struct TypstDiagnostic {
    pub message: String,
    pub line: u32,
    pub column: u32,
    pub severity: u32, // 1: Error, 2: Warning, 3: Hint, 4: Info
}

pub struct TypstPage {
    pub image: Vec<u8>,
}

pub struct TypstCompileResult {
    pub pages: Vec<TypstPage>,
    pub diagnostics: Vec<TypstDiagnostic>,
}

pub struct TypstCompletion {
    pub label: String,
    pub apply: Option<String>,
    pub detail: Option<String>,
    pub kind: String,
}

pub fn hello_from_rust() -> String {
    "Hello from Rust!".to_string()
}

pub struct ExtraFile {
    pub name: String,
    pub data: Vec<u8>,
}

pub fn compile_typst(content: String, extra_files: Vec<ExtraFile>) -> TypstCompileResult {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut extras = std::collections::HashMap::new();
        for file in extra_files {
            extras.insert(file.name, file.data);
        }

        // 1. Get fonts with a brief EDITOR lock, released immediately.
        let fonts = {
            let editor = lock_editor();
            editor.preloaded_fonts.clone()
        };

        // 2. Lock the compile world and initialise or update it.
        let mut cw = lock_compile_world();
        if cw.is_none() {
            *cw = Some(TypinkWorld::new(content.clone(), extras.clone(), fonts));
        } else {
            let world = cw.as_ref().unwrap();
            world.set_main_content(content.clone());
            world.update_files(extras.clone());
        }

        let output = typst::compile::<typst::layout::PagedDocument>(cw.as_ref().unwrap());

        match output.output {
            Ok(paged_doc) => {
                let mut pages = Vec::new();
                for page in &paged_doc.pages {
                    let canvas = typst_render::render(
                        page, 2.0, // 2x scaling for clarity
                    );

                    let image = canvas.encode_png().expect("PNG encoding failed");
                    pages.push(TypstPage { image });
                }
                TypstCompileResult {
                    pages,
                    diagnostics: Vec::new(),
                }
            }
            Err(diags) => {
                let world = cw.as_ref().unwrap();
                let source = world.source(world.main()).unwrap();
                let mut diagnostics = Vec::new();

                for diag in diags {
                    let range = source.range(diag.span).unwrap_or(0..0);
                    let text = source.text();
                    let line = text[..range.start].chars().filter(|&c| c == '\n').count();
                    let last_line_start =
                        text[..range.start].rfind('\n').map(|i| i + 1).unwrap_or(0);
                    let column = text[last_line_start..range.start].chars().count();

                    let severity = match diag.severity {
                        typst::diag::Severity::Error => 1,
                        typst::diag::Severity::Warning => 2,
                    };

                    diagnostics.push(TypstDiagnostic {
                        message: diag.message.to_string(),
                        line: line as u32,
                        column: column as u32,
                        severity,
                    });
                }

                TypstCompileResult {
                    pages: Vec::new(),
                    diagnostics,
                }
            }
        }
    }));

    match result {
        Ok(val) => val,
        Err(_) => TypstCompileResult {
            pages: vec![],
            diagnostics: vec![],
        },
    }
}

pub fn compile_pdf(content: String, extra_files: Vec<ExtraFile>) -> Option<Vec<u8>> {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut extras = std::collections::HashMap::new();
        for file in extra_files {
            extras.insert(file.name, file.data);
        }

        // 1. Get fonts with a brief EDITOR lock, released immediately.
        let fonts = {
            let editor = lock_editor();
            editor.preloaded_fonts.clone()
        };

        // 2. Lock the compile world and initialise or update it.
        let mut cw = lock_compile_world();
        if cw.is_none() {
            *cw = Some(TypinkWorld::new(content.clone(), extras.clone(), fonts));
        } else {
            let world = cw.as_ref().unwrap();
            world.set_main_content(content.clone());
            world.update_files(extras.clone());
        }

        let output = typst::compile::<typst::layout::PagedDocument>(cw.as_ref().unwrap());

        match output.output {
            Ok(paged_doc) => {
                let pdf = typst_pdf::pdf(&paged_doc, &typst_pdf::PdfOptions::default()).ok()?;
                Some(pdf)
            }
            Err(_) => None,
        }
    }));

    result.unwrap_or(None)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_editor_view(start_line: usize, end_line: usize) -> EditorView {
    let mut editor = lock_editor();
    editor.get_view(start_line, end_line)
}

pub async fn get_completions(content: String, offset_u16: usize) -> Vec<TypstCompletion> {
    let res = std::thread::Builder::new()
        .name("typst-autocomplete".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            std::panic::catch_unwind(move || {
                let mut editor = lock_editor();
                editor.get_completions(content, offset_u16)
            })
        })
        .unwrap()
        .join();

    match res {
        Ok(Ok(completions)) => completions,
        _ => Vec::new(),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_key(key: String) -> Option<VimAction> {
    let mut editor = lock_editor();
    editor.handle_key(&key)
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_set_vim_register(text: String) {
    let mut editor = lock_editor();
    editor.set_vim_register(text);
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_init_fonts(fonts: Vec<FontFileData>) {
    let mut editor = lock_editor();
    editor.preloaded_fonts = fonts;
    // Clear the world to force a rebuild with new fonts
    editor.world = None;
    drop(editor);
    *lock_compile_world() = None;
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    init_rust();
}

#[no_mangle]
pub extern "C" fn frb_init_app() {
    init_rust();
}

fn init_rust() {
    use std::sync::Once;
    static START: Once = Once::new();

    START.call_once(|| {
        #[cfg(target_os = "android")]
        {
            android_logger::init_once(
                android_logger::Config::default()
                    .with_max_level(log::LevelFilter::Debug)
                    .with_tag("RustCore"),
            );
            log::info!("Rust Core initialized");
        }

        std::panic::set_hook(Box::new(|info| {
            let msg = if let Some(s) = info.payload().downcast_ref::<&str>() {
                *s
            } else if let Some(s) = info.payload().downcast_ref::<String>() {
                &s[..]
            } else {
                "unknown panic"
            };
            let location = info.location().map(|l| l.to_string()).unwrap_or_default();

            #[cfg(target_os = "android")]
            log::error!("RUST_PANIC: {} at {}", msg, location);

            eprintln!("RUST_PANIC: {} at {}", msg, location);
        }));
    });
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_init_jni_safety() {
    // Deprecated in favor of init_app, but keeping for compatibility if called elsewhere
    init_app();
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_get_total_lines() -> usize {
    let editor = lock_editor();
    editor.buffer.len_lines()
}

pub fn handle_editor_trigger_highlight() {
    let mut editor = lock_editor();
    editor.trigger_highlight();
}

pub fn handle_editor_save(path: String) -> Result<(), String> {
    let editor = lock_editor();
    editor.save(&path).map_err(|e| e.to_string())
}

pub fn handle_editor_load(path: String) -> Result<String, String> {
    let mut editor = lock_editor();
    editor.load(&path).map_err(|e| e.to_string())?;
    Ok(editor.buffer.to_string())
}

pub fn handle_editor_export_pdf(path: String) -> Result<(), String> {
    let res = std::thread::Builder::new()
        .name("typst-export".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            std::panic::catch_unwind(move || {
                let mut editor = lock_editor();
                editor.export_pdf(&path)
            })
        })
        .unwrap()
        .join();

    match res {
        Ok(Ok(val)) => val,
        _ => Err("PDF export failed or panicked".into()),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_replace_range(
    start_u16: usize,
    end_u16: usize,
    text: String,
    cursor_u16: Option<usize>,
) {
    let mut editor = lock_editor();
    editor.replace_range(start_u16, end_u16, &text, cursor_u16);
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_update_selection(cursor_u16: usize) {
    let mut editor = lock_editor();
    editor.set_cursor_u16(cursor_u16);
}

#[flutter_rust_bridge::frb(sync)]
pub fn handle_editor_set_cursor(line: usize, col: usize) {
    let mut editor = lock_editor();
    editor.set_cursor(line, col);
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_editor_content() -> String {
    let editor = lock_editor();
    editor.buffer.to_string()
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_editor_content(content: String) {
    let mut editor = lock_editor();
    editor.set_content(&content);
}
