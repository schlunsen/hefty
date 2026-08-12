use anyhow::Result;
use globset::{Glob, GlobSet, GlobSetBuilder};
use jwalk::WalkDir;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;

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
    /// Aggregated size of every directory under the root (including the root).
    pub dir_sizes: HashMap<PathBuf, u64>,
    /// Number of paths that could not be read (e.g. permission denied).
    pub denied_count: u64,
}

/// Options controlling a scan.
#[derive(Debug, Clone, Default)]
pub struct ScanOptions {
    /// Minimum file size to report as a FileEntry.
    pub min_size: u64,
    /// Report actual disk usage (allocated blocks) instead of apparent size.
    pub disk_usage: bool,
    /// Glob patterns to exclude (matched against any path component).
    pub exclude: Vec<String>,
    /// Do not cross filesystem boundaries.
    pub one_file_system: bool,
}

impl ScanOptions {
    #[allow(dead_code)] // used by the library API and tests
    pub fn with_min_size(min_size: u64) -> Self {
        Self {
            min_size,
            ..Default::default()
        }
    }
}

/// Messages sent from the scanner thread to the UI
#[derive(Debug)]
pub enum ScanMessage {
    /// A file was found that meets the minimum size threshold
    FileFound(FileEntry),
    /// Progress update
    Progress {
        file_count: u64,
        total_bytes: u64,
        denied_count: u64,
    },
    /// Aggregated per-directory sizes (sent once, right before Done)
    DirSizes(HashMap<PathBuf, u64>),
    /// Scan is complete
    Done,
}

fn build_globset(patterns: &[String]) -> Option<GlobSet> {
    if patterns.is_empty() {
        return None;
    }
    let mut builder = GlobSetBuilder::new();
    for p in patterns {
        // Match the pattern itself anywhere in the tree.
        for variant in [p.clone(), format!("**/{}", p), format!("**/{}/**", p)] {
            if let Ok(glob) = Glob::new(&variant) {
                builder.add(glob);
            }
        }
    }
    builder.build().ok()
}

#[cfg(unix)]
fn device_of(path: &Path) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).map(|m| m.dev()).ok()
}

#[cfg(not(unix))]
fn device_of(_path: &Path) -> Option<u64> {
    None
}

/// Size of a file according to the scan options (apparent vs allocated).
#[cfg(unix)]
fn effective_size(md: &std::fs::Metadata, disk_usage: bool) -> u64 {
    use std::os::unix::fs::MetadataExt;
    if disk_usage {
        md.blocks() * 512
    } else {
        md.len()
    }
}

#[cfg(not(unix))]
fn effective_size(md: &std::fs::Metadata, _disk_usage: bool) -> u64 {
    md.len()
}

/// Returns true if this file is a hardlink we've already counted.
#[cfg(unix)]
fn already_seen_hardlink(
    md: &std::fs::Metadata,
    seen: &mut std::collections::HashSet<(u64, u64)>,
) -> bool {
    use std::os::unix::fs::MetadataExt;
    if md.nlink() > 1 {
        !seen.insert((md.dev(), md.ino()))
    } else {
        false
    }
}

#[cfg(not(unix))]
fn already_seen_hardlink(
    _md: &std::fs::Metadata,
    _seen: &mut std::collections::HashSet<(u64, u64)>,
) -> bool {
    false
}

/// Add `size` to every ancestor directory of `path` up to (and including) `root`.
fn add_to_dir_sizes(dir_sizes: &mut HashMap<PathBuf, u64>, root: &Path, path: &Path, size: u64) {
    let mut current = path.parent();
    while let Some(dir) = current {
        *dir_sizes.entry(dir.to_path_buf()).or_insert(0) += size;
        if dir == root {
            break;
        }
        current = dir.parent();
    }
}

/// Start scanning in a background thread, returning a receiver for results.
pub fn scan_directory_async(path: PathBuf, options: ScanOptions) -> mpsc::Receiver<ScanMessage> {
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        let mut total_size: u64 = 0;
        let mut file_count: u64 = 0;
        let mut denied_count: u64 = 0;
        let mut last_progress: u64 = 0;
        let mut dir_sizes: HashMap<PathBuf, u64> = HashMap::new();
        let mut seen_links = std::collections::HashSet::new();

        let globset = build_globset(&options.exclude);
        let root_dev = if options.one_file_system {
            device_of(&path)
        } else {
            None
        };
        let root = path.clone();

        let walker = WalkDir::new(&path)
            .follow_links(false)
            .skip_hidden(false)
            .process_read_dir(move |_depth, _dir_path, _state, children| {
                if let Some(gs) = &globset {
                    children.retain(|entry| match entry {
                        Ok(e) => !gs.is_match(e.path()),
                        Err(_) => true,
                    });
                }
                if let Some(dev) = root_dev {
                    for child in children.iter_mut().flatten() {
                        if child.file_type.is_dir() && device_of(&child.path()) != Some(dev) {
                            child.read_children_path = None;
                        }
                    }
                }
            });

        for entry in walker {
            let entry = match entry {
                Ok(e) => e,
                Err(_) => {
                    denied_count += 1;
                    continue;
                }
            };

            if !entry.file_type().is_file() {
                continue;
            }

            let md = match entry.metadata() {
                Ok(md) => md,
                Err(_) => {
                    denied_count += 1;
                    continue;
                }
            };

            if already_seen_hardlink(&md, &mut seen_links) {
                continue;
            }

            let size = effective_size(&md, options.disk_usage);
            let entry_path = entry.path();
            total_size = total_size.saturating_add(size);
            file_count += 1;
            add_to_dir_sizes(&mut dir_sizes, &root, &entry_path, size);

            if size >= options.min_size {
                let _ = tx.send(ScanMessage::FileFound(FileEntry {
                    path: entry_path,
                    size,
                }));
            }

            // Send progress every 500 files
            if file_count - last_progress >= 500 {
                let _ = tx.send(ScanMessage::Progress {
                    file_count,
                    total_bytes: total_size,
                    denied_count,
                });
                last_progress = file_count;
            }
        }

        // Final progress + directory aggregation
        let _ = tx.send(ScanMessage::Progress {
            file_count,
            total_bytes: total_size,
            denied_count,
        });
        let _ = tx.send(ScanMessage::DirSizes(dir_sizes));
        let _ = tx.send(ScanMessage::Done);
    });

    rx
}

