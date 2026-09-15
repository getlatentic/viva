//! The sessions column: what is running here, then what was, under headings,
//! in a window that follows the selection.

use crate::cells;
use crate::model::{Focus, Listed, Model};
use crate::session_list::Window;
use crate::theme::{state_mark, ACCENT, BORDER, DIM};
use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph};
use std::time::{SystemTime, UNIX_EPOCH};

/// The selected row's ground while the column has the keyboard.
const CHOSEN: Color = Color::Indexed(237);

/// Seconds between 1900, where the daemon's universal time counts from, and 1970.
const UNIVERSAL_TO_UNIX: u64 = 2_208_988_800;

/// A row of the column: a heading over a group, or a session.
pub enum Row<'a> {
    Heading(&'static str, usize),
    Session(Listed<'a>),
}

/// Where the column was drawn, and the session on each row, so a click lands
/// on the session it points at.
pub struct Column {
    pub area: Rect,
    pub rows: Vec<(String, Rect)>,
}

/// The rows of the column, headings included.
pub fn rows(model: &Model) -> Vec<Row<'_>> {
    let listed = model.sidebar_rows();
    let live = listed.iter().filter(|row| matches!(row, Listed::Live(_))).count();
    let earlier = listed.len() - live;
    let mut rows = Vec::with_capacity(listed.len() + 2);
    for (index, row) in listed.into_iter().enumerate() {
        if index == 0 && live > 0 {
            rows.push(Row::Heading("running", live));
        }
        if index == live {
            rows.push(Row::Heading("earlier", earlier));
        }
        rows.push(Row::Session(row));
    }
    rows
}

pub fn draw(frame: &mut Frame, area: Rect, model: &mut Model) -> Column {
    let focused = model.focus == Focus::Sessions;
    // A column with an edge, not a box. The edge is where it meets the page.
    let block = Block::default()
        .borders(Borders::RIGHT)
        .border_style(Style::default().fg(if focused { ACCENT } else { BORDER }))
        .title(Span::styled(" sessions ", Style::default().fg(if focused { ACCENT } else { DIM })));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let window = place_window(model, focused, inner.height as usize);
    let drawn = rows(model);
    let chosen = if focused { model.selected_row().map(|row| row.id().to_string()) } else { None };
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|since| since.as_secs()).unwrap_or(0);
    let mut lines: Vec<Line> = Vec::new();
    let mut hits = Vec::new();
    if drawn.is_empty() {
        lines.push(Line::from(Span::styled("  no sessions here", Style::default().fg(DIM))));
    }
    if window.marks_above() {
        lines.push(dim(format!("  ↑ {} more", window.above)));
    }
    for row in &drawn[window.first..window.last] {
        match row {
            Row::Heading(name, count) => lines.push(dim(format!("  {name} {count}"))),
            Row::Session(listed) => {
                let at = Rect::new(inner.x, inner.y + lines.len() as u16, inner.width, 1);
                hits.push((listed.id().to_string(), at));
                let open = listed.id() == model.current;
                let selected = chosen.as_deref() == Some(listed.id());
                lines.push(session_line(listed, open, selected, inner.width as usize, now));
            }
        }
    }
    if window.marks_below() {
        lines.push(dim(format!("  ↓ {} more", window.below)));
    }
    // No wrap: one row per session, so the row a click lands on is the
    // session it names.
    frame.render_widget(Paragraph::new(lines), inner);
    Column { area: inner, rows: hits }
}

/// Where the window lands: on the selection while the column has the keyboard,
/// and on the open session while it does not.
fn place_window(model: &mut Model, focused: bool, height: usize) -> Window {
    let (total, follow) = {
        let drawn = rows(model);
        let target = if focused {
            model.selected_row().map(|row| row.id().to_string())
        } else {
            Some(model.current.clone())
        };
        let at = target.and_then(|id| {
            drawn.iter().position(|row| matches!(row, Row::Session(listed) if listed.id() == id))
        });
        // A group's heading comes into view with its first session.
        let follow = at.map(|at| match at.checked_sub(1).map(|above| &drawn[above]) {
            Some(Row::Heading(..)) => (at - 1, at),
            _ => (at, at),
        });
        (drawn.len(), follow)
    };
    model.session_list.window(total, follow, height)
}

