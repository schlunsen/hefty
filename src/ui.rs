use crate::delete;
use crate::dupes::{self, DupeGroup, DupeMessage};
use crate::filetype::FileCategory;
use crate::scanner::{ScanMessage, ScanResult};
use crate::treemap;
use anyhow::Result;
use bytesize::ByteSize;
use crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, MouseButton,
    MouseEventKind,
};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph, Wrap},
    DefaultTerminal, Frame,
};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

const SPINNER: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

const DIR_COLOR: Color = Color::LightBlue;

#[derive(Debug, Clone, PartialEq)]
enum Dialog {
    None,
    ConfirmDelete { permanent: bool },
    ConfirmBatchDelete { permanent: bool },
    DeleteResult(String),
    BatchDeleteResult(String),
    FileInfo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ViewMode {
    Files,
    Tree,
    Dupes,
}

/// An entry shown in the directory drill-down view.
#[derive(Debug, Clone)]
struct TreeEntry {
    name: String,
    path: PathBuf,
    size: u64,
    is_dir: bool,
    /// Index into `files` if this entry is a file we know about.
    file_index: Option<usize>,
}

/// A selectable row in the duplicates view.
#[derive(Debug, Clone)]
struct DupeRow {
    group: usize,
    path: PathBuf,
    size: u64,
    first_in_group: bool,
}

pub struct App {
    scan: ScanResult,
    /// Indices into scan.files currently visible in Files mode (search + top-N applied).
    visible: Vec<usize>,
    view: ViewMode,
    selected: usize,
    scroll_offset: usize,
    horizontal_scroll: usize,
    show_treemap: bool,
    dialog: Dialog,
    deleted_bytes: u64,
    deleted_count: usize,
    // Live scan state
    scan_rx: Option<mpsc::Receiver<ScanMessage>>,
    scanning: bool,
    scan_file_count: u64,
    scan_total_bytes: u64,
    denied_count: u64,
    spinner_tick: usize,
    top_n: usize,
    // Multi-select state (file indices into scan.files)
    marked: HashSet<usize>,
    // Search state
    search: String,
    search_input: bool,
    // Tree (drill-down) state
    current_dir: PathBuf,
    tree_entries: Vec<TreeEntry>,
    // Duplicate detection state
    dupe_rx: Option<mpsc::Receiver<DupeMessage>>,
    dupe_groups: Vec<DupeGroup>,
    dupe_rows: Vec<DupeRow>,
    dupe_progress: (usize, usize),
    hashing: bool,
    // Mouse hit areas from the last draw
    list_inner: Rect,
    treemap_hits: Vec<(Rect, usize)>,
    // Redraw tracking
    needs_redraw: bool,
}

impl App {
    pub fn new_live(root: PathBuf, rx: mpsc::Receiver<ScanMessage>, top_n: usize) -> Self {
        Self {
            current_dir: root.clone(),
            scan: ScanResult {
                root,
                files: Vec::new(),
                total_size: 0,
                dir_sizes: HashMap::new(),
                denied_count: 0,
            },
            visible: Vec::new(),
            view: ViewMode::Files,
            selected: 0,
            scroll_offset: 0,
            horizontal_scroll: 0,
            show_treemap: true,
            dialog: Dialog::None,
            deleted_bytes: 0,
            deleted_count: 0,
            scan_rx: Some(rx),
            scanning: true,
            scan_file_count: 0,
            scan_total_bytes: 0,
            denied_count: 0,
            spinner_tick: 0,
            top_n,
            marked: HashSet::new(),
            search: String::new(),
            search_input: false,
            tree_entries: Vec::new(),
            dupe_rx: None,
            dupe_groups: Vec::new(),
            dupe_rows: Vec::new(),
            dupe_progress: (0, 0),
            hashing: false,
            list_inner: Rect::default(),
            treemap_hits: Vec::new(),
            needs_redraw: true,
        }
    }

    #[allow(dead_code)]
    pub fn new(scan: ScanResult) -> Self {
        let mut app = Self::new_live(scan.root.clone(), mpsc::channel().1, 0);
        app.scan = scan;
        app.scan_rx = None;
        app.scanning = false;
        app.rebuild_visible();
        app
    }

    // ── Display list helpers ────────────────────────────────────────────

    /// Number of rows in the current display list.
    fn display_len(&self) -> usize {
        match self.view {
            ViewMode::Files => self.visible.len(),
            ViewMode::Tree => self.tree_entries.len(),
            ViewMode::Dupes => self.dupe_rows.len(),
        }
    }

    /// File index (into scan.files) of the currently selected row, if any.
    fn selected_file_index(&self) -> Option<usize> {
        match self.view {
            ViewMode::Files => self.visible.get(self.selected).copied(),
            ViewMode::Tree => self
                .tree_entries
                .get(self.selected)
                .and_then(|e| e.file_index),
            ViewMode::Dupes => {
                let row = self.dupe_rows.get(self.selected)?;
                self.scan.files.iter().position(|f| f.path == row.path)
            }
        }
    }

    /// Path + size of the selected row (works for dirs and dupe rows too).
    fn selected_path(&self) -> Option<(PathBuf, u64)> {
        match self.view {
            ViewMode::Files => self
                .selected_file_index()
                .map(|i| (self.scan.files[i].path.clone(), self.scan.files[i].size)),
            ViewMode::Tree => self
                .tree_entries
                .get(self.selected)
                .map(|e| (e.path.clone(), e.size)),
            ViewMode::Dupes => self
                .dupe_rows
                .get(self.selected)
                .map(|r| (r.path.clone(), r.size)),
        }
    }

