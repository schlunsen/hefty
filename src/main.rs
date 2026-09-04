mod delete;
mod dupes;
mod filetype;
mod scanner;
mod treemap;
mod ui;

use anyhow::Result;
use bytesize::ByteSize;
use clap::{Parser, ValueEnum};
use scanner::ScanOptions;
use serde::Serialize;
use std::path::PathBuf;
use std::time::Instant;

#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
enum OutputFormat {
    Table,
    Json,
    Csv,
}

#[derive(Parser)]
#[command(
    name = "hefty",
    about = "Find the hefty files hogging your disk space",
    version
)]
struct Cli {
    /// Directory to scan (defaults to current directory)
    #[arg(default_value = ".")]
    path: PathBuf,

    /// Minimum file size to show (e.g. "1MB", "500KB")
    #[arg(short, long, default_value = "1MB")]
    min_size: String,

    /// Show top N largest files only (0 = all)
    #[arg(short = 'n', long, default_value = "100")]
    top: usize,

    /// List mode — print results and exit (no interactive UI)
    #[arg(short, long)]
    list: bool,

    /// Output format for list mode
    #[arg(short = 'f', long, value_enum, default_value = "table")]
    format: OutputFormat,

    /// Report actual disk usage (allocated blocks) instead of apparent size
    #[arg(long)]
    du: bool,

    /// Exclude paths matching a glob pattern (can be repeated, e.g. --exclude node_modules)
    #[arg(short = 'e', long = "exclude")]
    exclude: Vec<String>,

    /// Stay on one filesystem (don't cross mount points)
    #[arg(short = 'x', long)]
    one_file_system: bool,
}

fn parse_size(s: &str) -> Result<u64> {
    let s = s.trim().to_uppercase();

    if let Ok(n) = s.parse::<u64>() {
        return Ok(n);
    }

    let bs: ByteSize = s
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid size: '{}'. Use formats like 1MB, 500KB, 1GB", s))?;
    Ok(bs.0)
}

#[derive(Serialize)]
struct JsonFile<'a> {
    path: &'a str,
    size: u64,
    size_human: String,
}

#[derive(Serialize)]
struct JsonOutput<'a> {
    root: String,
    total_size: u64,
    file_count: usize,
    files: Vec<JsonFile<'a>>,
}

fn csv_escape(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let min_size = parse_size(&cli.min_size)?;

    let path = cli.path.canonicalize().unwrap_or(cli.path.clone());
    if !path.is_dir() {
        anyhow::bail!("'{}' is not a directory", path.display());
    }

    let options = ScanOptions {
        min_size,
        disk_usage: cli.du,
        exclude: cli.exclude.clone(),
        one_file_system: cli.one_file_system,
    };

    if cli.list {
        // Blocking scan + print for list mode
        let quiet = cli.format != OutputFormat::Table;
        if !quiet {
            eprintln!(
                "Scanning {} (min size: {})...",
                path.display(),
                ByteSize(min_size)
            );
        }

        let start = Instant::now();
        let mut scan = scanner::scan_directory(&path, options)?;
        let elapsed = start.elapsed();

        if !quiet {
            eprintln!(
                "Found {} files ({} total) in {:.2}s",
                scan.files.len(),
                ByteSize(scan.total_size),
                elapsed.as_secs_f64()
            );
            if scan.denied_count > 0 {
                eprintln!(
                    "Warning: {} paths could not be read (permission denied)",
                    scan.denied_count
                );
            }
        }

        if cli.top > 0 && scan.files.len() > cli.top {
            scan.files.truncate(cli.top);
        }

        match cli.format {
            OutputFormat::Json => {
                let paths: Vec<String> = scan
                    .files
                    .iter()
                    .map(|f| f.path.display().to_string())
                    .collect();
                let output = JsonOutput {
                    root: scan.root.display().to_string(),
                    total_size: scan.total_size,
                    file_count: scan.files.len(),
                    files: scan
                        .files
                        .iter()
                        .zip(paths.iter())
                        .map(|(f, p)| JsonFile {
                            path: p,
                            size: f.size,
                            size_human: ByteSize(f.size).to_string(),
                        })
                        .collect(),
                };
                println!("{}", serde_json::to_string_pretty(&output)?);
            }
            OutputFormat::Csv => {
                println!("size,size_human,path");
                for file in &scan.files {
                    println!(
                        "{},{},{}",
                        file.size,
                        ByteSize(file.size),
                        csv_escape(&file.path.display().to_string())
                    );
                }
            }
            OutputFormat::Table => {
                if scan.files.is_empty() {
                    eprintln!("No files found above minimum size threshold.");
                    return Ok(());
                }

                println!("\n{:>12}  PATH", "SIZE");
                println!("{}", "─".repeat(80));
                for file in &scan.files {
                    let rel = file.path.strip_prefix(&scan.root).unwrap_or(&file.path);
                    println!("{:>12}  {}", ByteSize(file.size), rel.display());
                }
                println!("{}", "─".repeat(80));
                println!("{:>12}  Total scanned", ByteSize(scan.total_size));
            }
        }
    } else {
        // Launch TUI immediately, scan in background
        let rx = scanner::scan_directory_async(path.clone(), options);
        let mut terminal = ratatui::init();
        let result = ui::App::new_live(path, rx, cli.top).run(&mut terminal);
        ratatui::restore();
        result?;
    }

    Ok(())
}
