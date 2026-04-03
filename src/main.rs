mod scanner;
mod treemap;
mod ui;

use anyhow::Result;
use bytesize::ByteSize;
use clap::Parser;
use std::path::PathBuf;
use std::time::Instant;

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
}

fn parse_size(s: &str) -> Result<u64> {
    let s = s.trim().to_uppercase();

    // Handle plain numbers as bytes
    if let Ok(n) = s.parse::<u64>() {
        return Ok(n);
    }

    // Parse things like "1MB", "500KB", "1.5GB"
    let bs: ByteSize = s
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid size: '{}'. Use formats like 1MB, 500KB, 1GB", s))?;
    Ok(bs.0)
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let min_size = parse_size(&cli.min_size)?;

    let path = cli.path.canonicalize().unwrap_or(cli.path.clone());
    if !path.is_dir() {
        anyhow::bail!("'{}' is not a directory", path.display());
    }

    eprintln!(
        "Scanning {} (min size: {})...",
        path.display(),
        ByteSize(min_size)
    );

    let start = Instant::now();
    let mut scan = scanner::scan_directory(&path, min_size)?;
    let elapsed = start.elapsed();

    eprintln!(
        "Found {} files ({} total) in {:.2}s",
        scan.files.len(),
        ByteSize(scan.total_size),
        elapsed.as_secs_f64()
    );

    // Apply top-N limit
    if cli.top > 0 && scan.files.len() > cli.top {
        scan.files.truncate(cli.top);
    }

    if scan.files.is_empty() {
        eprintln!("No files found above minimum size threshold.");
        return Ok(());
    }

    if cli.list {
        // Non-interactive list mode
        println!("\n{:>12}  {}", "SIZE", "PATH");
        println!("{}", "─".repeat(80));
        for file in &scan.files {
            let rel = file.path.strip_prefix(&scan.root).unwrap_or(&file.path);
            println!("{:>12}  {}", ByteSize(file.size), rel.display());
        }
        println!("{}", "─".repeat(80));
        println!("{:>12}  Total scanned", ByteSize(scan.total_size));
    } else {
        // Interactive TUI mode
        let mut terminal = ratatui::init();
        let result = ui::App::new(scan).run(&mut terminal);
        ratatui::restore();
        result?;
    }

    Ok(())
}
