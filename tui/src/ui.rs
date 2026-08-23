//! Drawing the model.
//!
//! ratatui does here what src/tui/screen.lisp did by hand: two buffers, a
//! diff, and only the changed cells on the wire. That part is not novel and
//! is not ours -- what is ours is above it, and this file is only the
//! arrangement.

use crate::model::{Focus, Model, Outcome, Role, TaskState};
use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph, Wrap};

pub const ACCENT: Color = Color::Indexed(13);
const DIM: Color = Color::Indexed(244);
const BORDER: Color = Color::Indexed(240);

/// Where each thing was drawn, so a click can be answered without a second
/// calculation of the same layout. Two functions deriving it independently is
/// how a tab bar selects the tab next to the one that was clicked.
#[derive(Debug, Default, Clone)]
pub struct Hitboxes {
    pub tabs: Vec<(usize, Rect)>,
    pub new_tab: Option<Rect>,
    pub sessions: Rect,
    pub session_rows: Vec<(usize, Rect)>,
    pub transcript: Rect,
    pub tasks: Rect,
    pub input: Rect,
    pub picker: Option<Rect>,
    pub picker_rows: Vec<(usize, Rect)>,
    pub command_rows: Vec<(usize, Rect)>,
}

/// The transcript, laid out once per change instead of once per frame.
///
/// Wrapping is what costs: building the lines and asking the paragraph how
/// tall it is both walk the whole conversation, and doing that at every
/// keypress means a long session is slower than a short one at exactly the
/// moment a person notices. Measured at 43ms a frame for 200 turns before this
/// existed, which is three frames' worth of work to move a cursor.
#[derive(Default)]
pub struct Rendered {
    key: Option<(String, u64, u16)>,
    lines: Vec<Line<'static>>,
    total: u16,
}

/// Break LINES to WIDTH, keeping each span's style across the break.
///
/// Wrapping HERE rather than at render time is the point. A Paragraph wraps
/// every time it is drawn, so a frame costs the length of the conversation
/// however little of it is visible -- and a person scrolling is asking for a
/// frame per keypress. Wrapped once per change, the render is a slice.
/// A line, and what stands in front of the rows it wraps onto.
///
/// A result line that begins with a gutter and loses it on the rows below
/// breaks its own block open: the second half of a long line starts at the
/// pane edge, outside the rule that says which call printed it.
struct Hanging {
    line: Line<'static>,
    indent: Option<Span<'static>>,
}

impl Hanging {
    fn plain(line: Line<'static>) -> Self {
        Hanging { line, indent: None }
    }

    fn under(indent: &'static str, style: Style, line: Line<'static>) -> Self {
        Hanging { line, indent: Some(Span::styled(indent, style)) }
    }
}

fn wrap_lines(lines: &[Hanging], width: u16) -> Vec<Line<'static>> {
    let width = width.max(1) as usize;
    let mut wrapped: Vec<Line<'static>> = Vec::with_capacity(lines.len());
    for hanging in lines {
        // A gutter as wide as the pane would leave no room for the text it is
        // meant to be indenting, and the wrap would never advance.
        let indent = hanging
            .indent
            .clone()
            .filter(|span| span.content.chars().count() < width);
        let carry = |row: &mut Vec<Span<'static>>| match &indent {
            Some(span) => {
                row.push(span.clone());
                span.content.chars().count()
            }
            None => 0,
        };
        let mut row: Vec<Span<'static>> = Vec::new();
        let mut used = 0usize;
        for span in &hanging.line.spans {
            let style = span.style;
            let mut rest: &str = &span.content;
            while !rest.is_empty() {
                let room = width.saturating_sub(used);
                if room == 0 {
                    wrapped.push(Line::from(std::mem::take(&mut row)));
                    used = carry(&mut row);
                    continue;
                }
                let taken = rest.chars().take(room).collect::<String>();
                if taken.len() == rest.len() {
                    used += taken.chars().count();
                    row.push(Span::styled(taken, style));
                    rest = "";
                } else {
                    // Break at the last space that fits, so a word is not cut
                    // in half unless it is longer than the pane.
                    let cut = taken.rfind(' ').map(|at| at + 1).unwrap_or(taken.len());
                    let (head, _) = taken.split_at(cut);
                    row.push(Span::styled(head.to_string(), style));
                    rest = &rest[cut..];
                    wrapped.push(Line::from(std::mem::take(&mut row)));
                    used = carry(&mut row);
                }
            }
        }
        wrapped.push(Line::from(row));
    }
    wrapped
}

