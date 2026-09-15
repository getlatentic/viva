//! Drawing the model.
//!
//! ratatui does here what src/tui/screen.lisp did by hand: two buffers, a
//! diff, and only the changed cells on the wire. That part is not novel and
//! is not ours -- what is ours is above it, and this file is only the
//! arrangement.

use crate::cells;
use crate::layout::Rendered;
use crate::markdown;
use crate::model::{Entry, Focus, Model, Models, Outcome, Role, TaskState};
use crate::theme::{state_mark, ACCENT, BORDER, DIM};
use crate::wrap::Hanging;
use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Clear, Padding, Paragraph, Wrap};

/// Where each thing was drawn, so a click can be answered without a second
/// calculation of the same layout. Two functions deriving it independently is
/// how a tab bar selects the tab next to the one that was clicked.
#[derive(Debug, Default, Clone)]
pub struct Hitboxes {
    pub tabs: Vec<(usize, Rect)>,
    pub new_tab: Option<Rect>,
    pub sessions: Rect,
    pub session_rows: Vec<(String, Rect)>,
    pub transcript: Rect,
    pub tasks: Rect,
    pub input: Rect,
    pub picker: Option<Rect>,
    pub picker_rows: Vec<(usize, Rect)>,
    pub command_rows: Vec<(usize, Rect)>,
}

