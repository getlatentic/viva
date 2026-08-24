//! Drawing the model.
//!
//! ratatui does here what src/tui/screen.lisp did by hand: two buffers, a
//! diff, and only the changed cells on the wire. That part is not novel and
//! is not ours -- what is ours is above it, and this file is only the
//! arrangement.

use crate::markdown;
use crate::model::{Entry, Focus, Model, Outcome, Role, TaskState};
use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Clear, Padding, Paragraph, Wrap};

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
/// One entry's rows, and the version of the entry they were made from.
struct Laid {
    stamp: u64,
    expanded: bool,
    lines: Vec<Line<'static>>,
}

#[derive(Default)]
pub struct Rendered {
    key: Option<(String, u16)>,
    blocks: Vec<Laid>,
    /// Where each block begins, so a window can be found without walking.
    starts: Vec<usize>,
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

    fn under(indent: impl Into<String>, style: Style, line: Line<'static>) -> Self {
        Hanging { line, indent: Some(Span::styled(indent.into(), style)) }
    }
}

fn wrap_lines(lines: &[Hanging], width: u16) -> Vec<Line<'static>> {
    let width = width.max(1) as usize;
    let mut wrapped: Vec<Line<'static>> = Vec::with_capacity(lines.len());
    for hanging in lines {
        wrapped.extend(wrap_one(hanging, width));
    }
    wrapped
}

/// One line as the rows it needs, breaking between words.
///
/// ACROSS SPANS, not within one. A wrapper that breaks each span on its own
/// sees `react-dom` written half as code and half as prose as two pieces, and
/// cuts the word in half at the seam -- which only shows once something is
/// styling the text, and then shows everywhere.
fn wrap_one(hanging: &Hanging, width: usize) -> Vec<Line<'static>> {
    let indent: Vec<(char, Style)> = match &hanging.indent {
        Some(span) if span.content.chars().count() < width => {
            span.content.chars().map(|character| (character, span.style)).collect()
        }
        _ => Vec::new(),
    };
    let glyphs: Vec<(char, Style)> = hanging
        .line
        .spans
        .iter()
        .flat_map(|span| span.content.chars().map(|character| (character, span.style)))
        .collect();

    let mut rows: Vec<Vec<(char, Style)>> = Vec::new();
    let mut row: Vec<(char, Style)> = Vec::new();
    let mut at = 0;
    while at < glyphs.len() {
        let blank = glyphs[at].0 == ' ';
        let end = (at..glyphs.len())
            .find(|index| (glyphs[*index].0 == ' ') != blank)
            .unwrap_or(glyphs.len());
        let run = &glyphs[at..end];
        at = end;
        if row.len() + run.len() <= width {
            row.extend_from_slice(run);
            continue;
        }
        // The break falls here. A run of spaces IS the break and is dropped;
        // a word moves down whole, unless it is longer than the pane.
        if blank {
            rows.push(std::mem::replace(&mut row, indent.clone()));
            continue;
        }
        if row.len() > indent.len() {
            rows.push(std::mem::replace(&mut row, indent.clone()));
        }
        let mut rest = run;
        while row.len() + rest.len() > width {
            let room = width.saturating_sub(row.len());
            if room == 0 {
                rows.push(std::mem::replace(&mut row, indent.clone()));
                continue;
            }
            row.extend_from_slice(&rest[..room]);
            rest = &rest[room..];
            rows.push(std::mem::replace(&mut row, indent.clone()));
        }
        row.extend_from_slice(rest);
    }
    rows.push(row);
    rows.into_iter().map(to_line).collect()
}

/// Neighbouring characters written the same way become one span again, so a
/// row costs what it says rather than one span per character.
fn to_line(glyphs: Vec<(char, Style)>) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    for (character, style) in glyphs {
        match spans.last_mut() {
            Some(last) if last.style == style => last.content.to_mut().push(character),
            _ => spans.push(Span::styled(character.to_string(), style)),
        }
    }
    Line::from(spans)
}

