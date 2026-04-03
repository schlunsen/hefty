use crate::scanner::{FileEntry, ScanMessage, ScanResult};
use crate::treemap;
use anyhow::Result;
use bytesize::ByteSize;
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph, Wrap},
    DefaultTerminal, Frame,
};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const COLORS: &[Color] = &[
    Color::Blue,
    Color::Green,
    Color::Yellow,
    Color::Cyan,
    Color::Magenta,
    Color::Red,
    Color::LightBlue,
    Color::LightGreen,
    Color::LightYellow,
    Color::LightCyan,
    Color::LightMagenta,
    Color::LightRed,
];

const SPINNER: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

#[derive(Debug, Clone, PartialEq)]
enum Dialog {
    None,
    ConfirmDelete,
    DeleteResult(String),
}

pub struct App {
    scan: ScanResult,
    selected: usize,
    scroll_offset: usize,
    show_treemap: bool,
    dialog: Dialog,
    deleted_bytes: u64,
    deleted_count: usize,
    // Live scan state
    scan_rx: Option<mpsc::Receiver<ScanMessage>>,
    scanning: bool,
    scan_file_count: u64,
    scan_total_bytes: u64,
    spinner_tick: usize,
    top_n: usize,
}

impl App {
    pub fn new_live(
        root: std::path::PathBuf,
        rx: mpsc::Receiver<ScanMessage>,
        top_n: usize,
    ) -> Self {
        Self {
            scan: ScanResult {
                root,
                files: Vec::new(),
                total_size: 0,
            },
            selected: 0,
            scroll_offset: 0,
            show_treemap: true,
            dialog: Dialog::None,
            deleted_bytes: 0,
            deleted_count: 0,
            scan_rx: Some(rx),
            scanning: true,
            scan_file_count: 0,
            scan_total_bytes: 0,
            spinner_tick: 0,
            top_n,
        }
    }

    #[allow(dead_code)]
    pub fn new(scan: ScanResult) -> Self {
        Self {
            scan,
            selected: 0,
            scroll_offset: 0,
            show_treemap: true,
            dialog: Dialog::None,
            deleted_bytes: 0,
            deleted_count: 0,
            scan_rx: None,
            scanning: false,
            scan_file_count: 0,
            scan_total_bytes: 0,
            spinner_tick: 0,
            top_n: 0,
        }
    }