fn dim(text: String) -> Line<'static> {
    Line::from(Span::styled(text, Style::default().fg(DIM)))
}

/// One session: a bar beside the open one, a mark on the selected one, its
/// state, what it is about, and -- for one no longer running -- how long ago it
/// was last used. The selection is a character as well as a ground, so it
/// still reads on a monochrome terminal.
fn session_line(listed: &Listed, open: bool, selected: bool, width: usize, now: u64) -> Line<'static> {
    let (mark, colour) = match listed {
        Listed::Live(session) => state_mark(&session.state),
        // A conversation with no process is not a state, it is a record.
        Listed::Earlier(_) => ("·", BORDER),
    };
    let age = match listed {
        Listed::Earlier(recorded) => ago(recorded.time, now),
        Listed::Live(_) => String::new(),
    };
    let tail = if age.is_empty() { 1 } else { cells::width(&age) + 2 };
    let room = width.saturating_sub(4 + tail);
    // CUT WITH A MARK. A subject sliced by the pane edge reads as a subject
    // that happens to end there, and the column is narrow enough that most
    // of them are.
    let subject = cells::clip(&listed.subject(), room);
    let gap = room.saturating_sub(cells::width(&subject));
    let ground = if selected { Style::default().bg(CHOSEN) } else { Style::default() };
    let name = if open {
        ground.fg(Color::Indexed(252)).add_modifier(Modifier::BOLD)
    } else if matches!(listed, Listed::Earlier(_)) && !selected {
        ground.fg(DIM)
    } else {
        ground
    };
    let mut spans = vec![
        Span::styled(if open { "▌" } else { " " }, ground.fg(ACCENT)),
        Span::styled(if selected { "›" } else { " " }, ground.fg(ACCENT).add_modifier(Modifier::BOLD)),
        Span::styled(mark, ground.fg(colour)),
        Span::styled(" ", ground),
        Span::styled(subject, name),
        Span::styled(" ".repeat(gap + 1), ground),
    ];
    if !age.is_empty() {
        spans.push(Span::styled(age, ground.fg(DIM)));
        spans.push(Span::styled(" ", ground));
    }
    Line::from(spans)
}