/// Blocking scan for list mode.
pub fn scan_directory(path: &Path, options: ScanOptions) -> Result<ScanResult> {
    let rx = scan_directory_async(path.to_path_buf(), options);

    let mut files = Vec::new();
    let mut total_size: u64 = 0;
    let mut denied_count: u64 = 0;
    let mut dir_sizes = HashMap::new();

    for msg in rx {
        match msg {
            ScanMessage::FileFound(entry) => files.push(entry),
            ScanMessage::Progress {
                total_bytes,
                denied_count: denied,
                ..
            } => {
                total_size = total_bytes;
                denied_count = denied;
            }
            ScanMessage::DirSizes(sizes) => dir_sizes = sizes,
            ScanMessage::Done => break,
        }
    }

    files.sort_by(|a, b| b.size.cmp(&a.size));

    Ok(ScanResult {
        root: path.to_path_buf(),
        files,
        total_size,
        dir_sizes,
        denied_count,
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
        let result = scan_directory(dir.path(), ScanOptions::with_min_size(0)).unwrap();

        assert_eq!(result.files.len(), 4);
        assert_eq!(result.total_size, 5 + 10_000 + 100_000 + 50_000);
    }

    #[test]
    fn scan_respects_min_size() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), ScanOptions::with_min_size(10_000)).unwrap();

        assert_eq!(result.files.len(), 3);
        assert!(result.files.iter().all(|f| f.size >= 10_000));
    }

    #[test]
    fn scan_sorts_largest_first() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), ScanOptions::with_min_size(0)).unwrap();

        for window in result.files.windows(2) {
            assert!(window[0].size >= window[1].size);
        }
    }

    #[test]
    fn scan_empty_directory() {
        let dir = tempfile::tempdir().unwrap();
        let result = scan_directory(dir.path(), ScanOptions::with_min_size(0)).unwrap();

        assert_eq!(result.files.len(), 0);
        assert_eq!(result.total_size, 0);
    }

    #[test]
    fn scan_nonexistent_returns_error_or_empty() {
        let result = scan_directory(
            Path::new("/nonexistent_path_12345"),
            ScanOptions::with_min_size(0),
        );
        assert!(result.is_ok());
        assert_eq!(result.unwrap().files.len(), 0);
    }

    #[test]
    fn scan_high_min_size_filters_everything() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), ScanOptions::with_min_size(1_000_000)).unwrap();

        assert_eq!(result.files.len(), 0);
        assert!(result.total_size > 0);
    }

    #[test]
    fn scan_async_finds_files() {
        let dir = setup_temp_dir();
        let rx = scan_directory_async(dir.path().to_path_buf(), ScanOptions::with_min_size(0));

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

    #[test]
    fn scan_aggregates_dir_sizes() {
        let dir = setup_temp_dir();
        let result = scan_directory(dir.path(), ScanOptions::with_min_size(0)).unwrap();

        let root_size = result
            .dir_sizes
            .get(&dir.path().to_path_buf())
            .copied()
            .unwrap_or(0);
        assert_eq!(root_size, result.total_size);

        let sub_size = result
            .dir_sizes
            .get(&dir.path().join("subdir"))
            .copied()
            .unwrap_or(0);
        assert_eq!(sub_size, 50_000);
    }

    #[test]
    fn scan_excludes_patterns() {
        let dir = setup_temp_dir();
        let mut opts = ScanOptions::with_min_size(0);
        opts.exclude = vec!["subdir".to_string()];
        let result = scan_directory(dir.path(), opts).unwrap();

        assert_eq!(result.files.len(), 3);
        assert!(result
            .files
            .iter()
            .all(|f| !f.path.to_string_lossy().contains("subdir")));
    }

    #[cfg(unix)]
    #[test]
    fn scan_counts_hardlinks_once() {
        let dir = setup_temp_dir();
        fs::hard_link(dir.path().join("large.bin"), dir.path().join("link.bin")).unwrap();

        let result = scan_directory(dir.path(), ScanOptions::with_min_size(0)).unwrap();

        // The hardlinked file should only be counted once
        assert_eq!(result.files.len(), 4);
        assert_eq!(result.total_size, 5 + 10_000 + 100_000 + 50_000);
    }
}