pub fn draw(frame: &mut Frame, model: &mut Model, rendered: &mut Rendered) -> Hitboxes {
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
        constraints.push(Constraint::Length(30));
    }
    constraints.push(Constraint::Min(0));
    if show_tasks {
        constraints.push(Constraint::Length(32));
    }
    let body = Layout::horizontal(constraints).split(rows[1]);
    let mut at = 0;
    if show_sessions {
        let column = crate::sidebar::draw(frame, body[at], model);
        hits.sessions = column.area;
        hits.session_rows = column.rows;
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
    } else if model.focus == Focus::Models {
        draw_models(frame, area, model);
    } else if model.focus == Focus::Deleting {
        draw_deleting(frame, area, model);
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
        Paragraph::new(vec![
            Line::from(vec![
                Span::styled("search ", Style::default().fg(DIM)),
                Span::styled(
                    model.picker.query.clone(),
                    Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
                ),
                Span::styled("_", Style::default().fg(ACCENT)),
            ]),
            Line::from(Span::styled("enter resumes · ctrl-d deletes · esc closes", Style::default().fg(DIM))),
        ]),
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
        let opening = cells::cut(&found.opening, 48).to_string();
        lines.push(Line::from(vec![
            Span::styled(cells::pad(&found.short_cwd(), 10), style.fg(if chosen {
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

/// Whether to delete a session, asked by what it is about. Its own box and its
/// own colour, so the question is not read as the list it was asked from.
fn draw_deleting(frame: &mut Frame, area: Rect, model: &Model) {
    let Some(deletion) = &model.deleting else {
        return;
    };
    let warning = Color::Indexed(203);
    let width = area.width.saturating_sub(8).min(64).max(24);
    let height = 6.min(area.height);
    let box_area = Rect::new(
        area.x + area.width.saturating_sub(width) / 2,
        area.y + area.height.saturating_sub(height) / 2,
        width,
        height,
    );
    frame.render_widget(Clear, box_area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(warning))
        .title(Span::styled(" delete this session? ", Style::default().fg(warning).add_modifier(Modifier::BOLD)))
        .padding(Padding::horizontal(1));
    let inner = block.inner(box_area);
    frame.render_widget(block, box_area);
    let subject = cells::clip(&deletion.subject, inner.width as usize);
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(subject, Style::default().fg(Color::Indexed(252)).add_modifier(Modifier::BOLD))),
            Line::from(Span::styled("its transcript and journal are removed for good", Style::default().fg(DIM))),
            Line::from(""),
            Line::from(vec![
                Span::styled("enter", Style::default().fg(warning).add_modifier(Modifier::BOLD)),
                Span::styled(" deletes · ", Style::default().fg(DIM)),
                Span::styled("esc", Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
                Span::styled(" keeps it", Style::default().fg(DIM)),
            ]),
        ]),
        inner,
    );
}

/// The models on offer, over everything else.
///
/// A BOUNDED WINDOW with a count above and below it, rather than a list that
/// stops wherever the box happens to end. Every row carries the number that
/// takes it, the label you would type, and the id that reaches the provider --
/// and the one already answering here says so, because a marker only its author
/// can read is not an answer.
fn draw_models(frame: &mut Frame, area: Rect, model: &Model) {
    let width = area.width.saturating_sub(8).min(86).max(24);
    let height = (Models::VISIBLE as u16 + 7).min(area.height.saturating_sub(4)).max(8);
    let box_area = Rect::new(
        area.x + (area.width.saturating_sub(width)) / 2,
        area.y + (area.height.saturating_sub(height)) / 2,
        width,
        height,
    );
    frame.render_widget(Clear, box_area);
    let block = pane("which model answers", true);
    let inner = block.inner(box_area);
    frame.render_widget(block, box_area);

    let rows = Layout::vertical([
        Constraint::Length(2),
        Constraint::Min(1),
        Constraint::Length(2),
    ])
    .split(inner);

    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("search ", Style::default().fg(DIM)),
            Span::styled(
                model.models.query.clone(),
                Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
            ),
            Span::styled("_", Style::default().fg(ACCENT)),
        ])),
        rows[0],
    );

    let here = model
        .sessions
        .iter()
        .find(|session| session.id == model.current)
        .map(|session| session.model.clone())
        .unwrap_or_default();
    let next = model
        .current_conversation()
        .and_then(|conversation| conversation.pending_model.clone());
    let matching = model.models.matching();
    let start = model.models.first_visible();
    let mut lines: Vec<Line> = Vec::new();
    if start > 0 {
        lines.push(Line::from(Span::styled(
            format!("  ↑ {start} more"),
            Style::default().fg(DIM),
        )));
    }
    for (offset, offer) in matching.iter().skip(start).take(Models::VISIBLE).enumerate() {
        let index = start + offset;
        let chosen = index == model.models.selection;
        let label = Style::default()
            .fg(if chosen { ACCENT } else { Color::Indexed(252) })
            .add_modifier(if chosen { Modifier::BOLD } else { Modifier::empty() });
        let mut spans = vec![
            Span::styled(format!(" ({}) ", offset + 1), Style::default().fg(DIM)),
            Span::styled(cells::pad(&cells::clip(&offer.label, 34), 34), label),
            Span::styled(format!(" {}", cells::clip(&offer.id, 30)), Style::default().fg(DIM)),
        ];
        // THE ONE ALREADY ANSWERING, said in words. A session records the model
        // id, so that is what matches -- the label it was chosen by is not
        // written down anywhere.
        if !here.is_empty() && offer.id == here {
            spans.push(Span::styled("  (current)", Style::default().fg(ACCENT)));
        }
        if next.as_deref().is_some_and(|next| next == offer.label || next == offer.id) {
            spans.push(Span::styled("  (next turn)", Style::default().fg(ACCENT)));
        }
        lines.push(Line::from(spans));
    }
    let shown = matching.len().saturating_sub(start).min(Models::VISIBLE);
    let below = matching.len().saturating_sub(start + shown);
    if below > 0 {
        lines.push(Line::from(Span::styled(
            format!("  ↓ {below} more"),
            Style::default().fg(DIM),
        )));
    }
    if matching.is_empty() {
        // `asking` and `no matches` and `nothing configured` are three answers,
        // and a picker that gives the wrong one teaches people it is broken.
        let message = if model.models.refreshing {
            "asking the providers…"
        } else if model.models.offers.is_empty() {
            "no model is configured — put a key in ~/.viva/auth.json"
        } else {
            "no matches"
        };
        lines.push(Line::from(Span::styled(message, Style::default().fg(DIM))));
    }
    frame.render_widget(Paragraph::new(lines), rows[1]);
    // What a choice does, said where it is made -- including its price: no model
    // holds a cache of a conversation it has never read.
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                " enter or a digit: this session, from its next turn · ctrl-n: a new session",
                Style::default().fg(DIM),
            )),
            Line::from(Span::styled(
                " that turn reads the whole conversation afresh · ctrl-r asks again · esc",
                Style::default().fg(DIM),
            )),
        ]),
        rows[2],
    );
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
        let width = cells::width(&text) as u16;
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
    let width = cells::width(&summary) as u16;
    if width > 0 && width + column + 4 < area.x + area.width {
        let right = Rect::new(area.x + area.width - width, area.y, width, 1);
        frame.render_widget(
            Paragraph::new(Span::styled(summary, Style::default().fg(DIM))), right);
    }
}