    fn clamp_selection(&mut self) {
        let len = self.display_len();
        if len == 0 {
            self.selected = 0;
        } else if self.selected >= len {
            self.selected = len - 1;
        }
    }

    fn rebuild_visible(&mut self) {
        let q = if self.search.is_empty() {
            None
        } else {
            Some(self.search.to_lowercase())
        };
        self.visible = self
            .scan
            .files
            .iter()
            .enumerate()
            .filter(|(_, f)| match &q {
                Some(q) => f.path.to_string_lossy().to_lowercase().contains(q),
                None => true,
            })
            .map(|(i, _)| i)
            .collect();
        if self.top_n > 0 && self.visible.len() > self.top_n {
            self.visible.truncate(self.top_n);
        }
        self.clamp_selection();
    }

    /// Build entries for the current directory in tree mode.
    fn rebuild_tree(&mut self) {
        let mut dirs: HashMap<PathBuf, u64> = HashMap::new();

        if !self.scan.dir_sizes.is_empty() {
            // Exact sizes from the finished scan
            for (path, size) in &self.scan.dir_sizes {
                if path.parent() == Some(self.current_dir.as_path()) {
                    dirs.insert(path.clone(), *size);
                }
            }
        } else {
            // Approximate from the files we've seen so far
            for f in &self.scan.files {
                if let Ok(rest) = f.path.strip_prefix(&self.current_dir) {
                    let mut comps = rest.components();
                    if let (Some(first), Some(_)) = {
                        let first = comps.next();
                        (first, comps.next())
                    } {
                        let child = self.current_dir.join(first.as_os_str());
                        *dirs.entry(child).or_insert(0) += f.size;
                    }
                }
            }
        }

        let mut entries: Vec<TreeEntry> = dirs
            .into_iter()
            .map(|(path, size)| TreeEntry {
                name: path
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string(),
                path,
                size,
                is_dir: true,
                file_index: None,
            })
            .collect();

        for (i, f) in self.scan.files.iter().enumerate() {
            if f.path.parent() == Some(self.current_dir.as_path()) {
                entries.push(TreeEntry {
                    name: f
                        .path
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .to_string(),
                    path: f.path.clone(),
                    size: f.size,
                    is_dir: false,
                    file_index: Some(i),
                });
            }
        }

        entries.sort_by_key(|e| std::cmp::Reverse(e.size));
        self.tree_entries = entries;
        self.clamp_selection();
    }

    fn rebuild_dupe_rows(&mut self) {
        self.dupe_rows = self
            .dupe_groups
            .iter()
            .enumerate()
            .flat_map(|(gi, g)| {
                g.paths.iter().enumerate().map(move |(pi, p)| DupeRow {
                    group: gi,
                    path: p.clone(),
                    size: g.size,
                    first_in_group: pi == 0,
                })
            })
            .collect();
        self.clamp_selection();
    }

    // ── Scanner / dupe polling ──────────────────────────────────────────

    /// Drain all pending messages from the scanner. Returns true if state changed.
    fn poll_scanner(&mut self) -> bool {
        let mut changed = false;
        if let Some(rx) = &self.scan_rx {
            loop {
                match rx.try_recv() {
                    Ok(ScanMessage::FileFound(entry)) => {
                        changed = true;
                        self.scan.total_size = self.scan.total_size.saturating_add(entry.size);
                        // Insert in sorted position (largest first)
                        let pos = self
                            .scan
                            .files
                            .binary_search_by(|f| entry.size.cmp(&f.size))
                            .unwrap_or_else(|p| p);
                        self.scan.files.insert(pos, entry);
                        // Shift marks that point past the insertion point
                        if !self.marked.is_empty() {
                            self.marked = self
                                .marked
                                .iter()
                                .map(|&i| if i >= pos { i + 1 } else { i })
                                .collect();
                        }
                    }
                    Ok(ScanMessage::Progress {
                        file_count,
                        total_bytes,
                        denied_count,
                    }) => {
                        changed = true;
                        self.scan_file_count = file_count;
                        self.scan_total_bytes = total_bytes;
                        self.denied_count = denied_count;
                    }
                    Ok(ScanMessage::DirSizes(sizes)) => {
                        changed = true;
                        self.scan.dir_sizes = sizes;
                    }
                    Ok(ScanMessage::Done) => {
                        changed = true;
                        self.scanning = false;
                        break;
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        if self.scanning {
                            changed = true;
                        }
                        self.scanning = false;
                        break;
                    }
                }
            }
        }
        if changed {
            self.rebuild_visible();
            if self.view == ViewMode::Tree {
                self.rebuild_tree();
            }
        }
        changed
    }

    fn poll_dupes(&mut self) -> bool {
        let mut changed = false;
        if let Some(rx) = &self.dupe_rx {
            loop {
                match rx.try_recv() {
                    Ok(DupeMessage::Progress { hashed, total }) => {
                        changed = true;
                        self.dupe_progress = (hashed, total);
                    }
                    Ok(DupeMessage::Done(groups)) => {
                        changed = true;
                        self.hashing = false;
                        self.dupe_groups = groups;
                        self.rebuild_dupe_rows();
                        break;
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        self.hashing = false;
                        break;
                    }
                }
            }
        }
        if !self.hashing && changed {
            self.dupe_rx = None;
        }
        changed
    }

    // ── Main loop ───────────────────────────────────────────────────────

