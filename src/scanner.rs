use anyhow::Result;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;
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

/// Messages sent from the scanner thread to the UI
#[derive(Debug)]
pub enum ScanMessage {
    /// A file was found that meets the minimum size threshold
    FileFound(FileEntry),
    /// Progress update: (total files scanned, total bytes scanned)
    Progress { file_count: u64, total_bytes: u64 },
    /// Scan is complete
    Done,
    /// Scan encountered a fatal error
    #[allow(dead_code)]
    Error(String),
}

/// Start scanning in a background thread, returning a receiver for results.
pub fn scan_directory_async(
    path: PathBuf,
    min_size: u64,
) -> mpsc::Receiver<ScanMessage> {
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        let mut total_size: u64 = 0;
        let mut file_count: u64 = 0;
        let mut last_progress: u64 = 0;

        for entry in WalkDir::new(&path)
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
                        let _ = tx.send(ScanMessage::FileFound(FileEntry {
                            path: entry.into_path(),
                            size,
                        }));
                    }

                    // Send progress every 500 files
                    if file_count - last_progress >= 500 {
                        let _ = tx.send(ScanMessage::Progress {
                            file_count,
                            total_bytes: total_size,
                        });
                        last_progress = file_count;
                    }
                }
            }
        }

        // Final progress
        let _ = tx.send(ScanMessage::Progress {
            file_count,
            total_bytes: total_size,
        });
        let _ = tx.send(ScanMessage::Done);
    });

    rx
}

/// Blocking scan for list mode (keeps the old behavior)
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
        let result = scan_directory(Path::new("/nonexistent_path_12345"), 0);
        assert!(result.is_ok());
        assert_eq!(result.unwrap().files.len(), 0);
    }

    #[test]
    fn scan_high_min_size_filters_everything() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), 1_000_000).unwrap();

        assert_eq!(result.files.len(), 0);
        assert!(result.total_size > 0);
    }

    #[test]
    fn scan_async_finds_files() {
        let dir = setup_temp_dir();
        let rx = scan_directory_async(dir.path().to_path_buf(), 0);

        let mut files = Vec::new();
        let mut done = false;
        for msg in rx {
            match msg {
                ScanMessage::FileFound(f) => files.push(f),
                ScanMessage::Done => {
                    done = true;
                    break;
                }
                _ => {}
            }
        }

        assert!(done);
        assert_eq!(files.len(), 4);
    }
}