/// The transcript, with a visible difference between a question and an answer.
///
/// The difference is carried by a PREFIX as well as a colour. Colour alone is
/// invisible on a monochrome terminal, to anyone who cannot tell two shades
/// apart, and to any test that reads the frame back -- so the distinction that
/// matters most is the one that must not depend on it.
/// The lines ONE entry comes to, before they are wrapped to a width.
///
/// One entry at a time, because a token changes one entry and laying out the
/// whole conversation for it costs the length of the conversation.
fn entry_lines(
    entry: &Entry,
    expanded: bool,
    after: Option<Role>,
) -> Vec<Hanging> {
    // How many lines of a tool result to show when it is not expanded. Three
    // is enough to see what a command said and not enough to bury the
    // conversation it belongs to.
    const GLIMPSE: usize = 3;
    let mut lines: Vec<Hanging> = Vec::new();
    // A LINE OF AIR WHERE WORK MEETS WORDS. A call ran straight on from the
    // sentence above it and the next sentence ran straight on from its output,
    // so a block had no edge at either end and the whole page read as one
    // run. Between two calls there is none: each already opens with a titled
    // rule, and a blank between every one of five `ls` calls is worse.
    if let Some(before) = after {
        // Not around a question: it already opens and closes with a line of
        // its own, and adding one here gave it two on each side.
        let asked = matches!(before, Role::User | Role::Looped)
            || matches!(entry.role, Role::User | Role::Looped);
        if !asked && (before == Role::Tool) != (entry.role == Role::Tool) {
            lines.push(Hanging::plain(Line::from("")));
        }
    }
    {
        let text = entry.text.as_str();
        match entry.role {
            // One shape for both, and a different mark and weight for each: a
            // person's prompt is the bright `›`, a loop's own is a dim `↻`.
            // Same shape because it IS the same thing -- the next prompt --
            // and reading it takes the same eye movement either way.
            Role::User | Role::Looped => {
                let looped = entry.role == Role::Looped;
                let voice = if looped {
                    Style::default().fg(Color::Indexed(244))
                } else {
                    Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)
                };
                lines.push(Hanging::plain(Line::from("")));
                for (index, piece) in text.lines().enumerate() {
                    let prefix = match (index, looped) {
                        (0, true) => "↻ ",
                        (0, false) => "› ",
                        _ => "  ",
                    };
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
                // YOURS, AND THE MODEL CANNOT SEE IT. A bang line is published
                // for every attached client and never written to the
                // conversation, so it looked exactly like a call the agent had
                // made -- and asking the agent about what it printed got a
                // blank look.
                if entry.tool == "!" {
                    title.push(Span::styled("  not sent to the model",
                                            Style::default().fg(DIM)));
                }
                lines.push(Hanging::ruled(Line::from(title), rule));
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
        ("ctrl-b", "show or hide the sessions"),
        ("↑ ← →", "read back, cross to the sessions"),
        ("ctrl-o", "all of a tool's output"),
        ("/", "the commands"),
    ] {
        right.push(Line::from(vec![Span::styled(format!("{k:<8}"), key), Span::styled(what, dim)]));
    }
    right.push(Line::from(""));
    // NOT THE EARLIER SESSIONS. They are in the sessions column, beside this,
    // where they stay after the first thing is said -- listing them here as
    // well put the same list in two places and lost it the moment the page
    // filled up.
    right.push(Line::from(""));
    let earlier = model.recent.iter().filter(|recorded| recorded.messages > 0).count();
    right.push(Line::from(Span::styled(
        match earlier {
            0 => "nothing said here yet — ask something".to_string(),
            1 => "nothing said here yet — 1 earlier session beside this".to_string(),
            many => format!("nothing said here yet — {many} earlier sessions beside this"),
        },
        dim,
    )));

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
    model: &mut Model,
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

    rendered.refresh(model, inner.width, entry_lines);
    let total = rendered.total();
    let offset = model
        .conversations
        .get_mut(&model.current)
        .map(|conversation| conversation.window_top(total, inner.height))
        .unwrap_or(0);
    // No wrap here: it is already wrapped, and only the visible rows are sent.
    frame.render_widget(Paragraph::new(rendered.window(offset, inner.height)), inner);
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
    let section = |lines: &mut Vec<Line>, title: &str, items: &[crate::protocol::Retained],
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
                Span::styled(format!("  {}", cells::pad(&item.name, 22)), Style::default().fg(Color::Indexed(252))),
                Span::styled(cells::pad(&item.scope, 9), Style::default().fg(DIM)),
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
        .map(|(_, short)| cells::width(short) + 3)
        .unwrap_or(0);
    while shown.len() > 1
        && cells::width(&shown.join("  ›  ")) + reserved + 2 > top.width as usize
    {
        shown.pop();
    }
    let left = format!(" {} ", shown.join("  ›  "));
    let mut kept: Vec<String> = Vec::new();
    let mut room = (top.width as usize).saturating_sub(cells::width(&left) + 2);
    for (long, short) in &notes {
        // The long form, the short form, or nothing -- and nothing after it.
        let gap = if kept.is_empty() { 2 } else { 3 };
        let chosen = [long, short]
            .into_iter()
            .find(|form| !form.is_empty() && cells::width(form) + gap <= room);
        match chosen {
            Some(form) => {
                room -= cells::width(form) + gap;
                kept.push(form.clone());
            }
            None => break,
        }
    }
    let right = if kept.is_empty() { String::new() } else { format!(" {} ", kept.join("   ")) };
    let fill = (top.width as usize)
        .saturating_sub(cells::width(&left) + cells::width(&right));
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(left, Style::default().fg(DIM)),
            Span::styled("─".repeat(fill), edge),
            Span::styled(right, Style::default().fg(DIM)),
        ])),
        top,
    );
    let typed = one_line(&model.input);
    // The cursor sits after what was typed, not wherever the last write ended.
    // Screen readers follow it too.
    let column = (inner.x as usize + 2 + cells::width(&typed))
        .min((inner.x + inner.width).saturating_sub(1) as usize) as u16;
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("› ", Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
            Span::raw(typed),
        ])),
        inner,
    );
    frame.set_cursor_position((column, inner.y));
}

