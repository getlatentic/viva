//! A list walked by keys and scrolled by a wheel, with the selection kept by id.
//!
//! By id, so a list that changes under the selection -- a session starting,
//! another ending -- goes on pointing at the same entry, and falls back to the
//! row nearest where it was when that entry leaves. The window moves only as
//! far as the selection needs, unless the wheel moved it; the next key brings
//! the selection back into view.

/// Which entry is selected, and where the window over the list starts.
#[derive(Debug, Default)]
pub struct SessionList {
    selected: Option<String>,
    /// Where the selection was, for when its entry leaves the list.
    hint: usize,
    /// The first row drawn.
    offset: usize,
    /// True while the wheel, not the selection, decides the window.
    wheeled: bool,
}

/// The rows a window shows, and how many are out of sight each way.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Window {
    pub first: usize,
    pub last: usize,
    pub above: usize,
    pub below: usize,
    pub height: usize,
}

impl Window {
    /// Does a row above the entries say how many are out of sight? Not in a
    /// window too short to hold that and an entry besides.
    pub fn marks_above(&self) -> bool {
        self.above > 0 && self.height >= 3
    }

    pub fn marks_below(&self) -> bool {
        self.below > 0 && self.height >= 3
    }
}

impl SessionList {
    /// The selected entry's place among IDS: where it is, or the row nearest
    /// where it was once it has gone. NONE only for an empty list.
    pub fn index(&self, ids: &[&str]) -> Option<usize> {
        if ids.is_empty() {
            return None;
        }
        let found = self
            .selected
            .as_deref()
            .and_then(|selected| ids.iter().position(|id| *id == selected));
        Some(found.unwrap_or(self.hint.min(ids.len() - 1)))
    }

    /// Select the entry with ID, when IDS has it.
    pub fn select(&mut self, ids: &[&str], id: &str) {
        if let Some(index) = ids.iter().position(|each| *each == id) {
            self.take(ids, index);
        }
    }

    fn take(&mut self, ids: &[&str], index: usize) {
        self.selected = Some(ids[index].to_string());
        self.hint = index;
        self.wheeled = false;
    }

    /// Move the selection by STEP entries, round from the last to the first.
    pub fn step(&mut self, ids: &[&str], step: isize) {
        let Some(index) = self.index(ids) else {
            return;
        };
        let next = (index as isize + step).rem_euclid(ids.len() as isize) as usize;
        self.take(ids, next);
    }

    /// Scroll the window by LINES without moving the selection.
    pub fn wheel(&mut self, lines: isize, total: usize, height: usize) {
        let furthest = place(total, total, None, height).first;
        self.offset = (self.offset as isize + lines).clamp(0, furthest as isize) as usize;
        self.wheeled = true;
    }

    /// The window over TOTAL rows, HEIGHT tall, keeping rows FOLLOW -- a first
    /// and a last -- in view. Remembers where it landed, so the next frame
    /// starts from there.
    pub fn window(&mut self, total: usize, follow: Option<(usize, usize)>, height: usize) -> Window {
        let window = place(self.offset, total, if self.wheeled { None } else { follow }, height);
        self.offset = window.first;
        window
    }
}

/// Rows left for entries when the window starts at FIRST: a row that says what
/// is out of sight is a row the entries do not get.
fn content_rows(first: usize, total: usize, height: usize) -> usize {
    if height < 3 {
        return height;
    }
    let mut rows = height;
    if first > 0 {
        rows -= 1;
    }
    if first + rows < total {
        rows -= 1;
    }
    rows
}

