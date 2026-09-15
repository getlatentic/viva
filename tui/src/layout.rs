//! The transcript's rows, kept from one frame to the next.
//!
//! Wrapping a long conversation takes longer than a frame has, so rows are
//! made when an entry changes and then kept: for every open tab, and for the
//! last two widths each entry was drawn at. A frame compares one stamp per
//! entry and copies the rows its window shows.

use std::collections::HashMap;

use ratatui::text::Line;

use crate::model::{Entry, Model, Role};
use crate::wrap::{self, Hanging, Wrapped};

/// Widths an entry keeps rows for. The sessions column and the task pane each
/// take width from the page and give it back, so a page flips between two;
/// a resize through many keeps the last two.
const WIDTHS: usize = 2;

/// Laid-out transcripts, one for each open tab.
#[derive(Default)]
pub struct Rendered {
    pages: HashMap<String, Page>,
    /// The session and width laid out last, which the window is read from.
    shown: Option<(String, u16)>,
}

#[derive(Default)]
struct Page {
    entries: Vec<Laid>,
    /// Where each entry begins at the width laid out last.
    starts: Vec<usize>,
    total: usize,
}

/// One entry's lines, and the version of the entry they were made from.
struct Laid {
    stamp: u64,
    expanded: bool,
    /// What came before it. A block puts a line of air between itself and
    /// prose, so its lines depend on what it follows.
    after: Option<Role>,
    lines: Vec<LaidLine>,
    /// Widths every line has rows for, the latest first, and the rows that
    /// comes to.
    heights: Vec<(u16, usize)>,
}

struct LaidLine {
    hanging: Hanging,
    wrapped: Vec<(u16, Wrapped)>,
}

impl Rendered {
    /// Bring the current session's rows up to date at WIDTH, asking LINES_OF
    /// only for the entries that changed.
    pub fn refresh(
        &mut self,
        model: &Model,
        width: u16,
        lines_of: impl Fn(&Entry, bool, Option<Role>) -> Vec<Hanging>,
    ) {
        self.pages.retain(|session, _| *session == model.current || model.tabs.contains(session));
        let Some(conversation) = model.current_conversation() else {
            self.shown = None;
            return;
        };
        let page = self.pages.entry(model.current.clone()).or_default();
        let expanded = conversation.expanded;
        let mut after = None;
        let mut count = 0;
        for entry in conversation.visible_entries() {
            let unchanged = page.entries.get(count).is_some_and(|laid| {
                laid.stamp == entry.stamp && laid.expanded == expanded && laid.after == after
            });
            if !unchanged {
                let lines = lines_of(entry, expanded, after);
                match page.entries.get_mut(count) {
                    Some(laid) => laid.relay(lines, width),
                    None => page.entries.push(Laid::new(lines)),
                }
                let laid = &mut page.entries[count];
                laid.stamp = entry.stamp;
                laid.expanded = expanded;
                laid.after = after;
            }
            after = Some(entry.role);
            count += 1;
        }
        page.entries.truncate(count);

        page.starts.clear();
        let mut running = 0;
        for laid in &mut page.entries {
            page.starts.push(running);
            running += laid.height(width);
        }
        page.total = running;
        self.shown = Some((model.current.clone(), width));
    }

    /// How many rows the session laid out last comes to.
    pub fn total(&self) -> u16 {
        self.page().map_or(0, |(page, _)| page.total.min(u16::MAX as usize) as u16)
    }

    fn page(&self) -> Option<(&Page, u16)> {
        let (session, width) = self.shown.as_ref()?;
        Some((self.pages.get(session)?, *width))
    }

    /// The rows to draw for a window HEIGHT tall starting at OFFSET.
    ///
    /// A slice, so drawing costs the height of the pane rather than the
    /// length of the session.
    pub fn window(&self, offset: u16, height: u16) -> Vec<Line<'static>> {
        let Some((page, width)) = self.page() else {
            return Vec::new();
        };
        let first = (offset as usize).min(page.total);
        let last = (first + height as usize).min(page.total);
        let mut rows = Vec::with_capacity(last - first);
        // Straight to the entry the window opens on, rather than through every
        // line above it.
        let mut at = match page.starts.binary_search(&first) {
            Ok(index) => index,
            Err(index) => index.saturating_sub(1),
        };
        while at < page.entries.len() && page.starts[at] < last {
            let mut position = page.starts[at];
            for line in &page.entries[at].lines {
                for row in line.rows(width) {
                    if position >= first && position < last {
                        rows.push(row.clone());
                    }
                    position += 1;
                }
            }
            at += 1;
        }
        rows
    }
}

impl Laid {
    fn new(lines: Vec<Hanging>) -> Self {
        Laid {
            stamp: 0,
            expanded: false,
            after: None,
            lines: lines.into_iter().map(|hanging| LaidLine { hanging, wrapped: Vec::new() }).collect(),
            heights: Vec::new(),
        }
    }

    /// Take the lines the entry comes to now. A line the same as the one in
    /// its place keeps its rows, and one with text added at its end keeps all
    /// but its last two at the width being drawn.
    fn relay(&mut self, lines: Vec<Hanging>, width: u16) {
        let mut before = std::mem::take(&mut self.lines).into_iter();
        self.lines = lines
            .into_iter()
            .map(|hanging| match before.next() {
                Some(line) if line.hanging == hanging => line,
                Some(line) if hanging.extends(&line.hanging) => {
                    let wrapped = line
                        .wrapped
                        .into_iter()
                        .find(|(at, _)| *at == width)
                        .map(|(at, rows)| vec![(at, wrap::rewrap(rows, &hanging, width))])
                        .unwrap_or_default();
                    LaidLine { hanging, wrapped }
                }
                _ => LaidLine { hanging, wrapped: Vec::new() },
            })
            .collect();
        self.heights.clear();
    }

