use anyhow::Result;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

#[derive(Debug, Clone)]
pub struct FileEntry {
    pub path: PathBuf,
    pub size: u64,
}

#[derive(Debug, Clone)]
pub struct ScanResult {
    pub root: PathBuf,
    pub files: Vec<FileEntry>,
    pub total_size: u64,
}

pub fn scan_directory(path: &Path, min_size: u64) -> Result<ScanResult> {
    let mut files = Vec::new();
    let mut total_size: u64 = 0;

    for entry in WalkDir::new(path)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if entry.file_type().is_file() {
            if let Ok(metadata) = entry.metadata() {
                let size = metadata.len();
                total_size = total_size.saturating_add(size);
                if size >= min_size {
                    files.push(FileEntry {
                        path: entry.into_path(),
                        size,
                    });
                }
            }
        }
    }

    // Sort largest first
    files.sort_by(|a, b| b.size.cmp(&a.size));

    Ok(ScanResult {
        root: path.to_path_buf(),
        files,
        total_size,
    })
}