    /// Drain all pending messages from the scanner
    fn poll_scanner(&mut self) {
        if let Some(rx) = &self.scan_rx {
            loop {
                match rx.try_recv() {
                    Ok(ScanMessage::FileFound(entry)) => {
                        self.scan.total_size = self.scan.total_size.saturating_add(entry.size);
                        // Insert in sorted position (largest first)
                        let pos = self
                            .scan
                            .files
                            .binary_search_by(|f| entry.size.cmp(&f.size))
                            .unwrap_or_else(|p| p);
                        self.scan.files.insert(pos, entry);
                        // Enforce top-N limit
                        if self.top_n > 0 && self.scan.files.len() > self.top_n {
                            self.scan.files.truncate(self.top_n);
                        }
                    }
                    Ok(ScanMessage::Progress {
                        file_count,
                        total_bytes,
                    }) => {
                        self.scan_file_count = file_count;
                        self.scan_total_bytes = total_bytes;
                    }
                    Ok(ScanMessage::Done) => {
                        self.scanning = false;
                        break;
                    }
                    Ok(ScanMessage::Error(_)) => {
                        self.scanning = false;
                        break;
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => {
                        self.scanning = false;
                        break;
                    }
                }
            }
        }
    }

    pub fn run(mut self, terminal: &mut DefaultTerminal) -> Result<()> {
        let tick_rate = Duration::from_millis(50);
        let mut last_tick = Instant::now();

        loop {
            terminal.draw(|frame| self.draw(frame))?;

            let timeout = tick_rate.saturating_sub(last_tick.elapsed());
            if event::poll(timeout)? {
                if let Event::Key(key) = event::read()? {
                    if key.kind != KeyEventKind::Press {
                        continue;
                    }

                    match &self.dialog {
                        Dialog::ConfirmDelete => match key.code {
                            KeyCode::Char('y') | KeyCode::Char('Y') => {
                                self.delete_selected();
                            }
                            _ => {
                                self.dialog = Dialog::None;
                            }
                        },
                        Dialog::DeleteResult(_) => {
                            self.dialog = Dialog::None;
                        }
                        Dialog::None => match key.code {
                            KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                            KeyCode::Down | KeyCode::Char('j') => {
                                if !self.scan.files.is_empty() {
                                    self.selected =
                                        (self.selected + 1).min(self.scan.files.len() - 1);
                                }
                            }
                            KeyCode::Up | KeyCode::Char('k') => {
                                self.selected = self.selected.saturating_sub(1);
                            }
                            KeyCode::PageDown => {
                                if !self.scan.files.is_empty() {
                                    self.selected =
                                        (self.selected + 20).min(self.scan.files.len() - 1);
                                }
                            }
                            KeyCode::PageUp => {
                                self.selected = self.selected.saturating_sub(20);
                            }
                            KeyCode::Home => {
                                self.selected = 0;
                            }
                            KeyCode::End => {
                                if !self.scan.files.is_empty() {
                                    self.selected = self.scan.files.len() - 1;
                                }
                            }
                            KeyCode::Tab => {
                                self.show_treemap = !self.show_treemap;
                            }
                            KeyCode::Char('d') | KeyCode::Delete => {
                                if !self.scan.files.is_empty() {
                                    self.dialog = Dialog::ConfirmDelete;
                                }
                            }
                            _ => {}
                        },
                    }
                }
            }

            if last_tick.elapsed() >= tick_rate {
                self.poll_scanner();
                self.spinner_tick = self.spinner_tick.wrapping_add(1);
                last_tick = Instant::now();
            }
        }
    }

    fn delete_selected(&mut self) {
        if self.scan.files.is_empty() {
            return;
        }

        let file = &self.scan.files[self.selected];
        let path = file.path.clone();
        let size = file.size;

        match std::fs::remove_file(&path) {
            Ok(()) => {
                self.deleted_bytes += size;
                self.deleted_count += 1;
                self.scan.total_size = self.scan.total_size.saturating_sub(size);
                self.scan.files.remove(self.selected);

                if !self.scan.files.is_empty() && self.selected >= self.scan.files.len() {
                    self.selected = self.scan.files.len() - 1;
                }

                self.dialog = Dialog::DeleteResult(format!(
                    "Deleted {} (freed {})",
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

    fn draw(&mut self, frame: &mut Frame) {
        let size = frame.area();

        if self.show_treemap {
            let outer = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Min(5), Constraint::Length(3)])
                .split(size);

            let columns = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
                .split(outer[0]);

            self.draw_treemap(frame, columns[0]);
            self.draw_file_list(frame, columns[1]);
            self.draw_status_bar(frame, outer[1]);
        } else {
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Min(5), Constraint::Length(3)])
                .split(size);

            self.draw_file_list(frame, chunks[0]);
            self.draw_status_bar(frame, chunks[1]);
        }

        // Draw dialog on top
        match &self.dialog {
            Dialog::ConfirmDelete => self.draw_confirm_dialog(frame, size),
            Dialog::DeleteResult(msg) => self.draw_result_dialog(frame, size, msg.clone()),
            Dialog::None => {}
        }
    }

    fn draw_confirm_dialog(&self, frame: &mut Frame, area: Rect) {
        if self.scan.files.is_empty() {
            return;
        }

        let file = &self.scan.files[self.selected];
        let name = file
            .path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let rel_path = file
            .path
            .strip_prefix(&self.scan.root)
            .unwrap_or(&file.path)
            .display()
            .to_string();

        let dialog_width = 60.min(area.width.saturating_sub(4));
        let dialog_height = 8_u16;
        let x = (area.width.saturating_sub(dialog_width)) / 2;
        let y = (area.height.saturating_sub(dialog_height)) / 2;
        let dialog_area = Rect::new(x, y, dialog_width, dialog_height);

        frame.render_widget(Clear, dialog_area);

        let text = vec![
            Line::from(""),
            Line::from(vec![
                Span::raw("  Delete "),
                Span::styled(
                    &name,
                    Style::default()
                        .fg(Color::White)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(" ({})", ByteSize(file.size)),
                    Style::default().fg(Color::Yellow),
                ),
                Span::raw(" ?"),
            ]),
            Line::from(""),
            Line::from(Span::styled(
                format!("  {}", rel_path),
                Style::default().fg(Color::DarkGray),
            )),
            Line::from(""),
            Line::from(vec![
                Span::raw("  Press "),
                Span::styled(
                    "y",
                    Style::default()
                        .fg(Color::Red)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::raw(" to confirm, any other key to cancel"),
            ]),
        ];

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(Color::Red))
            .title(" Delete File ");
        let paragraph = Paragraph::new(text)
            .block(block)
            .wrap(Wrap { trim: false });
        frame.render_widget(paragraph, dialog_area);
    }

    fn draw_result_dialog(&self, frame: &mut Frame, area: Rect, msg: String) {
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
            .title(if is_error { " Error " } else { " Deleted " });
        let paragraph = Paragraph::new(text)
            .block(block)
            .wrap(Wrap { trim: false });
        frame.render_widget(paragraph, dialog_area);
    }

    fn draw_treemap(&self, frame: &mut Frame, area: Rect) {
        let title = if self.scanning {
            let spinner = SPINNER[self.spinner_tick % SPINNER.len()];
            format!(" {} Treemap (scanning...) ", spinner)
        } else {
            " Treemap (Tab to toggle) ".to_string()
        };
        let block = Block::default().borders(Borders::ALL).title(title);
        let inner = block.inner(area);
        frame.render_widget(block, area);

        if self.scan.files.is_empty() || inner.width == 0 || inner.height == 0 {
            return;
        }

        let max_items = (inner.width as usize * inner.height as usize).min(self.scan.files.len());
        let display_files = &self.scan.files[..max_items];
        let sizes: Vec<u64> = display_files.iter().map(|f| f.size).collect();

        let rects = treemap::layout(&sizes, inner.width as f64, inner.height as f64);

        let buf = frame.buffer_mut();

        for rect in &rects {
            let rx = inner.x + rect.x as u16;
            let ry = inner.y + rect.y as u16;
            let rw = (rect.w as u16).max(1);
            let rh = (rect.h as u16).max(1);

            let color = COLORS[rect.index % COLORS.len()];
            let is_selected = rect.index == self.selected;

            let style = if is_selected {
                Style::default()
                    .bg(Color::White)
                    .fg(Color::Black)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().bg(color).fg(Color::Black)
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
                let label = short_name(&self.scan.files[rect.index], rw as usize - 1);
                for (i, ch) in label.chars().enumerate() {
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

    fn draw_file_list(&mut self, frame: &mut Frame, area: Rect) {
        let title = if self.scanning {
            let spinner = SPINNER[self.spinner_tick % SPINNER.len()];
            format!(
                " {} Files ({} found, scanning {} files...) ",
                spinner, self.scan.files.len(), self.scan_file_count
            )
        } else {
            format!(" Files ({}) ", self.scan.files.len())
        };
        let block = Block::default().borders(Borders::ALL).title(title);
        let inner = block.inner(area);
        frame.render_widget(block, area);

        let visible_rows = inner.height as usize;
        if visible_rows == 0 {
            return;
        }

        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        }
        if self.selected >= self.scroll_offset + visible_rows {
            self.scroll_offset = self.selected - visible_rows + 1;
        }

        let mut lines: Vec<Line> = Vec::new();
        for (i, file) in self
            .scan
            .files
            .iter()
            .enumerate()
            .skip(self.scroll_offset)
            .take(visible_rows)
        {
            let size_str = format!("{:>10}", ByteSize(file.size));
            let path_str = file
                .path
                .strip_prefix(&self.scan.root)
                .unwrap_or(&file.path)
                .display()
                .to_string();

            let color = COLORS[i % COLORS.len()];
            let style = if i == self.selected {
                Style::default()
                    .bg(Color::White)
                    .fg(Color::Black)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(color)
            };

            lines.push(Line::from(vec![
                Span::styled(size_str, style.add_modifier(Modifier::BOLD)),
                Span::styled("  ", style),
                Span::styled(path_str, style),
            ]));
        }

        let paragraph = Paragraph::new(lines);
        frame.render_widget(paragraph, inner);
    }

    fn draw_status_bar(&self, frame: &mut Frame, area: Rect) {
        let scan_info = if self.scanning {
            let spinner = SPINNER[self.spinner_tick % SPINNER.len()];
            format!(
                " {} Scanning: {} files ({}) ",
                spinner,
                self.scan_file_count,
                ByteSize(self.scan_total_bytes)
            )
        } else {
            format!(
                " Total: {} │ Files: {} ",
                ByteSize(self.scan_total_bytes.max(self.scan.total_size)),
                self.scan.files.len()
            )
        };

        let selected_info = if !self.scan.files.is_empty() {
            let f = &self.scan.files[self.selected];
            format!(
                "│ Selected: {} ({}) ",
                f.path.file_name().unwrap_or_default().to_string_lossy(),
                ByteSize(f.size)
            )
        } else {
            String::new()
        };

        let freed_info = if self.deleted_count > 0 {
            format!(
                "│ Freed: {} ({} files) ",
                ByteSize(self.deleted_bytes),
                self.deleted_count
            )
        } else {
            String::new()
        };

        let status = format!(
            "{}{}{}│ ↑↓ navigate  d delete  Tab treemap  q quit",
            scan_info, selected_info, freed_info,
        );

        let block = Block::default().borders(Borders::ALL);
        let paragraph = Paragraph::new(status)
            .style(Style::default().fg(Color::White))
            .block(block);
        frame.render_widget(paragraph, area);
    }
}

fn short_name(file: &FileEntry, max_len: usize) -> String {
    let name = file
        .path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();

    if name.len() <= max_len {
        name
    } else if max_len > 3 {
        format!("{}...", &name[..max_len - 3])
    } else {
        name[..max_len].to_string()
    }
}