    /// The rows this entry comes to at WIDTH, wrapping the lines that have
    /// none there and letting go of widths older than the two latest.
    fn height(&mut self, width: u16) -> usize {
        match self.heights.iter().position(|(at, _)| *at == width) {
            Some(0) => return self.heights[0].1,
            Some(index) => {
                let found = self.heights.remove(index);
                self.heights.insert(0, found);
                return found.1;
            }
            None => {}
        }
        self.heights.truncate(WIDTHS - 1);
        let kept: Vec<u16> = self.heights.iter().map(|(at, _)| *at).collect();
        let rows = self.lines.iter_mut().map(|line| line.wrap_to(width, &kept)).sum();
        self.heights.insert(0, (width, rows));
        rows
    }
}

impl LaidLine {
    /// Rows at WIDTH, made if there are none, keeping those at KEPT as well.
    fn wrap_to(&mut self, width: u16, kept: &[u16]) -> usize {
        self.wrapped.retain(|(at, _)| *at == width || kept.contains(at));
        if !self.wrapped.iter().any(|(at, _)| *at == width) {
            self.wrapped.push((width, wrap::wrap(&self.hanging, width)));
        }
        self.rows(width).len()
    }

    fn rows(&self, width: u16) -> &[Line<'static>] {
        self.wrapped
            .iter()
            .find(|(at, _)| *at == width)
            .map_or(&[], |(_, wrapped)| wrapped.rows.as_slice())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Event, SessionInfo};
    use ratatui::prelude::*;
    use serde_json::{json, Value};

    /// An entry's text as lines, one per line of it: the layout does not care
    /// what the lines say, only when they change.
    fn lines_of(entry: &Entry, expanded: bool, after: Option<Role>) -> Vec<Hanging> {
        let mut lines = Vec::new();
        if expanded && after.is_some() {
            lines.push(Hanging::plain(Line::from("")));
        }
        for piece in entry.text.split('\n') {
            let line = Line::from(vec![Span::raw("› "), Span::raw(piece.to_string())]);
            lines.push(Hanging::under("  ", Style::default(), line));
        }
        lines
    }

    fn two_tabs() -> Model {
        let mut model = Model::new("/w".into());
        model.sessions = vec![
            SessionInfo { id: "s1".into(), ..Default::default() },
            SessionInfo { id: "s2".into(), ..Default::default() },
        ];
        model.open_tab("s2");
        model.open_tab("s1");
        model
    }

    fn say(model: &mut Model, name: &str, data: Value) {
        let session = model.current.clone();
        let event: Event =
            serde_json::from_value(json!({"event": name, "session": session, "seq": 0, "data": data})).unwrap();
        model.absorb(&event);
    }

    #[test]
    fn what_is_kept_draws_the_same_as_laying_out_afresh() {
        const TOKENS: [&str; 9] = [
            "word ", "and more ", "\n", "an-unbroken-token-longer-than-a-row", " ", "日本語", "\n\n", "e\u{301} ", "\t",
        ];
        let mut model = two_tabs();
        let mut kept = Rendered::default();
        let mut seed: u64 = 0x5eed_1234_abcd;
        let mut roll = |sides: usize| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed % sides as u64) as usize
        };
        for step in 0..600 {
            match roll(12) {
                0 => {
                    let other = if model.current == "s1" { "s2" } else { "s1" };
                    model.open_tab(other);
                }
                1 => say(&mut model, "user.message", json!({"text": format!("question {step}")})),
                2 => {
                    let current = model.current.clone();
                    if let Some(conversation) = model.conversations.get_mut(&current) {
                        conversation.expanded = !conversation.expanded;
                    }
                }
                _ => say(&mut model, "model.delta", json!({"text": TOKENS[roll(TOKENS.len())]})),
            }
            let width = [24u16, 37, 60][roll(3)];
            kept.refresh(&model, width, lines_of);
            let mut fresh = Rendered::default();
            fresh.refresh(&model, width, lines_of);
            assert_eq!(kept.total(), fresh.total(), "step {step} at width {width}");
            assert_eq!(kept.window(0, kept.total()), fresh.window(0, fresh.total()), "step {step} at width {width}");
        }
    }

    #[test]
    fn a_closed_tab_takes_its_rows_with_it() {
        let mut model = two_tabs();
        let mut kept = Rendered::default();
        for session in ["s2", "s1"] {
            model.open_tab(session);
            say(&mut model, "model.delta", json!({"text": "something to lay out\n"}));
            kept.refresh(&model, 40, lines_of);
        }
        assert_eq!(kept.pages.len(), 2);
        let s2 = model.tabs.iter().position(|tab| tab == "s2").unwrap();
        model.close_tab(s2);
        kept.refresh(&model, 40, lines_of);
        assert_eq!(kept.pages.keys().collect::<Vec<_>>(), ["s1"]);
    }

    #[test]
    fn an_entry_keeps_rows_for_the_two_widths_it_was_drawn_at_last() {
        let mut model = two_tabs();
        say(&mut model, "model.delta", json!({"text": "a line long enough to wrap at every width here\n"}));
        let mut kept = Rendered::default();
        for width in [30, 40, 30, 50] {
            kept.refresh(&model, width, lines_of);
        }
        for laid in &kept.pages["s1"].entries {
            for line in &laid.lines {
                let mut widths: Vec<u16> = line.wrapped.iter().map(|(at, _)| *at).collect();
                widths.sort();
                assert_eq!(widths, [30, 50], "40 was drawn before 30 and should have gone");
            }
        }
    }
}