impl Rendered {
    /// The rows to draw for a window HEIGHT tall starting at OFFSET.
    ///
    /// A slice, so rendering costs the height of the pane rather than the
    /// length of the session.
    fn window(&self, offset: u16, height: u16) -> Vec<Line<'static>> {
        let start = (offset as usize).min(self.lines.len());
        let end = (start + height as usize).min(self.lines.len());
        self.lines[start..end].to_vec()
    }

    fn refresh(&mut self, model: &Model, width: u16) {
        let revision = model
            .current_conversation()
            .map(|conversation| conversation.revision)
            .unwrap_or(0);
        let key = (model.current.clone(), revision, width);
        if self.key.as_ref() == Some(&key) {
            return;
        }
        self.lines = wrap_lines(&transcript_lines(model), width);
        self.total = self.lines.len().min(u16::MAX as usize) as u16;
        self.key = Some(key);
    }
}

pub fn draw(frame: &mut Frame, model: &Model, rendered: &mut Rendered) -> Hitboxes {
    let area = frame.area();
    let mut hits = Hitboxes::default();

    let rows = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(3),
        Constraint::Length(3),
        Constraint::Length(1),
    ])
    .split(area);

    draw_tabs(frame, rows[0], model, &mut hits);

    // Side panes are dropped as the width falls, widest cost first. A tmux
    // pane is not a hundred columns, and side panes that squeeze the
    // transcript to nothing are worse than no side panes.
    let body = if area.width < 60 {
        let single = Layout::horizontal([Constraint::Min(0)]).split(rows[1]);
        vec![single[0]]
    } else if area.width < 100 {
        Layout::horizontal([Constraint::Length(22), Constraint::Min(0)])
            .split(rows[1])
            .to_vec()
    } else {
        Layout::horizontal([
            Constraint::Length(24),
            Constraint::Min(0),
            Constraint::Length(30),
        ])
        .split(rows[1])
        .to_vec()
    };

    let transcript_area = if body.len() == 1 { body[0] } else { body[1] };
    if body.len() > 1 {
        draw_sessions(frame, body[0], model, &mut hits);
    }
    draw_transcript(frame, transcript_area, model, rendered, &mut hits);
    if body.len() > 2 {
        draw_tasks(frame, body[2], model, &mut hits);
    }

    draw_input(frame, rows[2], model, &mut hits);
    draw_status(frame, rows[3], model);
    if model.showing_learned {
        draw_learned(frame, area, model);
    } else if model.focus == Focus::Picker {
        draw_picker(frame, area, model, &mut hits);
    } else {
        draw_command_menu(frame, rows[2], model, &mut hits);
    }
    hits
}

/// The commands a half-typed slash line could still become.
///
/// ABOVE the prompt and only while one is being typed. A closed set nobody can
/// see is barely better than no set: the person has to already know the words
/// to find out that the words exist.
fn draw_command_menu(frame: &mut Frame, input_area: Rect, model: &Model, hits: &mut Hitboxes) {
    let matches = crate::commands::matching(&model.input);
    if matches.is_empty() {
        return;
    }
    let width = input_area.width.min(64);
    let height = (matches.len() as u16 + 2).min(input_area.y.max(3));
    let area = Rect::new(
        input_area.x,
        input_area.y.saturating_sub(height),
        width,
        height,
    );
    frame.render_widget(Clear, area);
    let block = pane("", true);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    hits.command_rows.clear();

    let name_width = matches.iter().map(|c| c.name.len()).max().unwrap_or(6);
    let mut lines: Vec<Line> = Vec::new();
    for (index, command) in matches.iter().enumerate() {
        if index as u16 >= inner.height {
            break;
        }
        let chosen = index == model.command_selection.min(matches.len() - 1);
        let style = if chosen {
            Style::default().fg(Color::Indexed(232)).bg(ACCENT).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(Color::Indexed(252))
        };
        lines.push(Line::from(vec![
            Span::styled(format!(" {:name_width$} ", command.name), style),
            Span::styled(format!(" {}", command.blurb), Style::default().fg(DIM)),
        ]));
        hits.command_rows.push((
            index,
            Rect::new(inner.x, inner.y + index as u16, inner.width, 1),
        ));
    }
    frame.render_widget(Paragraph::new(lines), inner);
}