impl Rendered {
    /// The rows to draw for a window HEIGHT tall starting at OFFSET.
    ///
    /// A slice, so rendering costs the height of the pane rather than the
    /// length of the session.
    fn window(&self, offset: u16, height: u16) -> Vec<Line<'static>> {
        let first = (offset as usize).min(self.total as usize);
        let last = (first + height as usize).min(self.total as usize);
        let mut rows = Vec::with_capacity(last - first);
        // Straight to the block the window opens on, rather than through every
        // line above it.
        let mut at = match self.starts.binary_search(&first) {
            Ok(index) => index,
            Err(index) => index.saturating_sub(1),
        };
        while at < self.blocks.len() {
            let start = self.starts[at];
            if start >= last {
                break;
            }
            for (offset, line) in self.blocks[at].lines.iter().enumerate() {
                let position = start + offset;
                if position >= first && position < last {
                    rows.push(line.clone());
                }
            }
            at += 1;
        }
        rows
    }

    /// Lay out only what changed.
    ///
    /// A token changes ONE entry, and re-wrapping the whole conversation for
    /// it costs the length of the conversation: measured at 6.5ms a token for
    /// ten turns and 70.8ms for four hundred, so a long session got slower at
    /// exactly the moment somebody was watching output arrive. Each entry
    /// carries a stamp that changes when it does, so a pass over a thousand
    /// entries compares a thousand integers and lays out the one that moved.
    fn refresh(&mut self, model: &Model, width: u16) {
        let key = (model.current.clone(), width);
        if self.key.as_ref() != Some(&key) {
            // A different session, or a resize: nothing laid out for the old
            // width can be reused at the new one.
            self.blocks.clear();
            self.key = Some(key);
        }
        let Some(conversation) = model.current_conversation() else {
            self.blocks.clear();
            self.starts.clear();
            self.total = 0;
            return;
        };
        let expanded = conversation.expanded;
        let mut count = 0;
        for entry in conversation.visible_entries() {
            let fresh = match self.blocks.get(count) {
                Some(block) => block.stamp != entry.stamp || block.expanded != expanded,
                None => true,
            };
            if fresh {
                let block = Laid {
                    stamp: entry.stamp,
                    expanded,
                    lines: wrap_lines(&entry_lines(entry, expanded, width), width),
                };
                match self.blocks.get_mut(count) {
                    Some(slot) => *slot = block,
                    None => self.blocks.push(block),
                }
            }
            count += 1;
        }
        self.blocks.truncate(count);

        self.starts.clear();
        self.starts.reserve(self.blocks.len());
        let mut running = 0usize;
        for block in &self.blocks {
            self.starts.push(running);
            running += block.lines.len();
        }
        self.total = running.min(u16::MAX as usize) as u16;
    }
}

pub fn draw(frame: &mut Frame, model: &Model, rendered: &mut Rendered) -> Hitboxes {
    let area = frame.area();
    let mut hits = Hitboxes::default();

    // THE TRANSCRIPT IS THE PAGE. It was one of three boxes side by side, and
    // the boxes around a column of sessions and a column saying `no tasks`
    // cost a quarter of the width at every moment to say what the tab bar
    // already said. Now: tabs, the page, and an input whose top edge carries
    // the status -- three rows of chrome where there were five.
    let rows = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(3),
        Constraint::Length(3),
    ])
    .split(area);

    draw_tabs(frame, rows[0], model, &mut hits);

    // Side columns exist when asked for or needed, and only when there is
    // room: a tmux pane is not a hundred columns, and side columns that
    // squeeze the page to nothing are worse than none.
    let show_sessions = model.sidebar && area.width >= 70;
    let show_tasks = model.has_active_tasks() && area.width >= 90;
    let mut constraints = Vec::new();
    if show_sessions {
        constraints.push(Constraint::Length(26));
    }
    constraints.push(Constraint::Min(0));
    if show_tasks {
        constraints.push(Constraint::Length(32));
    }
    let body = Layout::horizontal(constraints).split(rows[1]);
    let mut at = 0;
    if show_sessions {
        draw_sessions(frame, body[at], model, &mut hits);
        at += 1;
    }
    let page = body[at];
    at += 1;
    if model.is_blank() {
        hits.transcript = page;
        draw_welcome(frame, page, model);
    } else {
        draw_transcript(frame, page, model, rendered, &mut hits);
    }
    if show_tasks {
        draw_tasks(frame, body[at], model, &mut hits);
    }

    draw_input(frame, rows[2], model, &mut hits);
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
    // THE NAME, always. A client that never says what it is leaves a person
    // with a terminal full of somebody's transcript and no way to tell whose.
    let mut spans: Vec<Span> = vec![
        Span::styled(" viva ", Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
        Span::styled("│", Style::default().fg(BORDER)),
    ];
    let mut column = area.x + 7;
    for (index, id) in model.tabs.iter().enumerate() {
        // The session's state rides on its tab, so `working` is visible
        // without a column for it: a mark before the name, or nothing.
        let state = model.sessions.iter().find(|s| &s.id == id).map(|s| s.state.as_str());
        let (mark, mark_colour) = state.map(state_mark).unwrap_or(("", BORDER));
        let lead = if mark.is_empty() || mark == "-" { String::new() } else { format!("{mark} ") };
        let text = format!(" {lead}{} ", model.tab_label(id));
        let width = text.chars().count() as u16;
        let style = if index == model.tab {
            Style::default().fg(Color::Indexed(232)).bg(ACCENT).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(DIM)
        };
        hits.tabs.push((index, Rect::new(column, area.y, width, 1)));
        if index == model.tab || lead.is_empty() {
            spans.push(Span::styled(text, style));
        } else {
            spans.push(Span::styled(" ".to_string(), style));
            spans.push(Span::styled(lead.clone(), Style::default().fg(mark_colour)));
            spans.push(Span::styled(format!("{} ", model.tab_label(id)), style));
        }
        column += width;
        spans.push(Span::styled("│", Style::default().fg(BORDER)));
        column += 1;
    }
    // `+` is a target, reported like any tab. Drawn and not reported was the
    // Lisp client's bug: clicking it did nothing and looked broken.
    hits.new_tab = Some(Rect::new(column, area.y, 3, 1));
    spans.push(Span::styled(" + ", Style::default().fg(DIM)));
    frame.render_widget(Paragraph::new(Line::from(spans)), area);

    // How many sessions are running, at the right: the sessions a person has
    // not opened a tab on are otherwise invisible until they look for them.
    let running = model.sessions.len();
    let working = model.sessions.iter().filter(|s| s.state == "working").count();
    let summary = match (running, working) {
        (0, _) => String::new(),
        (n, 0) => format!("{n} session{}  ctrl-b ", if n == 1 { "" } else { "s" }),
        (n, w) => format!("{n} session{}, {w} working  ctrl-b ", if n == 1 { "" } else { "s" }),
    };
    let width = summary.chars().count() as u16;
    if width > 0 && width + column + 4 < area.x + area.width {
        let right = Rect::new(area.x + area.width - width, area.y, width, 1);
        frame.render_widget(
            Paragraph::new(Span::styled(summary, Style::default().fg(DIM))), right);
    }
}