/// How long ago universal time THEN was, in the largest whole unit. Nothing
/// for a time the daemon did not know.
fn ago(then: u64, now: u64) -> String {
    let Some(unix) = then.checked_sub(UNIVERSAL_TO_UNIX).filter(|unix| *unix > 0) else {
        return String::new();
    };
    let seconds = now.saturating_sub(unix);
    match seconds {
        0..=59 => "now".to_string(),
        60..=3_599 => format!("{}m", seconds / 60),
        3_600..=86_399 => format!("{}h", seconds / 3_600),
        86_400..=604_799 => format!("{}d", seconds / 86_400),
        604_800..=31_535_999 => format!("{}w", seconds / 604_800),
        _ => format!("{}y", seconds / 31_536_000),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Recorded, SessionInfo};
    use ratatui::backend::TestBackend;
    use ratatui::buffer::Buffer;
    use ratatui::Terminal;

    fn with_history(earlier: usize) -> Model {
        let mut model = Model::new("/w".into());
        model.sessions = vec![
            SessionInfo { id: "s1".into(), opening: "the open one".into(), state: "working".into(), ..Default::default() },
            SessionInfo { id: "s2".into(), opening: "another running".into(), ..Default::default() },
        ];
        model.open_tab("s1");
        model.recent = (0..earlier)
            .map(|index| Recorded {
                id: format!("r{index}"),
                messages: 4,
                opening: format!("earlier question {index}"),
                ..Default::default()
            })
            .collect();
        model
    }

    /// The column drawn thirty wide and HEIGHT tall: its rows as text, where
    /// each session landed, and the cells themselves.
    fn column(model: &mut Model, height: u16) -> (Vec<String>, Column, Buffer) {
        let mut terminal = Terminal::new(TestBackend::new(30, height)).unwrap();
        let mut drawn = None;
        terminal.draw(|frame| drawn = Some(draw(frame, frame.area(), model))).unwrap();
        let buffer = terminal.backend().buffer().clone();
        let text = (0..height)
            .map(|y| (0..30).map(|x| buffer[(x, y)].symbol()).collect::<String>())
            .collect();
        (text, drawn.unwrap(), buffer)
    }

    fn row_of(text: &[String], needle: &str) -> usize {
        text.iter()
            .position(|row| row.contains(needle))
            .unwrap_or_else(|| panic!("no row says {needle:?}: {text:#?}"))
    }

    #[test]
    fn what_is_running_and_what_was_are_listed_under_their_own_headings() {
        let mut model = with_history(2);
        let (text, _, _) = column(&mut model, 12);
        assert!(row_of(&text, "running 2") < row_of(&text, "the open one"));
        assert!(row_of(&text, "another running") < row_of(&text, "earlier 2"));
        assert!(row_of(&text, "earlier 2") < row_of(&text, "earlier question 0"));
        assert!(text[row_of(&text, "the open one")].starts_with('▌'),
                "the open session is not marked by a character: {text:#?}");
        assert!(!text[row_of(&text, "another running")].starts_with('▌'));
    }

    #[test]
    fn a_long_column_follows_the_selection_and_says_how_many_are_out_of_sight() {
        let mut model = with_history(40);
        model.focus_sessions();
        for _ in 0..30 {
            model.move_selection(1);
        }
        let (text, drawn, buffer) = column(&mut model, 12);
        let selected = model.selected_row().unwrap();
        let row = row_of(&text, &selected.subject());
        assert!(text.iter().any(|line| line.contains("↑") && line.contains("more")),
                "nothing says what is above: {text:#?}");
        assert!(text.iter().any(|line| line.contains("↓") && line.contains("more")),
                "nothing says what is below: {text:#?}");
        assert_eq!(buffer[(20, row as u16)].bg, CHOSEN, "the selection is not highlighted");
        assert_eq!(text[row].chars().nth(1), Some('›'), "the selection is only a colour: {:?}", text[row]);
        assert!(drawn.rows.iter().any(|(id, area)| id == selected.id() && area.y == row as u16),
                "a click on the selected row would open something else");
    }

    #[test]
    fn the_selection_is_not_drawn_while_the_column_does_not_have_the_keyboard() {
        let mut model = with_history(3);
        model.focus_sessions();
        model.move_selection(2);
        model.focus = Focus::Input;
        let (text, _, buffer) = column(&mut model, 12);
        for row in 0..text.len() {
            assert_ne!(buffer[(20, row as u16)].bg, CHOSEN, "row {row} is highlighted: {text:#?}");
            assert_ne!(text[row].chars().nth(1), Some('›'), "row {row} is marked: {text:#?}");
        }
    }

    #[test]
    fn a_session_no_longer_running_says_how_long_ago_it_was_used() {
        let mut model = with_history(1);
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        model.recent[0].time = now - 7_200 + UNIVERSAL_TO_UNIX;
        let (text, _, _) = column(&mut model, 8);
        let row = &text[row_of(&text, "earlier question 0")];
        assert!(row.trim_end_matches('│').trim_end().ends_with("2h"), "{row:?}");
    }

    #[test]
    fn an_age_is_said_in_the_largest_whole_unit() {
        let now = 1_700_000_000;
        let before = |seconds: u64| now - seconds + UNIVERSAL_TO_UNIX;
        assert_eq!(ago(before(30), now), "now");
        assert_eq!(ago(before(5 * 60), now), "5m");
        assert_eq!(ago(before(3 * 3_600), now), "3h");
        assert_eq!(ago(before(2 * 86_400), now), "2d");
        assert_eq!(ago(before(3 * 604_800), now), "3w");
        assert_eq!(ago(0, now), "", "a time nobody knew was given an age");
    }
}