/// Every session there has ever been, searchable.
///
/// Over the frame rather than beside it. The sidebar answers `what is
/// running`; this answers `what have I talked to`, and the second list is
/// hundreds long where the first is three -- so it takes the screen while it
/// is being used and gives it back afterwards.
fn draw_picker(frame: &mut Frame, area: Rect, model: &Model, hits: &mut Hitboxes) {
    let width = area.width.saturating_sub(8).min(90).max(20);
    let height = area.height.saturating_sub(6).min(24).max(6);
    let box_area = Rect::new(
        area.x + (area.width.saturating_sub(width)) / 2,
        area.y + (area.height.saturating_sub(height)) / 2,
        width,
        height,
    );
    frame.render_widget(Clear, box_area);
    let block = pane("find a session", true);
    let inner = block.inner(box_area);
    frame.render_widget(block, box_area);
    hits.picker = Some(inner);

    let rows = Layout::vertical([Constraint::Length(2), Constraint::Min(1)]).split(inner);
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("search ", Style::default().fg(DIM)),
            Span::styled(
                model.picker.query.clone(),
                Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
            ),
            Span::styled("_", Style::default().fg(ACCENT)),
        ])),
        rows[0],
    );

    let mut lines: Vec<Line> = Vec::new();
    hits.picker_rows.clear();
    for (index, found) in model.picker.results.iter().enumerate() {
        if index as u16 >= rows[1].height {
            break;
        }
        let chosen = index == model.picker.selection;
        let style = if chosen {
            Style::default().fg(Color::Indexed(232)).bg(ACCENT).add_modifier(Modifier::BOLD)
        } else {
            Style::default()
        };
        let opening: String = found.opening.chars().take(48).collect();
        lines.push(Line::from(vec![
            Span::styled(format!("{:<10}", found.short_cwd()), style.fg(if chosen {
                Color::Indexed(232)
            } else {
                Color::Indexed(252)
            })),
            Span::styled(format!(" {:>4} msg  ", found.messages), Style::default().fg(DIM)),
            Span::styled(opening, style),
        ]));
        hits.picker_rows.push((index, Rect::new(rows[1].x, rows[1].y + index as u16, rows[1].width, 1)));
    }
    if lines.is_empty() {
        // `looking` and `nothing found` are different answers, and a picker
        // that says the second while the first is true teaches people it is
        // broken.
        let message = if model.picker.searching { "looking…" } else { "nothing found" };
        lines.push(Line::from(Span::styled(message, Style::default().fg(DIM))));
    }
    frame.render_widget(Paragraph::new(lines), rows[1]);
}

fn pane(title: &str, focused: bool) -> Block<'_> {
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(if focused { ACCENT } else { BORDER }))
        .title(Span::styled(
            format!(" {title} "),
            Style::default()
                .fg(if focused { ACCENT } else { Color::Indexed(252) })
                .add_modifier(Modifier::BOLD),
        ))
}