fn draw_sessions(frame: &mut Frame, area: Rect, model: &Model, hits: &mut Hitboxes) {
    let focused = model.focus == Focus::Sessions;
    // A column with an edge, not a box. The edge is where it meets the page.
    let block = Block::default()
        .borders(Borders::RIGHT)
        .border_style(Style::default().fg(if focused { ACCENT } else { BORDER }))
        .title(Span::styled(" sessions ", Style::default().fg(if focused { ACCENT } else { DIM })))
        .padding(Padding::horizontal(1));
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
            // WHAT IT IS ABOUT, and where it is only when nothing was asked
            // yet. Four sessions in one directory were four identical rows.
            Span::styled(
                session.subject().to_string(),
                if current {
                    Style::default().fg(Color::Indexed(252)).add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                },
            ),
        ]));
        // One row each. The state is its mark; the word is only said for a
        // state that needs one, so an idle list is a list of names.
        if session.state != "idle" && !session.state.is_empty() {
            let last = lines.len() - 1;
            lines[last].spans.push(Span::styled(format!("  {}", session.state),
                                                Style::default().fg(DIM)));
        }
        let row = inner.y + index as u16;
        if row < inner.y + inner.height {
            hits.session_rows.push((index, Rect::new(inner.x, row, inner.width, 1)));
        }
    }
    if lines.is_empty() {
        lines.push(Line::from(Span::styled("no sessions", Style::default().fg(DIM))));
    }
    // No wrap: one row per session, so the row a click lands on is the
    // session it names. A subject too long for the column is cut by the pane.
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
/// The rows ONE entry needs.
///
/// One entry at a time, because a token changes one entry and re-wrapping the
/// whole conversation for it costs the length of the conversation. Measured
/// before this: one streamed token cost 6.5ms at ten turns and 70.8ms at four
/// hundred, so a long session got slower at exactly the moment somebody was
/// watching output arrive.
fn entry_lines(entry: &Entry, expanded: bool, width: u16) -> Vec<Hanging> {
    // How many lines of a tool result to show when it is not expanded. Three
    // is enough to see what a command said and not enough to bury the
    // conversation it belongs to.
    const GLIMPSE: usize = 3;
    let mut lines: Vec<Hanging> = Vec::new();
    {
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
                // What the model wrote is markdown, and drawn as characters it
                // shows its own punctuation. The indent comes back with it so
                // a list item's second row sits under its text, not its bullet.
                for drawn in markdown::render(text) {
                    lines.push(Hanging::under(drawn.indent, Style::default(),
                                              Line::from(drawn.spans)));
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
                // A TITLED RULE, so a call and what it printed read as one
                // block with a top edge, and the time it took has a place.
                //
                // A DELEGATE IS NOT A COMMAND. It is a whole agent, and drawn
                // like `ls` a person cannot count them: asking for two workers
                // and getting one looked the same as asking for two and
                // getting two. It says `worker`, in its own colour, and the
                // calls it makes are drawn inside it.
                let rule = Style::default().fg(BORDER);
                let worker = entry.tool == "delegate";
                let lead = "  ".repeat(entry.depth as usize);
                let mut title = vec![Span::styled(format!("{lead}─ "), rule)];
                title.push(Span::styled(format!("{} ", entry.outcome.mark()),
                                        Style::default().fg(colour)));
                if worker {
                    title.push(Span::styled("worker ", Style::default().fg(ACCENT)
                                            .add_modifier(Modifier::BOLD)));
                    let task = text.strip_prefix("delegate ").unwrap_or(text);
                    title.push(Span::styled(task.to_string(), Style::default().fg(Color::Indexed(252))));
                } else {
                    title.push(Span::styled(text.to_string(), Style::default().fg(Color::Indexed(252))));
                }
                // Under ten milliseconds is not shown. A replayed session
                // delivers a call and its result in the same instant, and a
                // `(0ms)` there would be a measurement of the replay.
                if let Some(took) = entry.took.filter(|took| took.as_millis() >= 10) {
                    title.push(Span::styled(format!("  ({})", elapsed(took)),
                                            Style::default().fg(DIM)));
                }
                let used: usize = title.iter().map(|span| span.content.chars().count()).sum();
                if used + 2 < width as usize {
                    title.push(Span::styled(
                        format!(" {}", "─".repeat(width as usize - used - 1)), rule));
                }
                lines.push(Hanging::plain(Line::from(title)));
                let shown = if expanded {
                    entry.output.len()
                } else {
                    entry.output.len().min(GLIMPSE)
                };
                let gutter = Style::default().fg(if worker { ACCENT } else { BORDER });
                let rail = format!("{lead}  │ ");
                for line in entry.output.iter().take(shown) {
                    lines.push(Hanging::under(rail.clone(), gutter, Line::from(vec![
                        Span::styled(rail.clone(), gutter),
                        Span::styled(line.clone(), Style::default().fg(DIM)),
                    ])));
                }
                // The hidden lines are ANNOUNCED. Silently showing three of
                // four hundred teaches a person the command printed three.
                if entry.output.len() > shown {
                    lines.push(Hanging::plain(Line::from(Span::styled(
                        format!("{rail}… {} more line{}  (ctrl-o)",
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

/// The page before anything has been said on it.
///
/// A blank page is a claim -- that nothing is here -- and on a fresh session
/// it is the moment a person most needs to know what is: which model will
/// answer, what this directory has already retained, what was said here
/// before, and which keys do what. Gone the moment the first event arrives.
fn draw_welcome(frame: &mut Frame, area: Rect, model: &Model) {
    let block = Block::default().padding(Padding::new(2, 2, 1, 1));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 30 || inner.height < 6 {
        return;
    }
    let heading = Style::default().fg(ACCENT).add_modifier(Modifier::BOLD);
    let key = Style::default().fg(Color::Indexed(252));
    let dim = Style::default().fg(DIM);

    let mut left: Vec<Line> = vec![
        Line::from(Span::styled("viva", heading)),
        Line::from(""),
        Line::from(Span::styled("this session", heading)),
    ];
    let session = model.sessions.iter().find(|s| s.id == model.current);
    match session {
        Some(session) => {
            left.push(Line::from(vec![Span::styled("model    ", dim), Span::raw(session.model.clone())]));
            if !session.effort.is_empty() {
                left.push(Line::from(vec![Span::styled("effort   ", dim), Span::raw(session.effort.clone())]));
            }
            left.push(Line::from(vec![Span::styled("in       ", dim), Span::raw(session.short_label().to_string())]));
        }
        None => left.push(Line::from(Span::styled("starting a session…", dim))),
    }
    left.push(Line::from(""));
    left.push(Line::from(Span::styled("learned here", heading)));
    let learned = &model.learned;
    if learned.inspected {
        let count = |n: usize, word: &str| format!("{n} {word}{}", if n == 1 { "" } else { "s" });
        left.push(Line::from(Span::raw(format!("{} · {} · {}",
            count(learned.notes.len(), "note"),
            count(learned.skills.len(), "skill"),
            count(learned.tools.len(), "tool")))));
        for name in learned.skills.iter().chain(learned.tools.iter()).map(|r| r.name.as_str()).take(4) {
            left.push(Line::from(Span::styled(format!("  {name}"), dim)));
        }
    } else {
        left.push(Line::from(Span::styled("nothing yet", dim)));
    }

    let mut right: Vec<Line> = vec![Line::from(Span::styled("keys", heading))];
    for (k, what) in [
        ("ctrl-p", "find any session, running or not"),
        ("ctrl-n", "start a session in a new tab"),
        ("ctrl-b", "show the running sessions"),
        ("ctrl-o", "all of a tool's output"),
        ("/", "the commands"),
    ] {
        right.push(Line::from(vec![Span::styled(format!("{k:<8}"), key), Span::styled(what, dim)]));
    }
    right.push(Line::from(""));
    // NAMED FOR WHAT THEY ARE. `recent here` beside a left column saying no
    // session was open read as a list of messages -- and the two columns
    // looked like they disagreed, when one was about what is RUNNING and the
    // other about what is RECORDED.
    right.push(Line::from(Span::styled("earlier sessions here", heading)));
    if model.recent.is_empty() {
        right.push(Line::from(Span::styled("none recorded in this directory", dim)));
    } else {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        for recorded in model.recent.iter().filter(|r| r.messages > 0).take(5) {
            let opening: String = recorded.opening.chars().take(40).collect();
            right.push(Line::from(vec![
                Span::styled("· ", dim),
                Span::raw(opening),
                Span::styled(format!("  {} msgs, {} ago", recorded.messages, recorded.age(now)), dim),
            ]));
        }
    }
    right.push(Line::from(Span::styled("ctrl-p to continue one", dim)));
    right.push(Line::from(""));
    right.push(Line::from(Span::styled("nothing said here yet — ask something", dim)));

    // Two columns when they fit, one under the other when they do not.
    if inner.width >= 78 {
        // A gap between them, and the left column wraps: without either, a
        // line one character too long ran straight into the right column.
        let columns = Layout::horizontal([
            Constraint::Length(30),
            Constraint::Length(4),
            Constraint::Min(0),
        ])
        .split(inner);
        frame.render_widget(Paragraph::new(left).wrap(Wrap { trim: false }), columns[0]);
        frame.render_widget(Paragraph::new(right).wrap(Wrap { trim: false }), columns[2]);
    } else {
        let mut all = left;
        all.push(Line::from(""));
        all.extend(right);
        frame.render_widget(Paragraph::new(all).wrap(Wrap { trim: false }), inner);
    }
}

/// A duration as a person reads one: `838ms`, `2.3s`, `1m04s`.
fn elapsed(took: std::time::Duration) -> String {
    let millis = took.as_millis();
    if millis < 1000 {
        format!("{millis}ms")
    } else if millis < 60_000 {
        format!("{:.1}s", took.as_secs_f64())
    } else {
        format!("{}m{:02}s", took.as_secs() / 60, took.as_secs() % 60)
    }
}

fn draw_transcript(
    frame: &mut Frame,
    area: Rect,
    model: &Model,
    rendered: &mut Rendered,
    hits: &mut Hitboxes,
) {
    // No box and no title: the tab already names the session, and a frame
    // around the page is a frame around the only thing on screen. One row of
    // air at the foot, so the last thing said does not sit on the prompt.
    let block = Block::default().padding(Padding::new(1, 1, 0, 1));
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
    let block = Block::default()
        .borders(Borders::LEFT)
        .border_style(Style::default().fg(BORDER))
        .title(Span::styled(" running ", Style::default().fg(DIM)))
        .padding(Padding::horizontal(1));
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
    // THE STATUS IS THE TOP EDGE. A separate row under the box said the same
    // things one line lower and cost that line on every screen; the edge of
    // the box was already being drawn and said nothing.
    let (facts, notes) = status_text(model);
    let edge = Style::default().fg(if model.focus == Focus::Input { ACCENT } else { BORDER });
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(edge);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    hits.input = inner;
    // The edge is written by hand, so what does not fit is DECIDED rather
    // than clipped: the facts first, then the notes in the order they matter,
    // and the learned counts are the first to go. Left to the widget, a
    // wide status pushed `scrolled -- End to follow` off the screen while
    // the counts stayed.
    let top = Rect::new(area.x + 1, area.y, area.width.saturating_sub(2), 1);
    // THE FACTS YIELD FIRST. A lost connection must not be the thing that
    // does: with a provider-prefixed model, a branch and a context reading,
    // the row filled up and `reconnecting` was the piece dropped -- so the
    // one moment the line had something urgent to say was the one moment it
    // could not. Room for the first note is taken before the facts are laid
    // out, and facts come off the right until it fits.
    let mut shown: Vec<String> = facts.clone();
    let reserved = notes
        .first()
        .map(|(_, short)| short.chars().count() + 3)
        .unwrap_or(0);
    while shown.len() > 1
        && shown.join("  ›  ").chars().count() + reserved + 2 > top.width as usize
    {
        shown.pop();
    }
    let left = format!(" {} ", shown.join("  ›  "));
    let mut kept: Vec<String> = Vec::new();
    let mut room = (top.width as usize).saturating_sub(left.chars().count() + 2);
    for (long, short) in &notes {
        // The long form, the short form, or nothing -- and nothing after it.
        let gap = if kept.is_empty() { 2 } else { 3 };
        let chosen = [long, short]
            .into_iter()
            .find(|form| !form.is_empty() && form.chars().count() + gap <= room);
        match chosen {
            Some(form) => {
                room -= form.chars().count() + gap;
                kept.push(form.clone());
            }
            None => break,
        }
    }
    let right = if kept.is_empty() { String::new() } else { format!(" {} ", kept.join("   ")) };
    let fill = (top.width as usize)
        .saturating_sub(left.chars().count() + right.chars().count());
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(left, Style::default().fg(DIM)),
            Span::styled("─".repeat(fill), edge),
            Span::styled(right, Style::default().fg(DIM)),
        ])),
        top,
    );
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

/// What the input's top edge says: the facts on the left, and on the right
/// whatever is unusual right now, most important first. Each note has a
/// short form for when the long one does not fit beside long facts -- a
/// provider-prefixed model and a branch with a slash in it leave a quarter
/// of a hundred-column screen for everything else.
fn status_text(model: &Model) -> (Vec<String>, Vec<(String, String)>) {
    let following = model
        .current_conversation()
        .map(|conversation| conversation.following)
        .unwrap_or(true);
    let facts = crate::status::facts(model);
    let mut notes: Vec<(String, String)> = Vec::new();
    let note = |long: &str, short: &str| (long.to_string(), short.to_string());
    // The status carries what went wrong -- a closed connection, a refused
    // request -- so it is never replaced by the facts.
    if !model.status.is_empty() {
        notes.push(note(&model.status, &model.status));
    }
    if !model.connected {
        notes.push(note("daemon gone", "daemon gone"));
    }
    if model.current_conversation().map(|c| c.gap).unwrap_or(false) {
        notes.push(note("missed events — ctrl-r to re-read", "missed events"));
    }
    if !following {
        notes.push(note("scrolled — End to follow", "scrolled"));
    }
    if model.current_conversation().map(|c| c.expanded).unwrap_or(false) {
        notes.push(note("tool output expanded — ctrl-o", "expanded"));
    }
    // ALWAYS the counts, once asked. A harness whose point is that it learns
    // should say what it has learned without being asked, and a fresh project
    // retaining nothing is exactly when somebody most needs to learn that it
    // retains -- so zero is shown, not hidden.
    let learned = &model.learned;
    if learned.inspected {
        notes.push((
            format!(
                "learned {} note{} · {} skill{} · {} tool{}",
                learned.notes.len(), if learned.notes.len() == 1 { "" } else { "s" },
                learned.skills.len(), if learned.skills.len() == 1 { "" } else { "s" },
                learned.tools.len(), if learned.tools.len() == 1 { "" } else { "s" },
            ),
            format!("learned {}·{}·{}",
                    learned.notes.len(), learned.skills.len(), learned.tools.len()),
        ));
        if !learned.refused.is_empty() {
            notes.push(note(&format!("{} refused — untrusted", learned.refused.len()),
                            &format!("{} refused", learned.refused.len())));
        }
    }
    (facts, notes)
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
        model.sidebar = true;
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
        // The page rows: below the tab bar, above the input box.
        let cells: Vec<String> = rows[1..rows.len() - 3].to_vec();
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
    fn a_word_is_not_cut_in_half_where_its_styling_changes() {
        // `react-dom` written half as code and half as prose is one word in
        // two spans. A wrapper that breaks each span on its own cuts it at the
        // seam, which shows only once something is styling the text.
        let mut model = ready(&[]);
        let filler = "word ".repeat(9);
        model.absorb(&event("model.delta",
                            json!({"text": format!("{filler}`react`-dom ends it\n")})));
        let rows = frame_of(&model, 100, 26);
        let joined = rows[1..rows.len() - 3].join("\n");
        assert!(joined.contains("react-dom"), "the word was cut in half:\n{joined}");
    }

    #[test]
    fn the_status_line_says_what_is_answering_and_how_full_it_is() {
        // These are true at every moment, so they are shown at every moment.
        // A hint about which key switches tabs is worth saying once; which
        // model is answering and how close its context is to its limit are
        // worth a permanent place.
        let mut model = ready(&[]);
        if let Some(session) = model.sessions.first_mut() {
            session.model = "deepseek-4-flash".into();
            session.effort = "high".into();
            session.tokens = 32_000;
            session.limit = 128_000;
        }
        let frame = frame_of(&model, 120, 26).join("\n");
        assert!(frame.contains("deepseek-4-flash"), "the model is not on screen");
        assert!(frame.contains("high"), "the effort is not on screen");
        assert!(frame.contains("25% of 128k"), "the context is not on screen:\n{frame}");
    }

    #[test]
    fn the_status_line_keeps_saying_what_went_wrong() {
        // The facts share the line with the status, they do not replace it: a
        // closed connection and a refused request are reported there, and a
        // line that showed only the facts would report neither.
        let mut model = ready(&[]);
        model.status = "the daemon closed the connection".into();
        let frame = frame_of(&model, 120, 26).join("\n");
        assert!(frame.contains("the daemon closed the connection"),
                "the failure is not on screen:\n{frame}");
        assert!(frame.contains("alpha"), "the facts went missing with it");
    }

    #[test]
    fn a_call_says_how_long_it_took_and_a_replayed_one_does_not() {
        // The difference between a 40ms grep and an 800ms one is worth a
        // glance; a replayed session delivers a call and its result in the
        // same instant, and a `(0ms)` there would measure the replay.
        let mut model = ready(&[]);
        model.absorb(&event("tool.started",
                            json!({"call": {"id": "c1", "name": "bash",
                                            "arguments": {"command": "sleep"}}})));
        std::thread::sleep(std::time::Duration::from_millis(30));
        model.absorb(&event("tool.completed", json!({"call": {"id": "c1"}, "output": "done"})));
        model.absorb(&event("tool.started",
                            json!({"call": {"id": "c2", "name": "ls", "arguments": {}}})));
        model.absorb(&event("tool.completed", json!({"call": {"id": "c2"}, "output": "x"})));
        let rows = frame_of(&model, 100, 26);
        let slept = rows.iter().find(|row| row.contains("bash sleep")).unwrap();
        assert!(slept.contains("ms)"), "the slow call shows no time: {slept:?}");
        assert!(slept.contains("─"), "the call is not drawn as a titled rule: {slept:?}");
        let quick = rows.iter().find(|row| row.contains("✔ ls")).unwrap();
        assert!(!quick.contains("ms)"), "an instant call shows a time: {quick:?}");
        assert_eq!(elapsed(std::time::Duration::from_millis(838)), "838ms");
        assert_eq!(elapsed(std::time::Duration::from_millis(2300)), "2.3s");
        assert_eq!(elapsed(std::time::Duration::from_secs(64)), "1m04s");
    }

    #[test]
    fn what_does_not_fit_on_the_edge_is_decided_not_clipped() {
        // A wide status pushed `scrolled -- End to follow` off the screen
        // while the learned counts stayed. The notes yield in order of
        // importance, and the counts are the first to go.
        let mut model = ready(&[]);
        for index in 0..60 {
            model.absorb(&event("model.delta", json!({"text": format!("line{index}\n")})));
        }
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.following = false;
            conversation.scroll = 10;
        }
        model.learned.inspected = true;
        if let Some(session) = model.sessions.first_mut() {
            session.model = "a-model-with-a-very-long-name-indeed".into();
            session.effort = "high".into();
        }
        let rows = frame_of(&model, 84, 20);
        let edge = &rows[rows.len() - 3];
        assert!(edge.contains("scrolled"), "the scroll note was clipped: {edge:?}");
        assert!(!edge.contains("learned"), "the counts outranked the scroll note: {edge:?}");
        let wide = frame_of(&model, 160, 20);
        assert!(wide[wide.len() - 3].contains("learned"), "the counts never fit at all");
    }

    #[test]
    fn a_lost_connection_is_never_what_yields() {
        // With a provider-prefixed model, a branch and a context reading, the
        // row filled up and `reconnecting` was the piece dropped -- so the one
        // moment the line had something urgent to say was the one moment it
        // could not. The facts come off instead.
        let mut model = ready(&[]);
        model.connected = false;
        model.status = "connection lost — reconnecting".into();
        if let Some(session) = model.sessions.first_mut() {
            session.model = "openai/a-very-long-provider-prefixed-model".into();
            session.effort = "high".into();
            session.tokens = 1_280;
            session.limit = 128_000;
        }
        let edge = frame_of(&model, 96, 16);
        let row = &edge[edge.len() - 3];
        assert!(row.contains("reconnecting"), "the lost connection was dropped: {row:?}");
        // The model is the last fact to go, since it says what is answering.
        assert!(row.contains("openai/a-very-long"), "the facts went entirely: {row:?}");
    }

    #[test]
    fn two_workers_are_two_things_on_screen_and_their_calls_sit_inside_them() {
        // Asking for two workers and getting one looked exactly like asking
        // for two and getting two: a delegate was drawn like `ls`, and the
        // tools its worker ran sat level with the delegate's own call.
        let mut model = ready(&[]);
        for (id, task) in [("d1", "design the architecture"), ("d2", "look for bugs")] {
            model.absorb(&event("tool.started", json!({
                "call": {"id": id, "name": "delegate", "arguments": {"task": task}}})));
        }
        // The worker's own call names the worker that made it, which is how
        // the client knows whose it is with two of them running.
        model.absorb(&event("tool.started", json!({
            "call": {"id": "r1", "name": "read", "arguments": {"path": "main.rs"}},
            "lane": "lane-1"})));
        model.absorb(&event("tool.completed", json!({"call": {"id": "r1"}, "output": "fn main"})));
        // A call on the session's own lane is inside nothing.
        model.absorb(&event("tool.started", json!({
            "call": {"id": "t1", "name": "ls", "arguments": {}}})));
        let rows = frame_of(&model, 110, 26);
        let workers: Vec<&String> = rows.iter().filter(|row| row.contains("worker")).collect();
        assert_eq!(workers.len(), 2, "two workers did not read as two: {rows:?}");
        assert!(workers[0].contains("design the architecture"));
        assert!(workers[1].contains("look for bugs"));
        // The worker's own call is drawn inside the workers that are running.
        let inner = rows.iter().find(|row| row.contains("read main.rs")).unwrap();
        let first = workers[0].find('─').unwrap();
        assert!(inner.find('─').unwrap() > first,
                "the worker's call is not inside it: {inner:?}");
        // The workers themselves stay side by side. A tool event carries no
        // parent, so nesting one worker inside another is a claim the client
        // cannot support -- and two from one batch are siblings.
        assert_eq!(workers[0].find('─'), workers[1].find('─'),
                   "one worker was drawn inside the other:\n{}\n{}", workers[0], workers[1]);
        let own = rows.iter().find(|row| row.contains("✔ ls") || row.contains("· ls")).unwrap();
        assert_eq!(own.find('─'), workers[0].find('─'),
                   "a call on the session's own lane was drawn inside a worker: {own:?}");
    }

    #[test]
    fn the_page_does_not_sit_on_the_prompt_and_the_client_says_its_name() {
        let model = ready(&[("model.delta", "the last thing said\n")]);
        let rows = frame_of(&model, 100, 16);
        assert!(rows[0].contains("viva"), "the client never says what it is: {:?}", rows[0]);
        // Row -3 is the input box's top edge; -4 must be air, not the text.
        let air = &rows[rows.len() - 4];
        assert!(air.trim().is_empty(), "the transcript sits on the prompt: {air:?}");
        assert!(rows.iter().any(|row| row.contains("the last thing said")),
                "the air cost the last line");
    }

    #[test]
    fn a_session_is_listed_by_what_it_is_about() {
        // Four sessions in one directory were four identical rows: the name
        // of the directory says where a session is, not which one it is.
        let mut model = ready(&[]);
        model.sidebar = true;
        if let Some(session) = model.sessions.first_mut() {
            session.opening = "why does the picker lose its filter".into();
        }
        let rows = frame_of(&model, 110, 16);
        let listed = rows[1..]
            .iter()
            .find(|row| row.contains("why does the picker"))
            .unwrap_or_else(|| panic!("the sidebar does not say what the session is about"));
        assert!(listed.contains('>'), "the current session lost its marker: {listed:?}");
        // A session nothing has been asked in falls back to where it is.
        assert!(rows[1..].iter().any(|row| row.contains("beta")),
                "a session with no question is not listed by its directory");
    }

    #[test]
    fn the_welcome_columns_do_not_run_into_each_other() {
        // A line one character longer than its column ran straight into the
        // one beside it, and read as two sentences spliced together.
        let mut model = ready(&[]);
        model.sessions.clear();
        model.current.clear();
        let rows = frame_of(&model, 100, 20);
        let left_edge = rows
            .iter()
            .find(|row| row.contains("keys"))
            .and_then(|row| row.find("keys"))
            .expect("the welcome has no key list");
        for row in &rows {
            for phrase in ["starting a session", "learned here", "this session"] {
                if let Some(at) = row.find(phrase) {
                    assert!(at + phrase.len() < left_edge,
                            "the left column runs into the right: {row:?}");
                }
            }
        }
    }

    #[test]
    fn the_welcome_says_which_column_is_running_and_which_is_recorded() {
        // `recent here` beside a left column saying no session was open read
        // as a list of messages, and the two columns looked like they
        // disagreed -- when one is about what is RUNNING and the other about
        // what is RECORDED.
        let mut model = ready(&[]);
        model.recent = vec![crate::protocol::Recorded {
            id: "r1".into(),
            messages: 12,
            opening: "why does the picker lose its filter".into(),
            ..Default::default()
        }];
        let frame = frame_of(&model, 110, 22).join("\n");
        assert!(frame.contains("this session"), "the left column names nothing");
        assert!(frame.contains("earlier sessions here"),
                "the recorded list does not say it is sessions:\n{frame}");
        assert!(frame.contains("why does the picker"), "the recorded list is empty");
    }

    #[test]
    fn a_narrow_pane_keeps_the_talk_and_drops_the_rest() {
        // Where this lives is a split, not a hundred-column window. Side panes
        // that squeeze the transcript to nothing are worse than none.
        let mut model = ready(&[("model.delta", "still readable\n")]);
        model.absorb(&event("task.started", json!({"task": "t1", "text": "indexing"})));
        let wide = frame_of(&model, 120, 16).join("\n");
        let narrow = frame_of(&model, 50, 16).join("\n");
        assert!(wide.contains("running"), "the wide frame has no task column");
        assert!(narrow.contains("still readable"), "the narrow frame lost the transcript");
        assert!(!narrow.contains("running"), "the task column survived into 50 columns");
    }

    #[test]
    fn the_current_session_is_marked_by_a_character_not_only_a_colour() {
        let mut model = ready(&[]);
        model.sidebar = true;
        let frame = frame_of(&model, 100, 16);
        // The row INSIDE the sidebar. The tab bar carries the same name and
        // comes first, so the obvious `find` picks it and asserts about the
        // wrong row -- which is a test that passes or fails for reasons
        // unrelated to what it claims to check. Below the tab bar, by position.
        let row = frame[1..]
            .iter()
            .find(|line| line.contains("alpha"))
            .expect("the sidebar has no row for the current session");
        assert!(row.contains('>'), "the current session's row carries no marker: {row:?}");
        assert!(row.contains('*'), "the working session shows no state mark: {row:?}");
        // Without the sidebar, the tab itself says the session is working.
        model.sidebar = false;
        let tabs = frame_of(&model, 100, 16)[0].clone();
        assert!(tabs.contains("* alpha"), "the tab does not carry the state: {tabs:?}");
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
