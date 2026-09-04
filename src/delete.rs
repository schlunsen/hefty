use std::collections::HashSet;
use std::io;
use std::path::Path;

/// Delete a file, either by moving it to the system Trash (default, recoverable)
/// or permanently removing it.
pub fn remove_file(path: &Path, permanent: bool) -> io::Result<()> {
    if permanent {
        std::fs::remove_file(path)
    } else {
        trash::delete(path).map_err(|e| io::Error::other(e.to_string()))
    }
}

/// After removing files at `removed_indices` (from a Vec), remap a set of marked
/// indices so they keep pointing at the same logical items.
/// `new_len` is the length of the list after removal.
pub fn remap_marks_after_removal(
    marked: &HashSet<usize>,
    removed_indices: &[usize],
    new_len: usize,
) -> HashSet<usize> {
    let mut new_marked = HashSet::new();
    for &idx in marked {
        if removed_indices.contains(&idx) {
            continue;
        }
        let shift = removed_indices.iter().filter(|&&r| r < idx).count();
        let new_idx = idx - shift;
        if new_idx < new_len {
            new_marked.insert(new_idx);
        }
    }
    new_marked
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remap_shifts_marks_down() {
        let marked: HashSet<usize> = [1, 3, 5].into_iter().collect();
        // Remove index 2 from a list of 6 -> new_len 5
        let remapped = remap_marks_after_removal(&marked, &[2], 5);
        assert_eq!(remapped, [1, 2, 4].into_iter().collect());
    }

    #[test]
    fn remap_drops_removed_marks() {
        let marked: HashSet<usize> = [0, 2, 4].into_iter().collect();
        let remapped = remap_marks_after_removal(&marked, &[2, 4], 3);
        assert_eq!(remapped, [0].into_iter().collect());
    }

    #[test]
    fn remap_multiple_removals_before_mark() {
        let marked: HashSet<usize> = [5].into_iter().collect();
        let remapped = remap_marks_after_removal(&marked, &[0, 1, 2], 3);
        assert_eq!(remapped, [2].into_iter().collect());
    }

    #[test]
    fn remap_out_of_bounds_dropped() {
        let marked: HashSet<usize> = [10].into_iter().collect();
        let remapped = remap_marks_after_removal(&marked, &[0], 3);
        assert!(remapped.is_empty());
    }

    #[test]
    fn permanent_delete_removes_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("victim.bin");
        std::fs::write(&path, vec![0u8; 100]).unwrap();

        remove_file(&path, true).unwrap();
        assert!(!path.exists());
    }

    #[test]
    fn permanent_delete_missing_file_errors() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("missing.bin");
        assert!(remove_file(&path, true).is_err());
    }
}