    pub fn run(mut self, terminal: &mut DefaultTerminal) -> Result<()> {
        let _ = crossterm::execute!(std::io::stdout(), EnableMouseCapture);
        let result = self.run_inner(terminal);
        let _ = crossterm::execute!(std::io::stdout(), DisableMouseCapture);
        result
    }

    fn run_inner(&mut self, terminal: &mut DefaultTerminal) -> Result<()> {
        let tick_rate = Duration::from_millis(50);
        let mut last_tick = Instant::now();

        loop {
            if self.needs_redraw {
                terminal.draw(|frame| draw(self, frame))?;
                self.needs_redraw = false;
            }

            let timeout = tick_rate.saturating_sub(last_tick.elapsed());
            if event::poll(timeout)? {
                match event::read()? {
                    Event::Key(key) => {
                        if key.kind != KeyEventKind::Press {
                            continue;
                        }
                        self.needs_redraw = true;
                        if self.handle_key(key.code) {
                            return Ok(());
                        }
                    }
                    Event::Mouse(mouse) => {
                        if self.handle_mouse(mouse) {
                            self.needs_redraw = true;
                        }
                    }
                    Event::Resize(_, _) => {
                        self.needs_redraw = true;
                    }
                    _ => {}
                }
            }

            if last_tick.elapsed() >= tick_rate {
                if self.poll_scanner() {
                    self.needs_redraw = true;
                }
                if self.poll_dupes() {
                    self.needs_redraw = true;
                }
                if self.scanning || self.hashing {
                    self.spinner_tick = self.spinner_tick.wrapping_add(1);
                    self.needs_redraw = true;
                }
                last_tick = Instant::now();
            }
        }
    }