/// What typed or pasted text looks like on a single row.
///
/// The prompt is stored as it will be SENT, newlines and all, so a pasted
/// function reaches the model as a function. This row cannot lay those out, and
/// a raw newline in a span is a hole in the border -- so each one shows as a
/// glyph, one cell wide. A tab becomes the spaces it stands for: ratatui draws
/// a tab as nothing, which would leave the cursor short of the text after it.
fn one_line(text: &str) -> String {
    let shown = text.replace('\n', "\u{23ce}");
    if shown.contains('\t') {
        cells::expand_tabs(&shown, &mut 0)
    } else {
        shown
    }
}

/// What the input's top edge says: the facts on the left, and on the right
/// whatever is unusual right now, most important first. Each note has a
/// short form for when the long one does not fit beside long facts -- a
/// provider-prefixed model and a branch with a slash in it leave a quarter
/// of a hundred-column screen for everything else.
/// The first sentence, for a slot one sentence wide.
fn first_sentence(text: &str) -> &str {
    match text.find(". ") {
        Some(stop) => &text[..=stop],
        None => text,
    }
}

fn status_text(model: &Model) -> (Vec<String>, Vec<(String, String)>) {
    let following = model
        .current_conversation()
        .map(|conversation| conversation.following)
        .unwrap_or(true);
    let facts = crate::status::facts(model);
    let mut notes: Vec<(String, String)> = Vec::new();
    let note = |long: &str, short: &str| (long.to_string(), short.to_string());
    // Which column has the arrows, said first: the same two keys scroll the
    // talk or walk the list.
    match model.focus {
        Focus::Transcript => notes.push(note("↑↓ scroll · ← sessions · esc to type", "↑↓ scroll")),
        Focus::Sessions => notes.push(note("↑↓ choose · enter opens · ⌫ deletes · → the talk", "↑↓ choose")),
        _ => {}
    }
    // The status carries what went wrong -- a closed connection, a refused
    // request -- so it is never replaced by the facts.
    if !model.status.is_empty() {
        // A SHORT FORM THAT IS ACTUALLY SHORT. Both halves used to be the whole
        // status, so an error written for a shell -- the one naming the auth
        // file runs to about five hundred characters -- fitted neither slot and
        // was dropped. A person with no provider key saw `starting a session…`
        // and no reason at all.
        notes.push(note(&model.status, first_sentence(&model.status)));
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
    #[test]
    fn a_pasted_newline_shows_as_one_glyph() {
        // One character wide, which is what keeps DRAW_INPUT's cursor column
        // counting the same thing the reader sees.
        assert_eq!(super::one_line("a\nb"), "a\u{23ce}b");
        assert_eq!(super::one_line("a\nb").chars().count(), "a\nb".chars().count());
        // And untouched text is untouched.
        assert_eq!(super::one_line("plain"), "plain");
    }

    #[test]
    fn a_status_written_for_a_shell_has_a_short_form_that_fits() {
        let long = "No model is configured. Put a key in ~/.viva/auth.json, \
shaped like: { \"deepseek\": { \"apiKey\": \"sk-...\" } }";
        assert_eq!(super::first_sentence(long), "No model is configured.");
        // Nothing to cut is left alone rather than emptied.
        assert_eq!(super::first_sentence("daemon gone"), "daemon gone");
    }

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
    fn frame_of(model: &mut Model, width: u16, height: u16) -> Vec<String> {
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
        let mut model = ready(&[
            ("user.message", "what is in this folder"),
            ("model.delta", "a README and a Cargo.toml\n"),
        ]);
        let frame = frame_of(&mut model, 100, 20);
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
        let frame = frame_of(&mut model, 120, 16);
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
        let frame = frame_of(&mut model, 120, 20).join("\n");
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
        let frame = frame_of(&mut model, 100, 26).join("\n");
        assert!(frame.contains("line0"), "no output at all");
        assert!(frame.contains("37 more lines"), "the hidden lines are not announced");
        assert!(!frame.contains("line39"), "everything was shown despite the glimpse");
        // Expanded, the rest is there and the status line says so.
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.expanded = true;
            conversation.revision += 1;
        }
        let wide = frame_of(&mut model, 100, 60).join("\n");
        assert!(wide.contains("line39"), "expanding showed nothing more");
        assert!(wide.contains("expanded"), "nothing says the output is expanded");
    }

    #[test]
    fn the_cursor_sits_after_the_cells_typed() {
        let at = |typed: &str| {
            let mut model = crate::model::Model::new("/w".into());
            model.input = typed.to_string();
            let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(100, 20)).unwrap();
            let mut rendered = super::Rendered::default();
            terminal.draw(|frame| { super::draw(frame, &mut model, &mut rendered); }).unwrap();
            terminal.get_cursor_position().unwrap().x
        };
        assert_eq!(at("abc") - at(""), 3);
        assert_eq!(at("日本語") - at(""), 6);
        assert_eq!(at("🙂") - at(""), 2);
        assert_eq!(at("a\tb") - at(""), 5);
    }

    #[test]
    fn a_wrapped_result_line_stays_inside_its_own_block() {
        // A result line longer than the pane loses the gutter on the rows
        // below it, and the second half of the line starts at the pane edge
        // -- outside the rule that says which call printed it.
        let mut model = ready(&[]);
        model.absorb(&event("tool.started",
                            json!({"call": {"name": "bash", "arguments": {"command": "cat x"}}})));
        model.sidebar = false;                    // this is about the page
        let long = "alpha bravo charlie delta echo foxtrot golf hotel india juliet \
kilo lima mike november oscar papa quebec";
        model.absorb(&event("tool.completed", json!({"output": long})));
        // Read the TRANSCRIPT CELL, not the frame. The session is also named
        // `alpha` in the tab bar and in the sidebar, and a check that scans
        // whole rows for a word finds those first and tests nothing.
        let rows = frame_of(&mut model, 100, 26);
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
        let rows = frame_of(&mut model, 100, 26);
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
        let frame = frame_of(&mut model, 120, 26).join("\n");
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
        let frame = frame_of(&mut model, 120, 26).join("\n");
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
        let rows = frame_of(&mut model, 100, 26);
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
            // A blank line between them: one newline is a soft break, so
            // `line0\nline1` is one paragraph and barely scrolls at all.
            model.absorb(&event("model.delta", json!({"text": format!("line{index}\n\n")})));
        }
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.following = false;
            conversation.anchor = 5;
        }
        model.learned.inspected = true;
        if let Some(session) = model.sessions.first_mut() {
            session.model = "a-model-with-a-very-long-name-indeed".into();
            session.effort = "high".into();
        }
        let rows = frame_of(&mut model, 84, 20);
        let edge = &rows[rows.len() - 3];
        assert!(edge.contains("scrolled"), "the scroll note was clipped: {edge:?}");
        assert!(!edge.contains("learned"), "the counts outranked the scroll note: {edge:?}");
        let wide = frame_of(&mut model, 160, 20);
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
        let edge = frame_of(&mut model, 96, 16);
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
        let rows = frame_of(&mut model, 110, 26);
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
        let mut model = ready(&[("model.delta", "the last thing said\n")]);
        model.sidebar = false;                    // this is about the page
        let rows = frame_of(&mut model, 100, 16);
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
        let rows = frame_of(&mut model, 110, 16);
        let listed = rows[1..]
            .iter()
            .find(|row| row.contains("why does the picker"))
            .unwrap_or_else(|| panic!("the sidebar does not say what the session is about"));
        assert!(listed.contains('▌'), "the current session lost its marker: {listed:?}");
        // A session nothing has been asked in falls back to where it is.
        assert!(rows[1..].iter().any(|row| row.contains("beta")),
                "a session with no question is not listed by its directory");
    }

    #[test]
    fn the_welcome_columns_do_not_run_into_each_other() {
        // A line one character longer than its column ran straight into the
        // one beside it, and read as two sentences spliced together.
        let mut model = ready(&[]);
        model.sidebar = false;                    // this is about the welcome
        model.sessions.clear();
        model.current.clear();
        let rows = frame_of(&mut model, 100, 20);
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
        let frame = frame_of(&mut model, 130, 26).join("\n");
        assert!(frame.contains("this session"), "the welcome names nothing");
        // The earlier ones live in the sessions column, where they stay once
        // the page fills up -- not in the welcome, which is gone by then.
        assert!(frame.contains("why does the picker"),
                "an earlier session is not in the sessions column:\n{frame}");
        assert!(frame.contains("1 earlier session beside this"),
                "the welcome does not say where they are:\n{frame}");
    }

    #[test]
    fn the_sessions_column_holds_what_is_running_and_what_was() {
        // Running and recorded are the same thing to a person looking for a
        // conversation they had: the difference is whether it still has a
        // process, which is a mark on the row and not a second list.
        let mut model = ready(&[]);
        model.recent = vec![
            crate::protocol::Recorded {
                id: "r1".into(),
                messages: 12,
                opening: "an earlier question".into(),
                ..Default::default()
            },
            // The running session's own transcript: listed once, not twice.
            crate::protocol::Recorded { id: "s1".into(), messages: 3, ..Default::default() },
        ];
        // THE COLUMN, by position. `alpha` is also the tab, and the status
        // line, and the page title -- so counting it across the frame counts
        // three things that are not the list.
        let rows = frame_of(&mut model, 120, 20);
        let column: Vec<String> = rows[1..rows.len() - 3]
            .iter()
            .map(|row| row.chars().take(26).collect())
            .collect();
        assert!(column.iter().any(|row| row.contains("an earlier question")),
                "the earlier session is not listed: {column:?}");
        assert_eq!(column.iter().filter(|row| row.contains("alpha")).count(), 1,
                   "the running session was listed twice: {column:?}");
    }

    #[test]
    fn a_session_with_no_question_is_named_by_its_folder_and_id() {
        // Two fresh sessions in one directory were two identical rows, and
        // the id is what tells them apart.
        let session = SessionInfo {
            id: "20260824-092233-E138".into(),
            label: "/w/alpha".into(),
            ..Default::default()
        };
        assert_eq!(session.subject(), "alpha.E138");
        let asked = SessionInfo { opening: "what is this".into(), ..session.clone() };
        assert_eq!(asked.subject(), "what is this");
    }

    #[test]
    fn reading_back_is_not_dragged_by_output_still_arriving() {
        let mut model = ready(&[]);
        model.sidebar = false;
        for index in 0..80 {
            // A blank line between them: one newline is a soft break, so
            // `line0\nline1` is one paragraph and barely scrolls at all.
            model.absorb(&event("model.delta", json!({"text": format!("line{index}\n\n")})));
        }
        // Scroll back, and settle whatever the movement owes.
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.scroll_by(20);
            while conversation.settle() {}
        }
        let before = frame_of(&mut model, 100, 20);
        // The agent keeps talking while a person reads what it already said.
        for index in 80..90 {
            // A blank line between them: one newline is a soft break, so
            // `line0\nline1` is one paragraph and barely scrolls at all.
            model.absorb(&event("model.delta", json!({"text": format!("line{index}\n\n")})));
        }
        let after = frame_of(&mut model, 100, 20);
        assert_eq!(before, after,
                   "the view moved while reading back:\nbefore\n{}\nafter\n{}",
                   before.join("\n"), after.join("\n"));
    }

    #[test]
    fn a_block_of_work_has_air_where_it_meets_words() {
        // A call ran straight on from the sentence above it and the next
        // sentence ran straight on from its output, so a block had no edge at
        // either end and the whole page read as one run.
        let mut model = ready(&[]);
        model.sidebar = false;
        model.absorb(&event("model.delta", json!({"text": "before the work\n"})));
        for (id, path) in [("t1", "one"), ("t2", "two")] {
            model.absorb(&event("tool.started",
                                json!({"call": {"id": id, "name": "ls",
                                                "arguments": {"path": path}}})));
            model.absorb(&event("tool.completed",
                                json!({"call": {"id": id}, "output": "a-file"})));
        }
        model.absorb(&event("model.delta", json!({"text": "after the work\n"})));
        let rows: Vec<String> = frame_of(&mut model, 100, 20)
            .iter()
            .map(|row| row.trim().to_string())
            .collect();
        let at = |needle: &str| {
            rows.iter().position(|row| row.contains(needle))
                .unwrap_or_else(|| panic!("{needle:?} is not on screen: {rows:?}"))
        };
        assert!(rows[at("before the work") + 1].is_empty(), "no air before the work");
        assert!(rows[at("after the work") - 1].is_empty(), "no air after the work");
        // BETWEEN two calls there is none: each already opens with a titled
        // rule, and a blank between every one of five `ls` calls is worse.
        assert!(rows[at("ls two") - 1].contains("a-file"),
                "two calls were pushed apart: {rows:?}");
    }

    #[test]
    fn a_question_is_not_given_two_lines_of_air() {
        // It opens and closes with one of its own, so the rule that puts air
        // where work meets words gave it a second on each side.
        let mut model = ready(&[]);
        model.sidebar = false;
        model.absorb(&event("tool.started",
                            json!({"call": {"id": "t1", "name": "ls", "arguments": {}}})));
        model.absorb(&event("tool.completed", json!({"call": {"id": "t1"}, "output": "a-file"})));
        model.absorb(&event("user.message", json!({"text": "and then what"})));
        model.absorb(&event("tool.started",
                            json!({"call": {"id": "t2", "name": "ls", "arguments": {}}})));
        let rows: Vec<String> = frame_of(&mut model, 100, 20)
            .iter()
            .map(|row| row.trim().to_string())
            .collect();
        let asked = rows.iter().position(|row| row.contains("and then what")).unwrap();
        assert!(rows[asked - 1].is_empty() && !rows[asked - 2].is_empty(),
                "the question has two lines above it: {rows:?}");
        assert!(rows[asked + 1].is_empty() && !rows[asked + 2].is_empty(),
                "the question has two lines below it: {rows:?}");
    }

    #[test]
    fn a_line_you_ran_yourself_says_the_model_cannot_see_it() {
        // It is published for every attached client and never written to the
        // conversation, so it looked exactly like a call the agent had made --
        // and asking the agent about what it printed got a blank look.
        let mut model = ready(&[]);
        model.sidebar = false;
        model.absorb(&event("tool.started",
                            json!({"call": {"id": "b1", "name": "!",
                                            "arguments": {"command": "ls -la"}}})));
        model.absorb(&event("tool.completed",
                            json!({"call": {"id": "b1", "name": "!"}, "output": "a-file"})));
        model.absorb(&event("tool.started",
                            json!({"call": {"id": "t1", "name": "ls", "arguments": {}}})));
        model.absorb(&event("tool.completed", json!({"call": {"id": "t1"}, "output": "a-file"})));
        let rows = frame_of(&mut model, 110, 20);
        let mine = rows.iter().find(|row| row.contains("! ls -la")).unwrap();
        assert!(mine.contains("not sent to the model"), "a bang line does not say so: {mine:?}");
        let agents = rows.iter().find(|row| row.contains("✔ ls ") || row.contains("✔ ls─")
                                      || (row.contains("✔ ls") && !row.contains("-la"))).unwrap();
        assert!(!agents.contains("not sent"), "an agent's call claims to be yours: {agents:?}");
    }

    #[test]
    fn a_narrow_pane_keeps_the_talk_and_drops_the_rest() {
        // Where this lives is a split, not a hundred-column window. Side panes
        // that squeeze the transcript to nothing are worse than none.
        let mut model = ready(&[("model.delta", "still readable\n")]);
        model.absorb(&event("task.started", json!({"task": "t1", "text": "indexing"})));
        let wide = frame_of(&mut model, 120, 16).join("\n");
        let narrow = frame_of(&mut model, 50, 16).join("\n");
        assert!(wide.contains("running"), "the wide frame has no task column");
        assert!(narrow.contains("still readable"), "the narrow frame lost the transcript");
        assert!(!narrow.contains("running"), "the task column survived into 50 columns");
    }

    #[test]
    fn the_current_session_is_marked_by_a_character_not_only_a_colour() {
        let mut model = ready(&[]);
        model.sidebar = true;
        let frame = frame_of(&mut model, 100, 16);
        // The row INSIDE the sidebar. The tab bar carries the same name and
        // comes first, so the obvious `find` picks it and asserts about the
        // wrong row -- which is a test that passes or fails for reasons
        // unrelated to what it claims to check. Below the tab bar, by position.
        let row = frame[1..]
            .iter()
            .find(|line| line.contains("alpha"))
            .expect("the sidebar has no row for the current session");
        assert!(row.contains('▌'), "the current session's row carries no marker: {row:?}");
        assert!(row.contains('*'), "the working session shows no state mark: {row:?}");
        // Without the sidebar, the tab itself says the session is working.
        model.sidebar = false;
        let tabs = frame_of(&mut model, 100, 16)[0].clone();
        assert!(tabs.contains("* alpha"), "the tab does not carry the state: {tabs:?}");
    }

    #[test]
    fn a_delete_asks_by_name_and_says_it_is_for_good() {
        let mut model = ready(&[("user.message", "run it")]);
        model.ask_delete("s2", "the conversation about lifetimes".into());
        let frame = frame_of(&mut model, 100, 24).join("\n");
        assert!(frame.contains("delete this session?"), "nothing asked:\n{frame}");
        assert!(frame.contains("the conversation about lifetimes"), "the question names nothing:\n{frame}");
        assert!(frame.contains("for good"), "the question does not say it cannot be undone:\n{frame}");
    }

    #[test]
    fn scrolling_stops_at_both_ends() {
        // Without an upper bound, holding Page Up walks the offset past the
        // start and the pane goes blank: the text still there, the window moved
        // off the end.
        let mut model = ready(&[]);
        for index in 0..60 {
            // A blank line between them: one newline is a soft break, so
            // `line0\nline1` is one paragraph and barely scrolls at all.
            model.absorb(&event("model.delta", json!({"text": format!("line{index}\n\n")})));
        }
        let conversation = model.conversations.get_mut("s1").unwrap();
        // Following pins to the bottom whatever the numbers say.
        assert_eq!(conversation.window_top(60, 10), 50);
        // Scrolled back ten, the window moves ten -- not more.
        conversation.scroll_by(10);
        while conversation.settle() {}
        assert_eq!(conversation.window_top(60, 10), 40);
        // Asked for far more than exists, it stops at the first line.
        conversation.scroll_by(10_000);
        while conversation.settle() {}
        assert_eq!(conversation.window_top(60, 10), 0, "scrolling ran past the start");
        // And a conversation shorter than the pane never scrolls at all.
        assert_eq!(conversation.window_top(4, 10), 0);
    }

    #[test]
    fn scrolled_back_is_said_out_loud() {
        // A view that has stopped following looks identical to one with no new
        // output. Saying so is the difference between a pause and a bug.
        let mut model = ready(&[]);
        for index in 0..60 {
            model.absorb(&event("model.delta", json!({"text": format!("line{index}\n\n")})));
        }
        if let Some(conversation) = model.conversations.get_mut("s1") {
            conversation.scroll_by(20);
            while conversation.settle() {}
        }
        let frame = frame_of(&mut model, 100, 16).join("\n");
        assert!(frame.contains("scrolled"), "nothing says the view is not following");
        // And with nothing to scroll, it does not claim to be scrolled back:
        // a view that cannot move has not stopped following anything.
        let mut brief = ready(&[("model.delta", "hello\n")]);
        if let Some(conversation) = brief.conversations.get_mut("s1") {
            conversation.following = false;
        }
        let short = frame_of(&mut brief, 100, 16).join("\n");
        assert!(!short.contains("scrolled"),
                "a transcript shorter than the pane called itself scrolled back");
    }

    #[test]
    fn the_plus_is_a_target_and_the_tabs_report_where_they_are() {
        let mut model = ready(&[]);
        model.open_tab("s2");
        let mut terminal = Terminal::new(TestBackend::new(100, 16)).unwrap();
        let mut hits = Hitboxes::default();
        let mut rendered = Rendered::default();
        terminal.draw(|f| hits = draw(f, &mut model, &mut rendered)).unwrap();
        assert_eq!(hits.tabs.len(), 2, "the tabs report no hitboxes");
        let plus = hits.new_tab.expect("the + reports no range and so can never be hit");
        let (_, first) = hits.tabs[0];
        assert!(plus.x > first.x, "the + overlaps the first tab");
        // Every tab's box is distinct, so a click cannot select two.
        let (_, second) = hits.tabs[1];
        assert!(second.x >= first.x + first.width, "two tabs claim the same columns");
    }
}
