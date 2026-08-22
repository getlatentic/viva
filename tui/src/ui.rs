//! Drawing the model.
//!
//! ratatui does here what src/tui/screen.lisp did by hand: two buffers, a
//! diff, and only the changed cells on the wire. That part is not novel and
//! is not ours -- what is ours is above it, and this file is only the
//! arrangement.

use crate::model::{Focus, Model, Role, TaskState};
use ratatui::prelude::*;
use ratatui::widgets::{Block, BorderType, Borders, Paragraph, Wrap};

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
}

pub fn draw(frame: &mut Frame, model: &Model) -> Hitboxes {
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
    draw_transcript(frame, transcript_area, model, &mut hits);
    if body.len() > 2 {
        draw_tasks(frame, body[2], model, &mut hits);
    }

    draw_input(frame, rows[2], model, &mut hits);
    draw_status(frame, rows[3], model);
    hits
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
pub fn transcript_lines(model: &Model) -> Vec<Line<'static>> {
    let mut lines: Vec<Line> = Vec::new();
    let Some(conversation) = model.current_conversation() else {
        return lines;
    };
    for entry in conversation.visible_entries() {
        match entry.role {
            Role::User => {
                lines.push(Line::from(""));
                for (index, piece) in entry.text.lines().enumerate() {
                    let prefix = if index == 0 { "› " } else { "  " };
                    lines.push(Line::from(vec![
                        Span::styled(prefix, Style::default().fg(ACCENT).add_modifier(Modifier::BOLD)),
                        Span::styled(
                            piece.to_string(),
                            Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
                        ),
                    ]));
                }
                lines.push(Line::from(""));
            }
            Role::Assistant => {
                for piece in entry.text.split('\n') {
                    lines.push(Line::from(Span::raw(piece.to_string())));
                }
            }
            Role::Tool => lines.push(Line::from(vec![
                Span::styled("· ", Style::default().fg(DIM)),
                Span::styled(entry.text.clone(), Style::default().fg(DIM)),
            ])),
            Role::Note => lines.push(Line::from(Span::styled(
                format!("! {}", entry.text),
                Style::default().fg(Color::Indexed(203)),
            ))),
        }
    }
    lines
}

fn draw_transcript(frame: &mut Frame, area: Rect, model: &Model, hits: &mut Hitboxes) {
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

    let lines = transcript_lines(model);
    let paragraph = Paragraph::new(lines).wrap(Wrap { trim: false });
    let total = paragraph.line_count(inner.width) as u16;
    let offset = scroll_offset(model, total, inner.height);
    frame.render_widget(paragraph.scroll((offset, 0)), inner);
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
        text.push_str("   [scrolled -- End to follow]");
    }
    if !model.connected {
        text.push_str("   [daemon gone]");
    }
    if model.current_conversation().map(|c| c.gap).unwrap_or(false) {
        text.push_str("   [missed events — ctrl-r to re-read]");
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
        terminal.draw(|f| { draw(f, model); }).unwrap();
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
        terminal.draw(|f| hits = draw(f, &model)).unwrap();
        assert_eq!(hits.tabs.len(), 2, "the tabs report no hitboxes");
        let plus = hits.new_tab.expect("the + reports no range and so can never be hit");
        let (_, first) = hits.tabs[0];
        assert!(plus.x > first.x, "the + overlaps the first tab");
        // Every tab's box is distinct, so a click cannot select two.
        let (_, second) = hits.tabs[1];
        assert!(second.x >= first.x + first.width, "two tabs claim the same columns");
    }
}