    /// Returns true if the app should quit.
    fn handle_key(&mut self, code: KeyCode) -> bool {
        // Search input mode swallows most keys
        if self.search_input {
            match code {
                KeyCode::Esc => {
                    self.search_input = false;
                    self.search.clear();
                    self.rebuild_visible();
                }
                KeyCode::Enter => {
                    self.search_input = false;
                }
                KeyCode::Backspace => {
                    self.search.pop();
                    self.rebuild_visible();
                }
                KeyCode::Char(c) => {
                    self.search.push(c);
                    self.rebuild_visible();
                }
                _ => {}
            }
            return false;
        }

        match &self.dialog {
            Dialog::ConfirmDelete { permanent } => {
                let permanent = *permanent;
                match code {
                    KeyCode::Char('y') | KeyCode::Char('Y') => self.delete_selected(permanent),
                    _ => self.dialog = Dialog::None,
                }
                return false;
            }
            Dialog::ConfirmBatchDelete { permanent } => {
                let permanent = *permanent;
                match code {
                    KeyCode::Char('y') | KeyCode::Char('Y') => self.delete_marked(permanent),
                    _ => self.dialog = Dialog::None,
                }
                return false;
            }
            Dialog::DeleteResult(_) | Dialog::BatchDeleteResult(_) | Dialog::FileInfo => {
                self.dialog = Dialog::None;
                return false;
            }
            Dialog::None => {}
        }

        match code {
            KeyCode::Char('q') => return true,
            KeyCode::Esc => {
                if !self.search.is_empty() {
                    self.search.clear();
                    self.rebuild_visible();
                } else if self.view != ViewMode::Files {
                    self.view = ViewMode::Files;
                    self.rebuild_visible();
                } else {
                    return true;
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.display_len() > 0 {
                    self.selected = (self.selected + 1).min(self.display_len() - 1);
                }
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.selected = self.selected.saturating_sub(1);
            }
            KeyCode::PageDown => {
                if self.display_len() > 0 {
                    self.selected = (self.selected + 20).min(self.display_len() - 1);
                }
            }
            KeyCode::PageUp => {
                self.selected = self.selected.saturating_sub(20);
            }
            KeyCode::Home => self.selected = 0,
            KeyCode::End => {
                if self.display_len() > 0 {
                    self.selected = self.display_len() - 1;
                }
            }
            KeyCode::Tab => self.show_treemap = !self.show_treemap,
            KeyCode::Char('/') => {
                if self.view == ViewMode::Files {
                    self.search_input = true;
                }
            }
            KeyCode::Char('t') => {
                if self.view == ViewMode::Tree {
                    self.view = ViewMode::Files;
                    self.rebuild_visible();
                } else {
                    self.view = ViewMode::Tree;
                    self.current_dir = self.scan.root.clone();
                    self.selected = 0;
                    self.rebuild_tree();
                }
            }
            KeyCode::Char('u') => {
                if self.view == ViewMode::Dupes {
                    self.view = ViewMode::Files;
                    self.rebuild_visible();
                } else {
                    self.view = ViewMode::Dupes;
                    self.selected = 0;
                    if !self.hashing && self.dupe_groups.is_empty() {
                        self.hashing = true;
                        self.dupe_progress = (0, 0);
                        self.dupe_rx = Some(dupes::find_duplicates_async(self.scan.files.clone()));
                    }
                }
            }
            KeyCode::Enter => match self.view {
                ViewMode::Tree => {
                    if let Some(entry) = self.tree_entries.get(self.selected) {
                        if entry.is_dir {
                            self.current_dir = entry.path.clone();
                            self.selected = 0;
                            self.scroll_offset = 0;
                            self.rebuild_tree();
                        } else {
                            self.dialog = Dialog::FileInfo;
                        }
                    }
                }
                _ => {
                    if self.selected_path().is_some() {
                        self.dialog = Dialog::FileInfo;
                    }
                }
            },
            KeyCode::Backspace => {
                if self.view == ViewMode::Tree && self.current_dir != self.scan.root {
                    if let Some(parent) = self.current_dir.parent() {
                        self.current_dir = parent.to_path_buf();
                        self.selected = 0;
                        self.scroll_offset = 0;
                        self.rebuild_tree();
                    }
                }
            }
            KeyCode::Char('o') => {
                if let Some((path, _)) = self.selected_path() {
                    let _ = opener::reveal(&path);
                }
            }
            KeyCode::Char('d') | KeyCode::Delete => self.request_delete(false),
            KeyCode::Char('X') => self.request_delete(true),
            KeyCode::Char(' ') => {
                if self.view == ViewMode::Files {
                    if let Some(idx) = self.selected_file_index() {
                        if self.marked.contains(&idx) {
                            self.marked.remove(&idx);
                        } else {
                            self.marked.insert(idx);
                        }
                        if self.selected + 1 < self.display_len() {
                            self.selected += 1;
                        }
                    }
                }
            }
            KeyCode::Char('a') => {
                if self.view == ViewMode::Files {
                    self.marked = self.visible.iter().copied().collect();
                }
            }
            KeyCode::Char('A') => self.marked.clear(),
            KeyCode::Right | KeyCode::Char('l') => self.horizontal_scroll += 4,
            KeyCode::Left | KeyCode::Char('h') => {
                if self.view == ViewMode::Tree && self.horizontal_scroll == 0 {
                    // In tree mode, Left goes up a directory
                    if self.current_dir != self.scan.root {
                        if let Some(parent) = self.current_dir.parent() {
                            self.current_dir = parent.to_path_buf();
                            self.selected = 0;
                            self.scroll_offset = 0;
                            self.rebuild_tree();
                        }
                    }
                } else {
                    self.horizontal_scroll = self.horizontal_scroll.saturating_sub(4);
                }
            }
            _ => {}
        }
        false
    }

    fn handle_mouse(&mut self, mouse: event::MouseEvent) -> bool {
        if self.dialog != Dialog::None || self.search_input {
            return false;
        }
        match mouse.kind {
            MouseEventKind::ScrollDown => {
                if self.display_len() > 0 {
                    self.selected = (self.selected + 3).min(self.display_len() - 1);
                }
                true
            }
            MouseEventKind::ScrollUp => {
                self.selected = self.selected.saturating_sub(3);
                true
            }
            MouseEventKind::Down(MouseButton::Left) => {
                let (col, row) = (mouse.column, mouse.row);
                // Click in the file list?
                let list = self.list_inner;
                if col >= list.x
                    && col < list.x + list.width
                    && row >= list.y
                    && row < list.y + list.height
                {
                    let clicked = self.scroll_offset + (row - list.y) as usize;
                    if clicked < self.display_len() {
                        self.selected = clicked;
                        return true;
                    }
                }
                // Click in the treemap?
                for (rect, idx) in &self.treemap_hits {
                    if col >= rect.x
                        && col < rect.x + rect.width
                        && row >= rect.y
                        && row < rect.y + rect.height
                    {
                        self.selected = *idx;
                        return true;
                    }
                }
                false
            }
            _ => false,
        }
    }

    // ── Deletion ────────────────────────────────────────────────────────

    fn request_delete(&mut self, permanent: bool) {
        if self.view == ViewMode::Files && !self.marked.is_empty() {
            self.dialog = Dialog::ConfirmBatchDelete { permanent };
        } else if let Some(entry) = match self.view {
            ViewMode::Tree => self.tree_entries.get(self.selected).map(|e| !e.is_dir),
            _ => self.selected_path().map(|_| true),
        } {
            if entry {
                self.dialog = Dialog::ConfirmDelete { permanent };
            }
        }
    }

    /// Remove a file from scan state by its index into scan.files.
    fn remove_file_from_state(&mut self, file_idx: usize) {
        let size = self.scan.files[file_idx].size;
        self.scan.total_size = self.scan.total_size.saturating_sub(size);
        self.scan.files.remove(file_idx);
        self.marked =
            delete::remap_marks_after_removal(&self.marked, &[file_idx], self.scan.files.len());
        self.rebuild_visible();
        if self.view == ViewMode::Tree {
            self.rebuild_tree();
        }
    }

    fn delete_selected(&mut self, permanent: bool) {
        let Some((path, size)) = self.selected_path() else {
            self.dialog = Dialog::None;
            return;
        };

        let verb = if permanent {
            "Deleted"
        } else {
            "Moved to Trash"
        };
        match delete::remove_file(&path, permanent) {
            Ok(()) => {
                self.deleted_bytes += size;
                self.deleted_count += 1;

                if let Some(idx) = self.scan.files.iter().position(|f| f.path == path) {
                    self.remove_file_from_state(idx);
                }
                if self.view == ViewMode::Dupes {
                    if let Some(row) = self.dupe_rows.get(self.selected) {
                        let group = row.group;
                        self.dupe_groups[group].paths.retain(|p| p != &path);
                        if self.dupe_groups[group].paths.len() < 2 {
                            self.dupe_groups.remove(group);
                        }
                        self.rebuild_dupe_rows();
                    }
                }
                self.clamp_selection();

                self.dialog = Dialog::DeleteResult(format!(
                    "{} {} (freed {})",
                    verb,
                    path.file_name().unwrap_or_default().to_string_lossy(),
                    ByteSize(size)
                ));
            }
            Err(e) => {
                self.dialog = Dialog::DeleteResult(format!(
                    "Error deleting {}: {}",
                    path.file_name().unwrap_or_default().to_string_lossy(),
                    e
                ));
            }
        }
    }

    fn delete_marked(&mut self, permanent: bool) {
        if self.marked.is_empty() {
            self.dialog = Dialog::None;
            return;
        }

        let mut indices: Vec<usize> = self.marked.iter().copied().collect();
        indices.sort_unstable_by(|a, b| b.cmp(a));

        let mut success_count = 0usize;
        let mut fail_count = 0usize;
        let mut total_freed: u64 = 0;
        let mut first_error: Option<String> = None;
        let mut removed: Vec<usize> = Vec::new();

        for idx in &indices {
            let Some(file) = self.scan.files.get(*idx) else {
                continue;
            };
            let path = file.path.clone();
            let size = file.size;

            match delete::remove_file(&path, permanent) {
                Ok(()) => {
                    total_freed += size;
                    success_count += 1;
                    removed.push(*idx);
                }
                Err(e) => {
                    fail_count += 1;
                    if first_error.is_none() {
                        first_error = Some(format!(
                            "Error deleting {}: {}",
                            path.file_name().unwrap_or_default().to_string_lossy(),
                            e
                        ));
                    }
                }
            }
        }

        // Remove successfully deleted files (indices sorted descending)
        for idx in &removed {
            self.scan.total_size = self
                .scan
                .total_size
                .saturating_sub(self.scan.files[*idx].size);
            self.scan.files.remove(*idx);
        }

        self.deleted_bytes += total_freed;
        self.deleted_count += success_count;
        self.marked.clear();
        self.rebuild_visible();
        if self.view == ViewMode::Tree {
            self.rebuild_tree();
        }
        self.clamp_selection();

        let verb = if permanent {
            "Deleted"
        } else {
            "Moved to Trash"
        };
        let msg = if fail_count > 0 {
            format!(
                "{} {} files (freed {}), {} failed{}",
                verb,
                success_count,
                ByteSize(total_freed),
                fail_count,
                first_error.map(|e| format!(" — {}", e)).unwrap_or_default()
            )
        } else {
            format!(
                "{} {} files (freed {})",
                verb,
                success_count,
                ByteSize(total_freed)
            )
        };

        self.dialog = Dialog::BatchDeleteResult(msg);
    }

    fn marked_total_size(&self) -> u64 {
        self.marked
            .iter()
            .map(|&i| self.scan.files.get(i).map(|f| f.size).unwrap_or(0))
            .sum()
    }
}

// ── Drawing ─────────────────────────────────────────────────────────────

fn draw(app: &mut App, frame: &mut Frame) {
    let size = frame.area();

    let show_treemap = app.show_treemap && app.view != ViewMode::Dupes;
    if show_treemap {
        let outer = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(5), Constraint::Length(3)])
            .split(size);

