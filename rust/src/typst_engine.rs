use chrono::{Datelike, Local};
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::Mutex;
use typst::foundations::{Bytes, Datetime};
use typst::syntax::{FileId, Source};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_ide::IdeWorld;
use walkdir::WalkDir;

#[derive(Clone)]
pub struct FontFileData {
    pub path: String,
    pub bytes: Vec<u8>,
}

pub struct TypinkWorld {
    library: LazyHash<Library>,
    fonts: LazyHash<FontBook>,
    font_data: Vec<Font>,
    sources: Mutex<HashMap<FileId, Source>>,
    data: Mutex<HashMap<FileId, Bytes>>,
    main_id: FileId,
}

impl TypinkWorld {
    pub fn new(
        main_content: String,
        extra_files: HashMap<String, Vec<u8>>,
        preloaded_fonts: Vec<FontFileData>,
    ) -> Self {
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

        // 1. Process preloaded fonts (Priority for Android assets)
        for font_file in preloaded_fonts {
            let bytes = Bytes::new(font_file.bytes);
            for font in Font::iter(bytes) {
                book.push(font.info().clone());
                font_data.push(font);
            }
        }

        #[cfg(target_os = "linux")]
        {
            // フォントの検索パス (NixOS / Linux 共通)
            let font_paths = ["/run/current-system/sw/share/X11/fonts", "/usr/share/fonts"];

            'outer: for path in font_paths.iter() {
                if !Path::new(path).exists() {
                    continue;
                }

                for entry in WalkDir::new(path)
                    .follow_links(true)
                    .into_iter()
                    .filter_map(|e| e.ok())
                    .filter(|e| {
                        e.path()
                            .extension()
                            .is_some_and(|ext| ext == "ttf" || ext == "otf")
                    })
                {
                    if let Ok(data) = fs::read(entry.path()) {
                        let bytes = Bytes::new(data);
                        for font in Font::iter(bytes) {
                            book.push(font.info().clone());
                            font_data.push(font);
                        }
                    }
                    // 起動速度のために合計100個で見切る
                    if font_data.len() > 100 {
                        break 'outer;
                    }
                }
            }
        }

        Self {
            library: LazyHash::new(library),
            fonts: LazyHash::new(book),
            font_data,
            sources: Mutex::new(sources),
            data: Mutex::new(data),
            main_id,
        }
    }

    pub fn set_main_content(&self, content: String) {
        let mut sources = self.sources.lock().unwrap();
        let source = Source::new(self.main_id, content);
        sources.insert(self.main_id, source);
    }

    pub fn update_files(&self, extra_files: std::collections::HashMap<String, Vec<u8>>) {
        let mut data = self.data.lock().unwrap();
        data.clear();
        for (name, content) in extra_files {
            let id = FileId::new(None, typst::syntax::VirtualPath::new(name));
            data.insert(id, Bytes::new(content));
        }
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
        let sources = self.sources.lock().unwrap();

        // 1. Exact match
        if let Some(source) = sources.get(&id) {
            return Ok(source.clone());
        }

        // 2. Case-insensitive fallback
        let req_path = id.vpath().as_rooted_path().to_string_lossy().to_lowercase();
        for (stored_id, source) in &*sources {
            if stored_id
                .vpath()
                .as_rooted_path()
                .to_string_lossy()
                .to_lowercase()
                == req_path
            {
                return Ok(source.clone());
            }
        }

        Err(typst::diag::FileError::NotFound(
            id.vpath().as_rooted_path().to_path_buf(),
        ))
    }

    fn font(&self, id: usize) -> Option<Font> {
        self.font_data.get(id).cloned()
    }

    fn file(&self, id: FileId) -> Result<Bytes, typst::diag::FileError> {
        let data = self.data.lock().unwrap();

        // 1. Exact match
        if let Some(bytes) = data.get(&id) {
            return Ok(bytes.clone());
        }

        // 2. Full path case-insensitive fallback
        let req_path = id.vpath().as_rooted_path().to_string_lossy().to_lowercase();
        for (stored_id, bytes) in &*data {
            if stored_id
                .vpath()
                .as_rooted_path()
                .to_string_lossy()
                .to_lowercase()
                == req_path
            {
                return Ok(bytes.clone());
            }
        }

        // 3. Filename-only fallback (extreme resilience)
        let req_filename = id
            .vpath()
            .as_rooted_path()
            .file_name()
            .map(|f| f.to_string_lossy().to_lowercase());

        if let Some(req_f) = req_filename {
            for (stored_id, bytes) in &*data {
                if let Some(stored_f) = stored_id.vpath().as_rooted_path().file_name() {
                    if stored_f.to_string_lossy().to_lowercase() == req_f {
                        return Ok(bytes.clone());
                    }
                }
            }
        }

        Err(typst::diag::FileError::NotFound(
            id.vpath().as_rooted_path().to_path_buf(),
        ))
    }

    fn today(&self, _offset: Option<i64>) -> Option<Datetime> {
        let now = Local::now();
        Datetime::from_ymd(now.year(), now.month() as u8, now.day() as u8)
    }
}

impl IdeWorld for TypinkWorld {
    fn upcast(&self) -> &dyn World {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vfs_resolution() {
        let mut extras = HashMap::new();
        extras.insert("hello/fig_1.svg".to_string(), vec![1, 2, 3]);
        let world = TypinkWorld::new("".to_string(), extras, Vec::new());

        // Simulate Typst requesting /hello/fig_1.svg
        let id = FileId::new(None, typst::syntax::VirtualPath::new("hello/fig_1.svg"));
        let result = world.file(id);
        assert!(
            result.is_ok(),
            "Failed to resolve hello/fig_1.svg precisely"
        );

        let id2 = FileId::new(None, typst::syntax::VirtualPath::new("/hello/fig_1.svg"));
        let result2 = world.file(id2);
        assert!(result2.is_ok(), "Failed to resolve /hello/fig_1.svg");

        // CROSS-FOLDER CASE: Registered in figures/ but requested in hello/
        let mut extras2 = HashMap::new();
        extras2.insert("figures/fig_2.svg".to_string(), vec![4, 5, 6]);
        let world2 = TypinkWorld::new("".to_string(), extras2, Vec::new());

        let id3 = FileId::new(None, typst::syntax::VirtualPath::new("hello/fig_2.svg"));
        let result3 = world2.file(id3);
        assert!(
            result3.is_ok(),
            "Failed to resolve hello/fig_2.svg via fuzzy filename match"
        );
    }
}