fn draw_tabs(frame: &mut Frame, area: Rect, model: &Model, hits: &mut Hitboxes) {
    let mut spans: Vec<Span> = Vec::new();
    let mut column = area.x + 1;
    spans.push(Span::raw(" "));
    for (index, id) in model.tabs.iter().enumerate() {
        let text = format!(" {} ", model.tab_label(id));
        let width = text.chars().count() as u16;
        let style = if index == model.tab {
            Style::default().fg(Color::Indexed(232)).bg(ACCENT).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(DIM)
        };
        hits.tabs.push((index, Rect::new(column, area.y, width, 1)));
        spans.push(Span::styled(text, style));
        column += width;
        spans.push(Span::styled("│", Style::default().fg(BORDER)));
        column += 1;
    }
    // `+` is a target, reported like any tab. Drawn and not reported was the
    // Lisp client's bug: clicking it did nothing and looked broken.
    hits.new_tab = Some(Rect::new(column, area.y, 3, 1));
    spans.push(Span::styled(" + ", Style::default().fg(DIM)));
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn draw_sessions(frame: &mut Frame, area: Rect, model: &Model, hits: &mut Hitboxes) {
    let focused = model.focus == Focus::Sessions;
    let block = pane("sessions", focused);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    hits.sessions = inner;

    let mut lines: Vec<Line> = Vec::new();
    for (index, session) in model.sessions.iter().enumerate() {
        let current = session.id == model.current;
        let (mark, colour) = state_mark(&session.state);
        let marker = if current { ">" } else { " " };
        let cursor = if focused && index == model.selection { "[" } else { " " };
        lines.push(Line::from(vec![
            Span::styled(marker.to_string(), Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
            Span::styled(cursor.to_string(), Style::default().fg(ACCENT)),
            Span::styled(format!("{mark} "), Style::default().fg(colour)),
            Span::styled(
                session.short_label().to_string(),
                if current {
                    Style::default().fg(Color::Indexed(252)).add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                },
            ),
        ]));
        lines.push(Line::from(Span::styled(
            format!("    {}", session.state),
            Style::default().fg(DIM),
        )));
        let row = inner.y + (index as u16) * 2;
        if row < inner.y + inner.height {
            hits.session_rows.push((index, Rect::new(inner.x, row, inner.width, 2)));
        }
    }
    if lines.is_empty() {
        lines.push(Line::from(Span::styled("no sessions", Style::default().fg(DIM))));
    }
    frame.render_widget(Paragraph::new(lines), inner);
}

fn state_mark(state: &str) -> (&'static str, Color) {
    match state {
        "working" => ("*", Color::Indexed(220)),
        "stuck" => ("!", Color::Indexed(203)),
        "suspended" => ("~", Color::Indexed(111)),
        "stopping" => (".", DIM),
        _ => ("-", BORDER),
    }
}

/// The transcript, with a visible difference between a question and an answer.
///
/// The difference is carried by a PREFIX as well as a colour. Colour alone is
/// invisible on a monochrome terminal, to anyone who cannot tell two shades
/// apart, and to any test that reads the frame back -- so the distinction that
/// matters most is the one that must not depend on it.
fn transcript_lines(model: &Model) -> Vec<Hanging> {
    let mut lines: Vec<Hanging> = Vec::new();
    let Some(conversation) = model.current_conversation() else {
        return lines;
    };
    // How many lines of a tool result to show when it is not expanded. Three
    // is enough to see what a command said and not enough to bury the
    // conversation it belongs to.
    const GLIMPSE: usize = 3;
    for entry in conversation.visible_entries() {
        let text = entry.text.as_str();
        match entry.role {
            Role::User => {
                let voice = Style::default().fg(ACCENT).add_modifier(Modifier::BOLD);
                lines.push(Hanging::plain(Line::from("")));
                for (index, piece) in text.lines().enumerate() {
                    let prefix = if index == 0 { "› " } else { "  " };
                    lines.push(Hanging::under("  ", voice, Line::from(vec![
                        Span::styled(prefix, voice),
                        Span::styled(piece.to_string(), voice),
                    ])));
                }
                lines.push(Hanging::plain(Line::from("")));
            }
            Role::Assistant => {
                for piece in text.split('\n') {
                    lines.push(Hanging::plain(Line::from(Span::raw(piece.to_string()))));
                }
            }
            Role::Tool => {
                // A titled rule rather than a dim line, so a call and its
                // result read as one block instead of as loose text that
                // happens to follow.
                let colour = match entry.outcome {
                    Outcome::Failed => Color::Indexed(203),
                    Outcome::Done => Color::Indexed(114),
                    Outcome::Running => Color::Indexed(220),
                };
                lines.push(Hanging::under("  ", Style::default(), Line::from(vec![
                    Span::styled(format!("{} ", entry.outcome.mark()), Style::default().fg(colour)),
                    Span::styled(text.to_string(),
                                 Style::default().fg(Color::Indexed(252))),
                ])));
                let shown = if conversation.expanded {
                    entry.output.len()
                } else {
                    entry.output.len().min(GLIMPSE)
                };
                let gutter = Style::default().fg(BORDER);
                for line in entry.output.iter().take(shown) {
                    lines.push(Hanging::under("  │ ", gutter, Line::from(vec![
                        Span::styled("  │ ", gutter),
                        Span::styled(line.clone(), Style::default().fg(DIM)),
                    ])));
                }
                // The hidden lines are ANNOUNCED. Silently showing three of
                // four hundred teaches a person the command printed three.
                if entry.output.len() > shown {
                    lines.push(Hanging::plain(Line::from(Span::styled(
                        format!("  │ … {} more line{}  (ctrl-o)",
                                entry.output.len() - shown,
                                if entry.output.len() - shown == 1 { "" } else { "s" }),
                        gutter,
                    ))));
                }
            }
            Role::Note => {
                let alarm = Style::default().fg(Color::Indexed(203));
                lines.push(Hanging::under("  ", alarm,
                                          Line::from(Span::styled(format!("! {text}"), alarm))));
            }
        }
    }
    lines
}

fn draw_transcript(
    frame: &mut Frame,
    area: Rect,
    model: &Model,
    rendered: &mut Rendered,
    hits: &mut Hitboxes,
) {
    let title = model
        .sessions
        .iter()
        .find(|session| session.id == model.current)
        .map(|session| session.short_label().to_string())
        .unwrap_or_else(|| "transcript".into());
    let block = pane(&title, model.focus == Focus::Input);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    hits.transcript = inner;

    rendered.refresh(model, inner.width);
    let offset = scroll_offset(model, rendered.total, inner.height);
    // No wrap here: it is already wrapped, and only the visible rows are sent.
    frame.render_widget(Paragraph::new(rendered.window(offset, inner.height)), inner);
}

/// How far down to start, given how much there is and how much fits.
///
/// Following pins to the bottom. Scrolled, the offset is clamped to what
/// exists: without an upper bound, holding Page Up walks past the start of the
/// conversation and the pane goes blank -- the text still there, the window
/// moved off the end.
pub fn scroll_offset(model: &Model, total: u16, height: u16) -> u16 {
    let furthest = total.saturating_sub(height);
    match model.current_conversation() {
        Some(conversation) if !conversation.following => {
            furthest.saturating_sub(conversation.scroll.min(furthest))
        }
        _ => furthest,
    }
}

/// What this session has retained, as the files it actually wrote.
///
/// Named by their scope, because that is the fact a person needs: a
/// machine-level tool loads in every project they open, and a project-level
/// one does not. Refused entries are shown as refused rather than folded in --
/// "there is a tool here" and "the agent can call it" are different facts, and
/// a client that merges them makes an untrusted project look equipped.
fn draw_learned(frame: &mut Frame, area: Rect, model: &Model) {
    let width = area.width.saturating_sub(6).min(96).max(24);
    let height = area.height.saturating_sub(4).min(30).max(8);
    let box_area = Rect::new(
        area.x + area.width.saturating_sub(width) / 2,
        area.y + area.height.saturating_sub(height) / 2,
        width,
        height,
    );
    frame.render_widget(Clear, box_area);
    let block = pane("what this session has learned", true);
    let inner = block.inner(box_area);
    frame.render_widget(block, box_area);

    let learned = &model.learned;
    let mut lines: Vec<Line> = Vec::new();
    let mut section = |lines: &mut Vec<Line>, title: &str, items: &[crate::protocol::Retained],
                       colour: Color| {
        lines.push(Line::from(Span::styled(
            format!("{title}  ({})", items.len()),
            Style::default().fg(colour).add_modifier(Modifier::BOLD),
        )));
        if items.is_empty() {
            lines.push(Line::from(Span::styled("  none yet", Style::default().fg(DIM))));
        }
        for item in items {
            lines.push(Line::from(vec![
                Span::styled(format!("  {:<22}", item.name), Style::default().fg(Color::Indexed(252))),
                Span::styled(format!("{:<9}", item.scope), Style::default().fg(DIM)),
                Span::styled(item.detail.clone(), Style::default().fg(DIM)),
            ]));
        }
        lines.push(Line::from(""));
    };
    section(&mut lines, "notes", &learned.notes, ACCENT);
    section(&mut lines, "skills", &learned.skills, Color::Indexed(114));
    section(&mut lines, "tools", &learned.tools, Color::Indexed(220));
    if !learned.refused.is_empty() {
        section(&mut lines, "refused — this project is not trusted",
                &learned.refused, Color::Indexed(203));
        lines.push(Line::from(Span::styled(
            "  `viva trust` lets a project's own tools run as you.",
            Style::default().fg(DIM),
        )));
    }
    lines.push(Line::from(Span::styled(
        "  these are files; read, edit or delete them by hand.",
        Style::default().fg(DIM),
    )));
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), inner);
}

