use crate::scanner::{FileEntry, ScanResult};
use crate::treemap;
use anyhow::Result;
use bytesize::ByteSize;
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    DefaultTerminal, Frame,
};

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

pub struct App {
    scan: ScanResult,
    selected: usize,
    scroll_offset: usize,
    show_treemap: bool,
}

impl App {
    pub fn new(scan: ScanResult) -> Self {
        Self {
            scan,
            selected: 0,
            scroll_offset: 0,
            show_treemap: true,
        }
    }

    pub fn run(mut self, terminal: &mut DefaultTerminal) -> Result<()> {
        loop {
            terminal.draw(|frame| self.draw(frame))?;

            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                match key.code {
                    KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                    KeyCode::Down | KeyCode::Char('j') => {
                        if !self.scan.files.is_empty() {
                            self.selected = (self.selected + 1).min(self.scan.files.len() - 1);
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
                    _ => {}
                }
            }
        }
    }

    fn draw(&mut self, frame: &mut Frame) {
        let size = frame.area();

        if self.show_treemap {
            let outer = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(5),
                    Constraint::Length(3),
                ])
                .split(size);

            let columns = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(50),
                    Constraint::Percentage(50),
                ])
                .split(outer[0]);

            self.draw_treemap(frame, columns[0]);
            self.draw_file_list(frame, columns[1]);
            self.draw_status_bar(frame, outer[1]);
        } else {
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(5),
                    Constraint::Length(3),
                ])
                .split(size);

            self.draw_file_list(frame, chunks[0]);
            self.draw_status_bar(frame, chunks[1]);
        }
    }

    fn draw_treemap(&self, frame: &mut Frame, area: Rect) {
        let block = Block::default()
            .borders(Borders::ALL)
            .title(" Treemap (Tab to toggle) ");
        let inner = block.inner(area);
        frame.render_widget(block, area);

        if self.scan.files.is_empty() || inner.width == 0 || inner.height == 0 {
            return;
        }

        // Use top N files that fit visually
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

            // Fill the rectangle
            for y in ry..ry.saturating_add(rh).min(inner.y + inner.height) {
                for x in rx..rx.saturating_add(rw).min(inner.x + inner.width) {
                    if let Some(cell) = buf.cell_mut((x, y)) {
                        cell.set_style(style);
                        cell.set_char(' ');
                    }
                }
            }

            // Draw label if there's room
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
        let block = Block::default()
            .borders(Borders::ALL)
            .title(format!(
                " Files ({} total, {} shown) ",
                self.scan.files.len(),
                self.scan.files.len()
            ));
        let inner = block.inner(area);
        frame.render_widget(block, area);

        let visible_rows = inner.height as usize;
        if visible_rows == 0 {
            return;
        }

        // Adjust scroll to keep selection visible
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        }
        if self.selected >= self.scroll_offset + visible_rows {
            self.scroll_offset = self.selected - visible_rows + 1;
        }

        let mut lines: Vec<Line> = Vec::new();
        for (i, file) in self.scan
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
        let total = ByteSize(self.scan.total_size);
        let selected_info = if !self.scan.files.is_empty() {
            let f = &self.scan.files[self.selected];
            format!(
                "  │  Selected: {} ({})",
                f.path.file_name().unwrap_or_default().to_string_lossy(),
                ByteSize(f.size)
            )
        } else {
            String::new()
        };

        let status = format!(
            " Total: {} │ Files: {}{}  │  ↑↓ navigate  Tab treemap  q quit",
            total,
            self.scan.files.len(),
            selected_info,
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
