use ratatui::style::Color;
use std::path::Path;

/// High-level file categories, used for treemap/list coloring.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileCategory {
    Video,
    Audio,
    Image,
    Archive,
    Document,
    Code,
    Binary,
    Data,
    Other,
}

impl FileCategory {
    pub fn of(path: &Path) -> Self {
        let ext = match path.extension().and_then(|e| e.to_str()) {
            Some(e) => e.to_ascii_lowercase(),
            None => return FileCategory::Other,
        };
        match ext.as_str() {
            "mp4" | "mov" | "mkv" | "avi" | "webm" | "m4v" | "wmv" | "flv" | "mpg" | "mpeg" => {
                FileCategory::Video
            }
            "mp3" | "wav" | "flac" | "aac" | "ogg" | "m4a" | "aiff" | "wma" | "opus" => {
                FileCategory::Audio
            }
            "jpg" | "jpeg" | "png" | "gif" | "webp" | "heic" | "tiff" | "tif" | "bmp" | "svg"
            | "raw" | "cr2" | "nef" | "psd" | "ai" => FileCategory::Image,
            "zip" | "tar" | "gz" | "bz2" | "xz" | "zst" | "7z" | "rar" | "dmg" | "iso" | "pkg"
            | "deb" | "rpm" | "jar" | "war" => FileCategory::Archive,
            "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "txt" | "md" | "rtf"
            | "odt" | "epub" | "pages" | "key" | "numbers" => FileCategory::Document,
            "rs" | "py" | "js" | "ts" | "tsx" | "jsx" | "c" | "cpp" | "h" | "hpp" | "go"
            | "java" | "kt" | "swift" | "rb" | "php" | "sh" | "pl" | "lua" | "html" | "css"
            | "scss" | "vue" | "svelte" => FileCategory::Code,
            "app" | "exe" | "dll" | "so" | "dylib" | "bin" | "o" | "a" | "lib" | "wasm"
            | "class" | "pyc" => FileCategory::Binary,
            "json" | "yaml" | "yml" | "toml" | "xml" | "csv" | "sqlite" | "db" | "sql"
            | "parquet" | "log" | "plist" | "dat" | "pak" | "cache" => FileCategory::Data,
            _ => FileCategory::Other,
        }
    }

    pub fn color(self) -> Color {
        match self {
            FileCategory::Video => Color::Magenta,
            FileCategory::Audio => Color::LightMagenta,
            FileCategory::Image => Color::Green,
            FileCategory::Archive => Color::Yellow,
            FileCategory::Document => Color::Cyan,
            FileCategory::Code => Color::LightGreen,
            FileCategory::Binary => Color::Red,
            FileCategory::Data => Color::LightYellow,
            FileCategory::Other => Color::Blue,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            FileCategory::Video => "Video",
            FileCategory::Audio => "Audio",
            FileCategory::Image => "Image",
            FileCategory::Archive => "Archive",
            FileCategory::Document => "Document",
            FileCategory::Code => "Code",
            FileCategory::Binary => "Binary",
            FileCategory::Data => "Data",
            FileCategory::Other => "Other",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn categorizes_by_extension() {
        assert_eq!(
            FileCategory::of(&PathBuf::from("a/movie.MOV")),
            FileCategory::Video
        );
        assert_eq!(
            FileCategory::of(&PathBuf::from("x.tar")),
            FileCategory::Archive
        );
        assert_eq!(
            FileCategory::of(&PathBuf::from("no_extension")),
            FileCategory::Other
        );
    }
}