fn draw_tasks(frame: &mut Frame, area: Rect, model: &Model, hits: &mut Hitboxes) {
    let block = pane("tasks", false);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    hits.tasks = inner;

    let mut lines: Vec<Line> = Vec::new();
    if let Some(conversation) = model.current_conversation() {
        for task in conversation.tasks.values() {
            let colour = match task.state {
                TaskState::Running => Color::Indexed(220),
                TaskState::Done => Color::Indexed(114),
                TaskState::Failed => Color::Indexed(203),
                _ => DIM,
            };
            // Depth by parentage: a subagent that spawned a subagent is a
            // shape worth seeing, and it is the whole point of a task tree.
            let indent = if task.parent.is_some() { "  " } else { "" };
            lines.push(Line::from(vec![
                Span::raw(indent),
                Span::styled(format!("{} ", task.state.mark()), Style::default().fg(colour)),
                Span::raw(task.label.clone()),
            ]));
            if !task.latest.is_empty() {
                lines.push(Line::from(Span::styled(
                    format!("{indent}  {}", task.latest),
                    Style::default().fg(DIM),
                )));
            }
        }
    }
    if lines.is_empty() {
        lines.push(Line::from(Span::styled("no tasks", Style::default().fg(DIM))));
    }
    // trim: FALSE. Trimming strips leading whitespace, and the indent is how a
    // task says whose child it is -- so a trimming wrap rendered a tree as a
    // flat list and threw away the only thing the task pane knows that a
    // session list does not.
    frame.render_widget(Paragraph::new(lines).wrap(Wrap { trim: false }), inner);
}

