use std::collections::HashMap;
use std::sync::Mutex;
use std::fs;
use std::path::Path;
use typst::foundations::{Bytes, Datetime};
use typst::syntax::{FileId, Source};
use typst::text::{Font, FontBook};
use typst::Library;
use typst::World;
use typst::utils::LazyHash;
use chrono::{Local, Datelike};
use walkdir::WalkDir;

pub struct TypinkWorld {
    library: LazyHash<Library>,
    fonts: LazyHash<FontBook>,
    font_data: Vec<Font>,
    sources: Mutex<HashMap<FileId, Source>>,
    data: HashMap<FileId, Bytes>,
    main_id: FileId,
}

impl TypinkWorld {
    pub fn new(main_content: String, extra_files: HashMap<String, Vec<u8>>) -> Self {
        let library = Library::default();
        let main_id = FileId::new(None, typst::syntax::VirtualPath::new("main.typ"));
        let main_source = Source::new(main_id, main_content);
        
        let mut sources = HashMap::new();
        sources.insert(main_id, main_source);

        let mut font_data = Vec::new();
        let mut book = FontBook::new();

        let mut data = HashMap::new();
        for (name, content) in extra_files {
            let id = FileId::new(None, typst::syntax::VirtualPath::new(name.clone()));
            data.insert(id, Bytes::new(content.clone()));

            // Additional check: if this is a font file, register it
            if name.ends_with(".ttf") || name.ends_with(".otf") {
                let bytes = Bytes::new(content);
                for font in Font::iter(bytes) {
                    book.push(font.info().clone());
                    font_data.push(font);
                }
            }
        }

        // フォントの検索パス (NixOS / Linux 共通 + Bundled Assets)
        let font_paths = [
            "/home/user/Code/rust/Typink/flutter_app/assets/fonts",
            "/run/current-system/sw/share/X11/fonts",
            "/usr/share/fonts",
        ];

        for (i, path) in font_paths.iter().enumerate() {
            if !Path::new(path).exists() { continue; }
            
            for entry in WalkDir::new(path)
                .follow_links(true)
                .into_iter()
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().map_or(false, |ext| ext == "ttf" || ext == "otf"))
            {
                if let Ok(data) = fs::read(entry.path()) {
                    let bytes = Bytes::new(data);
                    for font in Font::iter(bytes) {
                        book.push(font.info().clone());
                        font_data.push(font);
                    }
                }
                // アセットフォルダ(index 0)以外は、起動速度のために合計100個で見切る
                if i > 0 && font_data.len() > 100 { break; }
            }
            if i > 0 && font_data.len() > 100 { break; }
        }

        Self {
            library: LazyHash::new(library),
            fonts: LazyHash::new(book),
            font_data,
            sources: Mutex::new(sources),
            data,
            main_id,
        }
    }

    pub fn set_main_content(&self, content: String) {
        let mut sources = self.sources.lock().unwrap();
        let source = Source::new(self.main_id, content);
        sources.insert(self.main_id, source);
    }
}

impl World for TypinkWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        &self.fonts
    }

    fn main(&self) -> FileId {
        self.main_id
    }

    fn source(&self, id: FileId) -> Result<Source, typst::diag::FileError> {
        self.sources
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or_else(|| typst::diag::FileError::NotFound(id.vpath().as_rooted_path().to_path_buf()))
    }

    fn font(&self, id: usize) -> Option<Font> {
        self.font_data.get(id).cloned()
    }

    fn file(&self, id: FileId) -> Result<Bytes, typst::diag::FileError> {
        self.data
            .get(&id)
            .cloned()
            .ok_or_else(|| typst::diag::FileError::NotFound(id.vpath().as_rooted_path().to_path_buf()))
    }

    fn today(&self, _offset: Option<i64>) -> Option<Datetime> {
        let now = Local::now();
        Datetime::from_ymd(now.year(), now.month() as u8, now.day() as u8)
    }
}