        let columns = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
            .split(outer[0]);

        draw_treemap(app, frame, columns[0]);
        draw_list(app, frame, columns[1]);
        draw_status_bar(app, frame, outer[1]);
    } else {
        app.treemap_hits.clear();
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(5), Constraint::Length(3)])
            .split(size);

        draw_list(app, frame, chunks[0]);
        draw_status_bar(app, frame, chunks[1]);
    }

    match &app.dialog {
        Dialog::ConfirmDelete { permanent } => draw_confirm_dialog(app, frame, size, *permanent),
        Dialog::ConfirmBatchDelete { permanent } => {
            draw_batch_confirm_dialog(app, frame, size, *permanent)
        }
        Dialog::DeleteResult(msg) => draw_result_dialog(frame, size, msg.clone()),
        Dialog::BatchDeleteResult(msg) => draw_result_dialog(frame, size, msg.clone()),
        Dialog::FileInfo => draw_file_info_dialog(app, frame, size),
        Dialog::None => {}
    }
}

/// Items for the treemap in the current view: (label, size, color).
fn treemap_items(app: &App) -> Vec<(String, u64, Color)> {
    match app.view {
        ViewMode::Files => app
            .visible
            .iter()
            .map(|&i| {
                let f = &app.scan.files[i];
                let name = f
                    .path
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string();
                (name, f.size, FileCategory::of(&f.path).color())
            })
            .collect(),
        ViewMode::Tree => app
            .tree_entries
            .iter()
            .map(|e| {
                let label = if e.is_dir {
                    format!("{}/", e.name)
                } else {
                    e.name.clone()
                };
                let color = if e.is_dir {
                    DIR_COLOR
                } else {
                    FileCategory::of(&e.path).color()
                };
                (label, e.size, color)
            })
            .collect(),
        ViewMode::Dupes => Vec::new(),
    }
}