fn draw_input(frame: &mut Frame, area: Rect, model: &Model, hits: &mut Hitboxes) {
    let block = pane("", model.focus == Focus::Input);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    hits.input = inner;
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("› ", Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
            Span::raw(model.input.clone()),
        ])),
        inner,
    );
    // The cursor sits after what was typed, not wherever the last write ended.
    // Screen readers follow it too.
    let column = inner.x + 2 + model.input.chars().count() as u16;
    frame.set_cursor_position((column.min(inner.x + inner.width - 1), inner.y));
}

fn draw_status(frame: &mut Frame, area: Rect, model: &Model) {
    let following = model
        .current_conversation()
        .map(|conversation| conversation.following)
        .unwrap_or(true);
    let mut text = format!(" {}", model.status);
    if !following {
        text.push_str("   [scrolled — End to follow]");
    }
    if model.current_conversation().map(|c| c.expanded).unwrap_or(false) {
        text.push_str("   [tool output expanded — ctrl-o]");
    }
    if !model.connected {
        text.push_str("   [daemon gone]");
    }
    if model.current_conversation().map(|c| c.gap).unwrap_or(false) {
        text.push_str("   [missed events — ctrl-r to re-read]");
    }
    // ALWAYS the counts, never only behind a keystroke. A harness whose point
    // is that it learns should say what it has learned without being asked.
    let learned = &model.learned;
    // Shown even at zero, once asked. A fresh project retaining nothing is
    // exactly when somebody most needs to learn that the harness retains --
    // hiding the row until it is non-empty hides the feature from everyone who
    // has not used it yet.
    if learned.inspected {
        text.push_str(&format!(
            "   learned {} note{} · {} skill{} · {} tool{}",
            learned.notes.len(), if learned.notes.len() == 1 { "" } else { "s" },
            learned.skills.len(), if learned.skills.len() == 1 { "" } else { "s" },
            learned.tools.len(), if learned.tools.len() == 1 { "" } else { "s" },
        ));
        if !learned.refused.is_empty() {
            text.push_str(&format!("  ({} refused — untrusted)", learned.refused.len()));
        }
    }
    if let Some(session) = model.sessions.iter().find(|s| s.id == model.current) {
        if !session.model.is_empty() {
            text.push_str(&format!("   {}", session.model));
        }
    }
    frame.render_widget(
        Paragraph::new(Span::styled(text, Style::default().fg(DIM))),
        area,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Model;
    use crate::protocol::{Event, SessionInfo};
    use ratatui::backend::TestBackend;
    use serde_json::json;

    fn event(name: &str, data: serde_json::Value) -> Event {
        serde_json::from_value(json!({"event": name, "session": "s1", "seq": 1, "data": data}))
            .unwrap()
    }

    /// The frame as text, one string per row -- what a person would see.
    fn frame_of(model: &Model, width: u16, height: u16) -> Vec<String> {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        let mut rendered = Rendered::default();
        terminal.draw(|f| { draw(f, model, &mut rendered); }).unwrap();
        let buffer = terminal.backend().buffer().clone();
        (0..buffer.area.height)
            .map(|row| {
                (0..buffer.area.width)
                    .map(|column| buffer[(column, row)].symbol().to_string())
                    .collect::<String>()
                    .trim_end()
                    .to_string()
            })
            .collect()
    }

    fn ready(entries: &[(&str, &str)]) -> Model {
        let mut model = Model::new("/w".into());
        model.sessions = vec![
            SessionInfo { id: "s1".into(), label: "/w/alpha".into(), state: "working".into(), ..Default::default() },
            SessionInfo { id: "s2".into(), label: "/w/beta".into(), state: "stuck".into(), ..Default::default() },
        ];
        model.open_tab("s1");
        for (kind, text) in entries {
            model.absorb(&event(kind, json!({"text": text})));
        }
        model
    }

    #[test]
    fn a_question_looks_different_from_an_answer_on_the_screen() {
        // Asserted on the RENDERED frame, not on the model: the distinction
        // exists to be seen, and a model that holds it while the renderer drops
        // it is exactly the failure this catches.
        //
        // A PREFIX as well as a colour. Colour alone is invisible on a
        // monochrome terminal, to anyone who cannot tell two shades apart, and
        // to this test -- so the distinction that matters most must not depend
        // on it.
        let model = ready(&[
            ("user.message", "what is in this folder"),
            ("model.delta", "a README and a Cargo.toml\n"),
        ]);
        let frame = frame_of(&model, 100, 20);
        let question = frame.iter().find(|line| line.contains("what is in this folder")).unwrap();
        let answer = frame.iter().find(|line| line.contains("a README")).unwrap();
        assert!(question.contains('›'), "the question carries no marker: {question:?}");
        assert!(!answer.contains('›'), "the answer was marked as a question: {answer:?}");
    }

    #[test]
    fn a_child_task_is_drawn_under_its_parent() {
        // The indent is the whole of what the task pane knows that a flat list
        // does not. A trimming wrap strips leading whitespace and renders the
        // tree flat, which is how this shipped the first time.
        let mut model = ready(&[]);
        model.absorb(&event("task.started", json!({"task": "t1", "text": "run the suite"})));
        model.absorb(&event(
            "task.started",
            json!({"task": "t2", "text": "compile it", "parent": "t1"}),
        ));
        let frame = frame_of(&model, 120, 16);
        let parent = frame.iter().find(|l| l.contains("run the suite")).unwrap();
        let child = frame.iter().find(|l| l.contains("compile it")).unwrap();
        let parent_at = parent.find("run the suite").unwrap();
        let child_at = child.find("compile it").unwrap();
        assert!(
            child_at > parent_at,
            "the child is not indented under its parent ({child_at} vs {parent_at})"
        );
    }

    #[test]
    fn one_frame_holds_the_sessions_the_talk_and_the_work() {
        let mut model = ready(&[("user.message", "run it")]);
        model.absorb(&event("task.started", json!({"task": "t1", "text": "indexing"})));
        model.absorb(&event("tool.output", json!({"text": "step 3 of 9\n"})));
        let frame = frame_of(&model, 120, 20).join("\n");
        assert!(frame.contains("alpha"), "no session list");
        assert!(frame.contains("beta"), "the other session is missing");
        assert!(frame.contains("run it"), "no transcript");
        assert!(frame.contains("indexing"), "the subagent is not in the task pane");
        assert!(frame.contains("step 3 of 9"), "what the work is printing is not shown");
    }

    #[test]
    fn a_long_tool_result_is_glimpsed_and_the_rest_announced() {
        // Silently showing three lines of four hundred teaches a person the
        // command printed three.
        let mut model = ready(&[]);
        model.absorb(&event("tool.started",
                            json!({"call": {"name": "bash", "arguments": {"command": "build"}}})));
        for n in 0..40 {
            model.absorb(&event("tool.output", json!({"text": format!("line{n}\n")})));
        }
        let frame = frame_of(&model, 100, 26).join("\n");
        assert!(frame.contains("line0"), "no output at all");
        assert!(frame.contains("37 more lines"), "the hidden lines are not announced");
        assert!(!frame.contains("line39"), "everything was shown despite the glimpse");
        // Expanded, the rest is there and the status line says so.
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.expanded = true;
            conversation.revision += 1;
        }
        let wide = frame_of(&model, 100, 60).join("\n");
        assert!(wide.contains("line39"), "expanding showed nothing more");
        assert!(wide.contains("expanded"), "nothing says the output is expanded");
    }

    #[test]
    fn a_wrapped_result_line_stays_inside_its_own_block() {
        // A result line longer than the pane loses the gutter on the rows
        // below it, and the second half of the line starts at the pane edge
        // -- outside the rule that says which call printed it.
        let mut model = ready(&[]);
        model.absorb(&event("tool.started",
                            json!({"call": {"name": "bash", "arguments": {"command": "cat x"}}})));
        let long = "alpha bravo charlie delta echo foxtrot golf hotel india juliet \
kilo lima mike november oscar papa quebec";
        model.absorb(&event("tool.completed", json!({"output": long})));
        // Read the TRANSCRIPT CELL, not the frame. The session is also named
        // `alpha` in the tab bar and in the sidebar, and a check that scans
        // whole rows for a word finds those first and tests nothing.
        let rows = frame_of(&model, 100, 26);
        let cells: Vec<String> = rows
            .iter()
            .filter_map(|row| row.split("││").nth(1).map(str::to_string))
            .collect();
        let carrying: Vec<&String> = cells.iter().filter(|cell| cell.contains("│ ")).collect();
        assert!(carrying.len() >= 2, "the result did not wrap, so nothing was tested");
        for word in ["alpha", "kilo", "quebec"] {
            let cell = cells.iter().find(|cell| cell.contains(word))
                .unwrap_or_else(|| panic!("{word} is not in the transcript"));
            let before = cell.split(word).next().unwrap();
            assert!(before.contains("│ "), "the row carrying {word} left its block: {cell:?}");
        }
    }

    #[test]
    fn a_narrow_pane_keeps_the_talk_and_drops_the_rest() {
        // Where this lives is a split, not a hundred-column window. Side panes
        // that squeeze the transcript to nothing are worse than none.
        let model = ready(&[("model.delta", "still readable\n")]);
        let wide = frame_of(&model, 120, 16).join("\n");
        let narrow = frame_of(&model, 50, 16).join("\n");
        assert!(wide.contains("tasks"), "the wide frame has no task pane");
        assert!(narrow.contains("still readable"), "the narrow frame lost the transcript");
        assert!(!narrow.contains("tasks"), "the task pane survived into 50 columns");
    }

    #[test]
    fn the_current_session_is_marked_by_a_character_not_only_a_colour() {
        let model = ready(&[]);
        let frame = frame_of(&model, 100, 16);
        // The row INSIDE the sidebar. The tab bar carries the same name and
        // comes first, so the obvious `find` picks it and asserts about the
        // wrong row -- which is a test that passes or fails for reasons
        // unrelated to what it claims to check.
        let row = frame
            .iter()
            .find(|line| line.contains("alpha") && line.starts_with('│'))
            .expect("the sidebar has no row for the current session");
        assert!(row.contains('>'), "the current session's row carries no marker: {row:?}");
        assert!(row.contains('*'), "the working session shows no state mark: {row:?}");
    }

    #[test]
    fn scrolling_stops_at_both_ends() {
        // Without an upper bound, holding Page Up walks the offset past the
        // start and the pane goes blank: the text still there, the window moved
        // off the end.
        let mut model = ready(&[]);
        for index in 0..60 {
            model.absorb(&event("model.delta", json!({"text": format!("line{index}\n")})));
        }
        // Following pins to the bottom whatever the numbers say.
        assert_eq!(scroll_offset(&model, 60, 10), 50);
        // Scrolled back ten, the window moves ten -- not more.
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.following = false;
            conversation.scroll = 10;
        }
        assert_eq!(scroll_offset(&model, 60, 10), 40);
        // Asked for far more than exists, it stops at the first line.
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.scroll = u16::MAX;
        }
        assert_eq!(scroll_offset(&model, 60, 10), 0, "scrolling ran past the start");
        // And a conversation shorter than the pane never scrolls at all.
        assert_eq!(scroll_offset(&model, 4, 10), 0);
    }

    #[test]
    fn scrolled_back_is_said_out_loud() {
        // A view that has stopped following looks identical to one with no new
        // output. Saying so is the difference between a pause and a bug.
        let mut model = ready(&[("model.delta", "hello\n")]);
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.following = false;
        }
        let frame = frame_of(&model, 100, 16).join("\n");
        assert!(frame.contains("scrolled"), "nothing says the view is not following");
    }

    #[test]
    fn the_plus_is_a_target_and_the_tabs_report_where_they_are() {
        let mut model = ready(&[]);
        model.open_tab("s2");
        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        let mut hits = Hitboxes::default();
        let mut rendered = Rendered::default();
        terminal.draw(|f| hits = draw(f, &model, &mut rendered)).unwrap();
        assert_eq!(hits.tabs.len(), 2, "the tabs report no hitboxes");
        let plus = hits.new_tab.expect("the + reports no range and so can never be hit");
        let (_, first) = hits.tabs[0];
        assert!(plus.x > first.x, "the + overlaps the first tab");
        // Every tab's box is distinct, so a click cannot select two.
        let (_, second) = hits.tabs[1];
        assert!(second.x >= first.x + first.width, "two tabs claim the same columns");
    }
}
