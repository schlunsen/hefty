use hefty::delete::{remap_marks_after_removal, remove_file};
use hefty::scanner::{scan_directory, ScanOptions};
use std::collections::HashSet;
use std::fs;
use std::process::Command;

fn setup_dir() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("a.bin"), vec![0u8; 50_000]).unwrap();
    fs::write(dir.path().join("b.bin"), vec![0u8; 40_000]).unwrap();
    fs::write(dir.path().join("c.bin"), vec![0u8; 30_000]).unwrap();
    fs::write(dir.path().join("d.bin"), vec![0u8; 20_000]).unwrap();
    dir
}

#[test]
fn scan_then_batch_delete_with_remap() {
    let dir = setup_dir();
    let scan = scan_directory(dir.path(), ScanOptions::with_min_size(0)).unwrap();
    let mut files = scan.files;
    assert_eq!(files.len(), 4);

    // Mark indices 1 (b.bin) and 3 (d.bin), plus keep a mark at 2 to verify remap
    let marked: HashSet<usize> = [1, 3].into_iter().collect();
    let mut indices: Vec<usize> = marked.iter().copied().collect();
    indices.sort_unstable_by(|a, b| b.cmp(a));

    let mut removed = Vec::new();
    for idx in &indices {
        let path = files[*idx].path.clone();
        remove_file(&path, true).unwrap();
        removed.push(*idx);
    }
    for idx in &removed {
        files.remove(*idx);
    }

    assert_eq!(files.len(), 2);
    assert!(!dir.path().join("b.bin").exists());
    assert!(!dir.path().join("d.bin").exists());
    assert!(dir.path().join("a.bin").exists());
    assert!(dir.path().join("c.bin").exists());

    // A hypothetical mark on old index 2 (c.bin) should remap to index 1
    let other_marks: HashSet<usize> = [2].into_iter().collect();
    let remapped = remap_marks_after_removal(&other_marks, &removed, files.len());
    assert_eq!(remapped, [1].into_iter().collect());
    assert!(files[1].path.ends_with("c.bin"));
}

#[test]
fn batch_delete_partial_failure_continues() {
    let dir = setup_dir();
    let scan = scan_directory(dir.path(), ScanOptions::with_min_size(0)).unwrap();
    let files = scan.files;

    // Delete index 1, then simulate it already being gone (double delete fails),
    // then keep deleting others — errors must not abort the batch.
    let mut success = 0;
    let mut failures = 0;
    let targets = [1usize, 1, 2];
    for idx in targets {
        match remove_file(&files[idx].path, true) {
            Ok(()) => success += 1,
            Err(_) => failures += 1,
        }
    }
    assert_eq!(success, 2);
    assert_eq!(failures, 1);
}

#[test]
fn cli_json_output() {
    let dir = setup_dir();
    let output = Command::new(env!("CARGO_BIN_EXE_hefty"))
        .args([
            dir.path().to_str().unwrap(),
            "--list",
            "--format",
            "json",
            "--min-size",
            "0",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());

    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(json["file_count"], 4);
    assert_eq!(json["total_size"], 140_000);
    assert_eq!(json["files"][0]["size"], 50_000);
    assert!(json["files"][0]["path"]
        .as_str()
        .unwrap()
        .ends_with("a.bin"));
}

#[test]
fn cli_csv_output() {
    let dir = setup_dir();
    let output = Command::new(env!("CARGO_BIN_EXE_hefty"))
        .args([
            dir.path().to_str().unwrap(),
            "--list",
            "--format",
            "csv",
            "--min-size",
            "0",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());

    let stdout = String::from_utf8(output.stdout).unwrap();
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines[0], "size,size_human,path");
    assert_eq!(lines.len(), 5); // header + 4 files
    assert!(lines[1].starts_with("50000,"));
}

#[test]
fn cli_exclude_flag() {
    let dir = setup_dir();
    let sub = dir.path().join("node_modules");
    fs::create_dir(&sub).unwrap();
    fs::write(sub.join("huge.bin"), vec![0u8; 500_000]).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_hefty"))
        .args([
            dir.path().to_str().unwrap(),
            "--list",
            "--format",
            "json",
            "--min-size",
            "0",
            "--exclude",
            "node_modules",
        ])
        .output()
        .unwrap();
    assert!(output.status.success());

    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(json["file_count"], 4);
    assert_eq!(json["total_size"], 140_000);
}