fn draw_treemap(app: &mut App, frame: &mut Frame, area: Rect) {
    let title = if app.scanning {
        let spinner = SPINNER[app.spinner_tick % SPINNER.len()];
        format!(" {} Treemap (scanning...) ", spinner)
    } else {
        " Treemap (Tab to toggle) ".to_string()
    };
    let block = Block::default().borders(Borders::ALL).title(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    app.treemap_hits.clear();

    let items = treemap_items(app);
    if items.is_empty() || inner.width == 0 || inner.height == 0 {
        return;
    }

    let max_items = (inner.width as usize * inner.height as usize).min(items.len());
    let sizes: Vec<u64> = items[..max_items].iter().map(|(_, s, _)| *s).collect();

    let rects = treemap::layout(&sizes, inner.width as f64, inner.height as f64);

    // Collect hit areas before mutable buffer borrow
    for rect in &rects {
        let rx = inner.x + rect.x as u16;
        let ry = inner.y + rect.y as u16;
        let rw = (rect.w as u16).max(1);
        let rh = (rect.h as u16).max(1);
        app.treemap_hits
            .push((Rect::new(rx, ry, rw, rh), rect.index));
    }

    let selected = app.selected;
    let marked_display: HashSet<usize> = match app.view {
        ViewMode::Files => app
            .visible
            .iter()
            .enumerate()
            .filter(|(_, &fi)| app.marked.contains(&fi))
            .map(|(di, _)| di)
            .collect(),
        _ => HashSet::new(),
    };

    let buf = frame.buffer_mut();

    for rect in &rects {
        let rx = inner.x + rect.x as u16;
        let ry = inner.y + rect.y as u16;
        let rw = (rect.w as u16).max(1);
        let rh = (rect.h as u16).max(1);

        let (label, _, color) = &items[rect.index];
        let is_selected = rect.index == selected;
        let is_marked = marked_display.contains(&rect.index);

        let style = if is_selected {
            Style::default()
                .bg(Color::White)
                .fg(Color::Black)
                .add_modifier(Modifier::BOLD)
        } else if is_marked {
            Style::default()
                .bg(Color::Magenta)
                .fg(Color::White)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().bg(*color).fg(Color::Black)
        };

        for y in ry..ry.saturating_add(rh).min(inner.y + inner.height) {
            for x in rx..rx.saturating_add(rw).min(inner.x + inner.width) {
                if let Some(cell) = buf.cell_mut((x, y)) {
                    cell.set_style(style);
                    cell.set_char(' ');
                }
            }
        }

        if rw >= 4 && rh >= 1 {
            let short = truncate_label(label, rw as usize - 1);
            for (i, ch) in short.chars().enumerate() {
                let x = rx + i as u16;
                if x < rx.saturating_add(rw).min(inner.x + inner.width) {
                    if let Some(cell) = buf.cell_mut((x, ry)) {
                        cell.set_char(ch);
                        cell.set_style(style);
                    }
                }
            }
        }
    }
}

fn draw_list(app: &mut App, frame: &mut Frame, area: Rect) {
    let title = match app.view {
        ViewMode::Files => {
            let filter = if app.search.is_empty() && !app.search_input {
                String::new()
            } else {
                format!(" [/{}]", app.search)
            };
            if app.scanning {
                let spinner = SPINNER[app.spinner_tick % SPINNER.len()];
                format!(
                    " {} Files ({} found, scanning {} files...){} ",
                    spinner,
                    app.visible.len(),
                    app.scan_file_count,
                    filter
                )
            } else {
                format!(" Files ({}){} ", app.visible.len(), filter)
            }
        }
        ViewMode::Tree => {
            let rel = app
                .current_dir
                .strip_prefix(&app.scan.root)
                .map(|p| p.display().to_string())
                .unwrap_or_default();
            format!(
                " Tree: /{} ({} items) — Enter descend, Backspace up ",
                rel,
                app.tree_entries.len()
            )
        }
        ViewMode::Dupes => {
            if app.hashing {
                let spinner = SPINNER[app.spinner_tick % SPINNER.len()];
                let (hashed, total) = app.dupe_progress;
                format!(" {} Duplicates (hashing {}/{}...) ", spinner, hashed, total)
            } else {
                let wasted: u64 = app.dupe_groups.iter().map(|g| g.wasted()).sum();
                format!(
                    " Duplicates ({} groups, {} reclaimable) ",
                    app.dupe_groups.len(),
                    ByteSize(wasted)
                )
            }
        }
    };
    let block = Block::default().borders(Borders::ALL).title(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    app.list_inner = inner;

    let visible_rows = inner.height as usize;
    if visible_rows == 0 {
        return;
    }

    if app.selected < app.scroll_offset {
        app.scroll_offset = app.selected;
    }
    if app.selected >= app.scroll_offset + visible_rows {
        app.scroll_offset = app.selected - visible_rows + 1;
    }

    let mut lines: Vec<Line> = Vec::new();
    for di in app.scroll_offset..(app.scroll_offset + visible_rows).min(app.display_len()) {
        let (marker, text, base_style) = row_content(app, di);
        let style = if di == app.selected {
            base_style
                .bg(Color::White)
                .fg(if app.marked_row(di) {
                    Color::Magenta
                } else {
                    Color::Black
                })
                .add_modifier(Modifier::BOLD)
        } else {
            base_style
        };

        let full_line = format!("{} {}", marker, text);
        let display_str: String = full_line.chars().skip(app.horizontal_scroll).collect();
        lines.push(Line::from(Span::styled(display_str, style)));
    }

    let paragraph = Paragraph::new(lines);
    frame.render_widget(paragraph, inner);
}

impl App {
    fn marked_row(&self, di: usize) -> bool {
        match self.view {
            ViewMode::Files => self
                .visible
                .get(di)
                .map(|fi| self.marked.contains(fi))
                .unwrap_or(false),
            _ => false,
        }
    }
}

/// Content of a display row: (marker, text, style)
fn row_content(app: &App, di: usize) -> (&'static str, String, Style) {
    match app.view {
        ViewMode::Files => {
            let fi = app.visible[di];
            let file = &app.scan.files[fi];
            let size_str = format!("{:>10}", ByteSize(file.size));
            let name = file.path.file_name().unwrap_or_default().to_string_lossy();
            let parent_hint = file
                .path
                .parent()
                .and_then(|p| p.file_name())
                .map(|p| format!("{}/", p.to_string_lossy()))
                .unwrap_or_default();
            let is_marked = app.marked.contains(&fi);
            let marker = if is_marked { "◆" } else { " " };
            let style = if is_marked {
                Style::default()
                    .fg(Color::Magenta)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(FileCategory::of(&file.path).color())
            };
            (
                marker,
                format!("{} {}{}", size_str, parent_hint, name),
                style,
            )
        }
        ViewMode::Tree => {
            let entry = &app.tree_entries[di];
            let size_str = format!("{:>10}", ByteSize(entry.size));
            if entry.is_dir {
                (
                    " ",
                    format!("{} ▸ {}/", size_str, entry.name),
                    Style::default().fg(DIR_COLOR).add_modifier(Modifier::BOLD),
                )
            } else {
                (
                    " ",
                    format!("{}   {}", size_str, entry.name),
                    Style::default().fg(FileCategory::of(&entry.path).color()),
                )
            }
        }
        ViewMode::Dupes => {
            let row = &app.dupe_rows[di];
            let size_str = format!("{:>10}", ByteSize(row.size));
            let rel = row
                .path
                .strip_prefix(&app.scan.root)
                .unwrap_or(&row.path)
                .display();
            let marker = if row.first_in_group { "═" } else { " " };
            let color = if row.group.is_multiple_of(2) {
                Color::Cyan
            } else {
                Color::Yellow
            };
            (
                marker,
                format!("{}  {}", size_str, rel),
                Style::default().fg(color),
            )
        }
    }
}

fn draw_status_bar(app: &App, frame: &mut Frame, area: Rect) {
    let scan_info = if app.scanning {
        let spinner = SPINNER[app.spinner_tick % SPINNER.len()];
        format!(
            " {} Scanning: {} files ({}) ",
            spinner,
            app.scan_file_count,
            ByteSize(app.scan_total_bytes)
        )
    } else {
        format!(
            " Total: {} │ Files: {} ",
            ByteSize(app.scan_total_bytes.max(app.scan.total_size)),
            app.scan.files.len()
        )
    };

    let denied_info = if app.denied_count > 0 {
        format!("│ ⚠ {} unreadable ", app.denied_count)
    } else {
        String::new()
    };

    let selected_info = match app.selected_path() {
        Some((path, size)) => format!(
            "│ Selected: {} ({}) ",
            path.file_name().unwrap_or_default().to_string_lossy(),
            ByteSize(size)
        ),
        None => String::new(),
    };

    let marked_info = if !app.marked.is_empty() {
        format!(
            "│ Marked: {} ({}) ",
            app.marked.len(),
            ByteSize(app.marked_total_size())
        )
    } else {
        String::new()
    };

    let freed_info = if app.deleted_count > 0 {
        format!(
            "│ Freed: {} ({} files) ",
            ByteSize(app.deleted_bytes),
            app.deleted_count
        )
    } else {
        String::new()
    };

    let keys = match app.view {
        ViewMode::Files => {
            "│ Space mark  d trash  X del  / find  t tree  u dupes  o reveal  q quit"
        }
        ViewMode::Tree => "│ Enter open  Backspace up  d trash  o reveal  t back  q quit",
        ViewMode::Dupes => "│ d trash  o reveal  u back  q quit",
    };

    let status = format!(
        "{}{}{}{}{}{}",
        scan_info, denied_info, selected_info, marked_info, freed_info, keys
    );

    let block = Block::default().borders(Borders::ALL);
    let paragraph = Paragraph::new(status)
        .style(Style::default().fg(Color::White))
        .block(block);
    frame.render_widget(paragraph, area);
}

fn draw_confirm_dialog(app: &App, frame: &mut Frame, area: Rect, permanent: bool) {
    let Some((path, size)) = app.selected_path() else {
        return;
    };
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    let rel_path = path
        .strip_prefix(&app.scan.root)
        .unwrap_or(&path)
        .display()
        .to_string();

    let (action, hint) = if permanent {
        ("Permanently delete", "This cannot be undone!")
    } else {
        ("Move to Trash", "File can be restored from the Trash")
    };

    let dialog_width = 60.min(area.width.saturating_sub(4));
    let dialog_height = 9_u16;
    let x = (area.width.saturating_sub(dialog_width)) / 2;
    let y = (area.height.saturating_sub(dialog_height)) / 2;
    let dialog_area = Rect::new(x, y, dialog_width, dialog_height);

    frame.render_widget(Clear, dialog_area);

    let text = vec![
        Line::from(""),
        Line::from(vec![
            Span::raw(format!("  {} ", action)),
            Span::styled(
                &name,
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(" ({})", ByteSize(size)),
                Style::default().fg(Color::Yellow),
            ),
            Span::raw(" ?"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            format!("  {}", rel_path),
            Style::default().fg(Color::DarkGray),
        )),
        Line::from(Span::styled(
            format!("  {}", hint),
            Style::default().fg(if permanent {
                Color::Red
            } else {
                Color::DarkGray
            }),
        )),
        Line::from(""),
        Line::from(vec![
            Span::raw("  Press "),
            Span::styled(
                "y",
                Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            ),
            Span::raw(" to confirm, any other key to cancel"),
        ]),
    ];

    let title = if permanent {
        " Delete File "
    } else {
        " Move to Trash "
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Red))
        .title(title);
    let paragraph = Paragraph::new(text).block(block).wrap(Wrap { trim: false });
    frame.render_widget(paragraph, dialog_area);
}

fn draw_batch_confirm_dialog(app: &App, frame: &mut Frame, area: Rect, permanent: bool) {
    if app.marked.is_empty() {
        return;
    }

    let count = app.marked.len();
    let total_size = app.marked_total_size();

    let (action, hint) = if permanent {
        (
            "Permanently delete".to_string(),
            format!("This will permanently remove {} files!", count),
        )
    } else {
        (
            "Move to Trash".to_string(),
            format!("{} files can be restored from the Trash", count),
        )
    };

    let dialog_width = 60.min(area.width.saturating_sub(4));
    let dialog_height = 8_u16;
    let x = (area.width.saturating_sub(dialog_width)) / 2;
    let y = (area.height.saturating_sub(dialog_height)) / 2;
    let dialog_area = Rect::new(x, y, dialog_width, dialog_height);

    frame.render_widget(Clear, dialog_area);

    let text = vec![
        Line::from(""),
        Line::from(vec![
            Span::raw(format!("  {} ", action)),
            Span::styled(
                format!("{} files", count),
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                format!(" ({})", ByteSize(total_size)),
                Style::default().fg(Color::Yellow),
            ),
            Span::raw(" ?"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            format!("  {}", hint),
            Style::default().fg(if permanent {
                Color::Red
            } else {
                Color::DarkGray
            }),
        )),
        Line::from(""),
        Line::from(vec![
            Span::raw("  Press "),
            Span::styled(
                "y",
                Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
            ),
            Span::raw(" to confirm, any other key to cancel"),
        ]),
    ];

    let title = if permanent {
        " Batch Delete "
    } else {
        " Batch Move to Trash "
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Red))
        .title(title);
    let paragraph = Paragraph::new(text).block(block).wrap(Wrap { trim: false });
    frame.render_widget(paragraph, dialog_area);
}

fn draw_result_dialog(frame: &mut Frame, area: Rect, msg: String) {
    let dialog_width = 60.min(area.width.saturating_sub(4));
    let dialog_height = 5_u16;
    let x = (area.width.saturating_sub(dialog_width)) / 2;
    let y = (area.height.saturating_sub(dialog_height)) / 2;
    let dialog_area = Rect::new(x, y, dialog_width, dialog_height);

    frame.render_widget(Clear, dialog_area);

    let is_error = msg.starts_with("Error");
    let color = if is_error { Color::Red } else { Color::Green };

    let text = vec![
        Line::from(""),
        Line::from(Span::styled(
            format!("  {}", msg),
            Style::default().fg(color).add_modifier(Modifier::BOLD),
        )),
        Line::from(Span::styled(
            "  Press any key to continue",
            Style::default().fg(Color::DarkGray),
        )),
    ];

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(color))
        .title(if is_error { " Error " } else { " Done " });
    let paragraph = Paragraph::new(text).block(block).wrap(Wrap { trim: false });
    frame.render_widget(paragraph, dialog_area);
}

fn draw_file_info_dialog(app: &App, frame: &mut Frame, area: Rect) {
    let Some((path, size)) = app.selected_path() else {
        return;
    };

    let full_path = path.display().to_string();
    let rel_path = path
        .strip_prefix(&app.scan.root)
        .unwrap_or(&path)
        .display()
        .to_string();
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    let size_str = format!("{}", ByteSize(size));
    let category = FileCategory::of(&path).label();

    let dialog_width = (full_path.len() as u16 + 6)
        .max(50)
        .min(area.width.saturating_sub(4));
    let dialog_height = 10_u16;
    let x = (area.width.saturating_sub(dialog_width)) / 2;
    let y = (area.height.saturating_sub(dialog_height)) / 2;
    let dialog_area = Rect::new(x, y, dialog_width, dialog_height);

    frame.render_widget(Clear, dialog_area);

    let text = vec![
        Line::from(""),
        Line::from(vec![
            Span::styled("  Name: ", Style::default().fg(Color::DarkGray)),
            Span::styled(
                &name,
                Style::default()
                    .fg(Color::White)
                    .add_modifier(Modifier::BOLD),
            ),
        ]),
        Line::from(vec![
            Span::styled("  Size: ", Style::default().fg(Color::DarkGray)),
            Span::styled(&size_str, Style::default().fg(Color::Yellow)),
        ]),
        Line::from(vec![
            Span::styled("  Type: ", Style::default().fg(Color::DarkGray)),
            Span::styled(category, Style::default().fg(Color::Green)),
        ]),
        Line::from(vec![
            Span::styled("  Path: ", Style::default().fg(Color::DarkGray)),
            Span::styled(&rel_path, Style::default().fg(Color::Cyan)),
        ]),
        Line::from(vec![
            Span::styled("  Full: ", Style::default().fg(Color::DarkGray)),
            Span::styled(&full_path, Style::default().fg(Color::White)),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "  Press any key to close (o reveals in file manager)",
            Style::default().fg(Color::DarkGray),
        )),
    ];

    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(Color::Cyan))
        .title(" File Info ");
    let paragraph = Paragraph::new(text).block(block).wrap(Wrap { trim: false });
    frame.render_widget(paragraph, dialog_area);
}

fn truncate_label(name: &str, max_len: usize) -> String {
    let chars: Vec<char> = name.chars().collect();
    if chars.len() <= max_len {
        name.to_string()
    } else if max_len > 3 {
        format!("{}...", chars[..max_len - 3].iter().collect::<String>())
    } else {
        chars[..max_len].iter().collect()
    }
}