/// Where a window over TOTAL rows lands, starting from OFFSET and moving only
/// as far as it must to show rows FOLLOW. When they cannot all fit, the last of
/// them -- the selection -- is the one kept.
fn place(offset: usize, total: usize, follow: Option<(usize, usize)>, height: usize) -> Window {
    if height == 0 || total <= height {
        let last = total.min(height);
        return Window { first: 0, last, above: 0, below: total - last, height };
    }
    let mut first = offset.min(total - 1);
    if let Some((start, end)) = follow {
        first = first.min(start);
        while end >= first + content_rows(first, total, height) {
            first += 1;
        }
    }
    // No empty rows under the last entry: back up while an earlier start still
    // reaches the end.
    while first > 0 && first - 1 + content_rows(first - 1, total, height) >= total {
        first -= 1;
    }
    let last = (first + content_rows(first, total, height)).min(total);
    Window { first, last, above: first, below: total - last, height }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_selection_stays_on_its_entry_when_the_list_changes_under_it() {
        let mut list = SessionList::default();
        list.select(&["s0", "s1", "s2", "s3", "s4"], "s3");
        assert_eq!(list.index(&["new", "s0", "s1", "s2", "s3", "s4"]), Some(4),
                   "an entry arriving moved the selection off its session");
        assert_eq!(list.index(&["new", "s0", "s1", "s4"]), Some(3),
                   "the row nearest was not taken when the selected entry left");
    }

    #[test]
    fn a_step_goes_round_from_the_last_row_to_the_first() {
        let ids = ["a", "b", "c"];
        let mut list = SessionList::default();
        list.select(&ids, "c");
        list.step(&ids, 1);
        assert_eq!(list.index(&ids), Some(0));
        list.step(&ids, -1);
        assert_eq!(list.index(&ids), Some(2));
        let mut empty = SessionList::default();
        empty.step(&[], 1);
        assert_eq!(empty.index(&[]), None);
    }

    #[test]
    fn a_short_list_is_drawn_whole_with_nothing_said_about_more() {
        let window = place(0, 4, Some((3, 3)), 10);
        assert_eq!((window.first, window.last), (0, 4));
        assert!(!window.marks_above() && !window.marks_below());
    }

    #[test]
    fn the_window_moves_only_as_far_as_the_selection_needs() {
        // Forty rows, ten high: row 12 is reached with a row saying what is
        // above and a row saying what is below, and the window goes no further.
        let window = place(0, 40, Some((12, 12)), 10);
        assert_eq!((window.first, window.last), (5, 13), "{window:?}");
        assert!(window.marks_above() && window.marks_below());
        assert_eq!(window.last - window.first + 2, 10, "the rows saying `more` were not counted");
        let back = place(window.first, 40, Some((4, 4)), 10);
        assert_eq!(back.first, 4, "moving up one went further than one: {back:?}");
    }

    #[test]
    fn the_first_entry_of_a_group_is_shown_under_its_heading() {
        assert_eq!(place(11, 40, Some((9, 10)), 10).first, 9);
        // When there is no room for both, the selection is what stays.
        let tight = place(0, 40, Some((5, 12)), 5);
        assert!(tight.first <= 12 && 12 < tight.last, "{tight:?}");
    }

    #[test]
    fn the_end_of_the_list_is_not_followed_by_empty_rows() {
        let window = place(38, 40, None, 10);
        assert_eq!((window.first, window.last, window.below), (31, 40, 0), "{window:?}");
    }

    #[test]
    fn a_window_too_short_to_say_more_shows_entries_only() {
        let window = place(5, 20, Some((6, 6)), 2);
        assert_eq!(window.last - window.first, 2, "{window:?}");
        assert!(!window.marks_above() && !window.marks_below());
    }

    #[test]
    fn the_wheel_moves_the_window_and_the_next_key_brings_the_selection_back() {
        let ids: Vec<String> = (0..40).map(|index| format!("s{index}")).collect();
        let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
        let mut list = SessionList::default();
        list.select(&ids, "s0");
        assert_eq!(list.window(40, Some((0, 0)), 10).first, 0);
        list.wheel(20, 40, 10);
        assert_eq!(list.window(40, Some((0, 0)), 10).first, 20, "the selection overrode the wheel");
        list.wheel(1000, 40, 10);
        assert_eq!(list.window(40, None, 10).last, 40, "the wheel ran past the end");
        list.step(&ids, 1);
        let window = list.window(40, Some((1, 1)), 10);
        assert!(window.first <= 1 && 1 < window.last, "a key did not bring the selection back: {window:?}");
    }
}
