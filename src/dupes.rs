use crate::scanner::FileEntry;
use std::collections::HashMap;
use std::io::Read;
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;

/// A group of files with identical size + content hash.
#[derive(Debug, Clone)]
pub struct DupeGroup {
    pub size: u64,
    pub paths: Vec<PathBuf>,
}

impl DupeGroup {
    /// Bytes that could be reclaimed by keeping one copy.
    pub fn wasted(&self) -> u64 {
        self.size * (self.paths.len() as u64 - 1)
    }
}

#[derive(Debug)]
pub enum DupeMessage {
    Progress { hashed: usize, total: usize },
    Done(Vec<DupeGroup>),
}

fn hash_file(path: &PathBuf) -> Option<blake3::Hash> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = [0u8; 65536];
    loop {
        let n = file.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Some(hasher.finalize())
}

/// Find duplicate files among the given entries in a background thread.
/// Only files sharing a size with another file are hashed.
pub fn find_duplicates_async(files: Vec<FileEntry>) -> mpsc::Receiver<DupeMessage> {
    let (tx, rx) = mpsc::channel();

    thread::spawn(move || {
        // Group by size; only size-colliding files are candidates.
        let mut by_size: HashMap<u64, Vec<PathBuf>> = HashMap::new();
        for f in files {
            by_size.entry(f.size).or_default().push(f.path);
        }
        by_size.retain(|_, v| v.len() > 1);

        let total: usize = by_size.values().map(|v| v.len()).sum();
        let mut hashed = 0usize;
        let mut groups: Vec<DupeGroup> = Vec::new();

        for (size, paths) in by_size {
            let mut by_hash: HashMap<blake3::Hash, Vec<PathBuf>> = HashMap::new();
            for path in paths {
                if let Some(hash) = hash_file(&path) {
                    by_hash.entry(hash).or_default().push(path);
                }
                hashed += 1;
                if hashed.is_multiple_of(10) {
                    let _ = tx.send(DupeMessage::Progress { hashed, total });
                }
            }
            for (_, dupe_paths) in by_hash {
                if dupe_paths.len() > 1 {
                    groups.push(DupeGroup {
                        size,
                        paths: dupe_paths,
                    });
                }
            }
        }

        // Largest waste first
        groups.sort_by_key(|g| std::cmp::Reverse(g.wasted()));
        let _ = tx.send(DupeMessage::Done(groups));
    });

    rx
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn finds_identical_files() {
        let dir = tempfile::tempdir().unwrap();
        let content = vec![7u8; 10_000];
        fs::write(dir.path().join("a.bin"), &content).unwrap();
        fs::write(dir.path().join("b.bin"), &content).unwrap();
        fs::write(dir.path().join("c.bin"), vec![9u8; 10_000]).unwrap(); // same size, diff content
        fs::write(dir.path().join("d.bin"), vec![1u8; 5_000]).unwrap(); // unique size

        let files: Vec<FileEntry> = ["a.bin", "b.bin", "c.bin", "d.bin"]
            .iter()
            .map(|n| {
                let path = dir.path().join(n);
                let size = fs::metadata(&path).unwrap().len();
                FileEntry { path, size }
            })
            .collect();

        let rx = find_duplicates_async(files);
        let mut result = None;
        for msg in rx {
            if let DupeMessage::Done(groups) = msg {
                result = Some(groups);
                break;
            }
        }

        let groups = result.unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].paths.len(), 2);
        assert_eq!(groups[0].size, 10_000);
        assert_eq!(groups[0].wasted(), 10_000);
    }

    #[test]
    fn no_dupes_returns_empty() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("a.bin"), vec![1u8; 100]).unwrap();
        fs::write(dir.path().join("b.bin"), vec![2u8; 200]).unwrap();

        let files: Vec<FileEntry> = ["a.bin", "b.bin"]
            .iter()
            .map(|n| {
                let path = dir.path().join(n);
                let size = fs::metadata(&path).unwrap().len();
                FileEntry { path, size }
            })
            .collect();

        let rx = find_duplicates_async(files);
        let mut result = None;
        for msg in rx {
            if let DupeMessage::Done(groups) = msg {
                result = Some(groups);
                break;
            }
        }
        assert!(result.unwrap().is_empty());
    }
}
