use anyhow::Result;
use bytesize::ByteSize;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;
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
    let mut file_count: u64 = 0;
    let mut last_update = Instant::now();
    let stderr = std::io::stderr();

    for entry in WalkDir::new(path)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        if entry.file_type().is_file() {
            if let Ok(metadata) = entry.metadata() {
                let size = metadata.len();
                total_size = total_size.saturating_add(size);
                file_count += 1;
                if size >= min_size {
                    files.push(FileEntry {
                        path: entry.into_path(),
                        size,
                    });
                }

                // Update progress every 100ms
                if last_update.elapsed().as_millis() >= 100 {
                    let mut handle = stderr.lock();
                    let _ = write!(
                        handle,
                        "\r\x1b[K  Scanned {} files ({}) — {} large files found...",
                        file_count,
                        ByteSize(total_size),
                        files.len()
                    );
                    let _ = handle.flush();
                    last_update = Instant::now();
                }
            }
        }
    }

    // Clear the progress line
    let _ = write!(std::io::stderr(), "\r\x1b[K");
    let _ = std::io::stderr().flush();

    // Sort largest first
    files.sort_by(|a, b| b.size.cmp(&a.size));

    Ok(ScanResult {
        root: path.to_path_buf(),
        files,
        total_size,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn setup_temp_dir() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();

        // Create files of various sizes
        fs::write(dir.path().join("small.txt"), "hello").unwrap();
        fs::write(dir.path().join("medium.bin"), vec![0u8; 10_000]).unwrap();
        fs::write(dir.path().join("large.bin"), vec![0u8; 100_000]).unwrap();

        // Create a subdirectory with a file
        let sub = dir.path().join("subdir");
        fs::create_dir(&sub).unwrap();
        fs::write(sub.join("nested.bin"), vec![0u8; 50_000]).unwrap();

        dir
    }

    #[test]
    fn scan_finds_all_files() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), 0).unwrap();

        assert_eq!(result.files.len(), 4);
        assert_eq!(result.total_size, 5 + 10_000 + 100_000 + 50_000);
    }

    #[test]
    fn scan_respects_min_size() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), 10_000).unwrap();

        // Should only include medium (10_000), large (100_000), nested (50_000)
        assert_eq!(result.files.len(), 3);
        assert!(result.files.iter().all(|f| f.size >= 10_000));
    }

    #[test]
    fn scan_sorts_largest_first() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), 0).unwrap();

        for window in result.files.windows(2) {
            assert!(window[0].size >= window[1].size);
        }
    }

    #[test]
    fn scan_empty_directory() {
        let dir = tempfile::tempdir().unwrap();
        let result = scan_directory(dir.path(), 0).unwrap();

        assert_eq!(result.files.len(), 0);
        assert_eq!(result.total_size, 0);
    }

    #[test]
    fn scan_nonexistent_returns_error_or_empty() {
        // walkdir handles nonexistent gracefully
        let result = scan_directory(Path::new("/nonexistent_path_12345"), 0);
        // Should either error or return empty
        assert!(result.is_ok());
        assert_eq!(result.unwrap().files.len(), 0);
    }

    #[test]
    fn scan_high_min_size_filters_everything() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), 1_000_000).unwrap();

        assert_eq!(result.files.len(), 0);
        // total_size still counts all files scanned
        assert!(result.total_size > 0);
    }
}
