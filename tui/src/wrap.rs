//! One line of the transcript as the rows it takes at a width.
//!
//! Lines are wrapped when they change, never at render time: a Paragraph wraps
//! every time it is drawn, so a frame would cost the whole conversation however
//! little of it is on screen.

use std::ops::Range;

use ratatui::prelude::*;

use crate::cells;

/// A line, and what stands in front of the rows it wraps onto.
///
/// A result line that begins with a gutter and loses it on the rows below
/// breaks its own block open: the second half of a long line starts at the
/// pane edge, outside the rule that says which call printed it.
#[derive(Clone, Debug, PartialEq)]
pub struct Hanging {
    line: Line<'static>,
    indent: Option<Span<'static>>,
    /// A rule from the end of the line to the edge of the pane, drawn when the
    /// line fits on one row with room to spare: what heads a tool call.
    rule: Option<Style>,
}

impl Hanging {
    pub fn plain(line: Line<'static>) -> Self {
        Hanging { line, indent: None, rule: None }
    }

    pub fn under(indent: impl Into<String>, style: Style, line: Line<'static>) -> Self {
        Hanging { line, indent: Some(Span::styled(indent.into(), style)), rule: None }
    }

    pub fn ruled(line: Line<'static>, style: Style) -> Self {
        Hanging { line, indent: None, rule: Some(style) }
    }

    /// Is this OLDER with text added at its end, and nothing before that changed?
    pub fn extends(&self, older: &Hanging) -> bool {
        if self.rule.is_some()
            || older.rule.is_some()
            || self.indent != older.indent
            || self.line.style != older.line.style
            || self.line.alignment != older.line.alignment
        {
            return false;
        }
        let Some((last, before)) = older.line.spans.split_last() else {
            return true;
        };
        let spans = &self.line.spans;
        spans.len() > before.len()
            && spans[..before.len()] == *before
            && spans[before.len()].style == last.style
            && spans[before.len()].content.starts_with(last.content.as_ref())
    }
}

/// A line's rows at one width, and where each row begins in the line's text.
#[derive(Debug)]
pub struct Wrapped {
    pub rows: Vec<Line<'static>>,
    starts: Vec<usize>,
}

/// LINE broken into rows WIDTH cells wide, between words where it can be.
pub fn wrap(line: &Hanging, width: u16) -> Wrapped {
    lay(line, width, Wrapped { rows: Vec::new(), starts: Vec::new() }, 0)
}

/// The rows of NEWER, which `extends` the line OLDER was wrapped from at WIDTH.
///
/// Text added at the end of a line can change only its last grapheme and what
/// follows it, and the earliest row that reaches is the one before the last:
/// when the line ended in spaces dropped at a break, the last row is empty and
/// the grapheme the new text can join sits on the row above. Every row before
/// that one is kept, so a line streamed a token at a time costs a token.
pub fn rewrap(mut older: Wrapped, newer: &Hanging, width: u16) -> Wrapped {
    let keep = older.rows.len().saturating_sub(2);
    let from = older.starts.get(keep).copied().unwrap_or(0);
    older.rows.truncate(keep);
    older.starts.truncate(keep);
    lay(newer, width, older, from)
}

/// LINE's rows from byte FROM of its text on, after the rows WRAPPED holds.
fn lay(line: &Hanging, width: u16, mut wrapped: Wrapped, from: usize) -> Wrapped {
    let width = width.max(1) as usize;
    let expanded: Vec<Span<'static>>;
    let spans: &[Span<'static>] = if line.line.spans.iter().any(|span| span.content.contains('\t')) {
        let mut column = 0;
        expanded = line
            .line
            .spans
            .iter()
            .map(|span| Span::styled(cells::expand_tabs(&span.content, &mut column), span.style))
            .collect();
        &expanded
    } else {
        &line.line.spans
    };
    let indent = line.indent.as_ref().filter(|span| cells::width(&span.content) < width);
    let indent_cells = indent.map_or(0, |span| cells::width(&span.content));
    let rows = Rows::new(width, indent_cells, from, wrapped.rows.is_empty());
    let ranges = if spans.iter().all(|span| cells::printable_ascii(&span.content)) {
        ascii_rows(spans, rows)
    } else {
        grapheme_rows(spans, rows)
    };
    let mut reader = Reader { spans, index: 0, start: 0 };
    for range in ranges {
        let continued = !wrapped.rows.is_empty();
        wrapped.starts.push(range.start);
        wrapped.rows.push(reader.row(if continued { indent } else { None }, range));
    }
    if let (Some(style), [row]) = (line.rule, wrapped.rows.as_mut_slice()) {
        let used: usize = row.spans.iter().map(|span| cells::width(&span.content)).sum();
        if used + 2 < width {
            row.spans.push(Span::styled(format!(" {}", "─".repeat(width - used - 1)), style));
        }
    }
    wrapped
}

/// Where rows begin and end: the decisions both ways of measuring share.
struct Rows {
    width: usize,
    indent: usize,
    /// Cells taken on the row being filled, counting the indent it starts with.
    used: usize,
    /// Where the row being filled begins, and where its glyphs end once it has any.
    start: usize,
    end: Option<usize>,
    done: Vec<Range<usize>>,
}

impl Rows {
    fn new(width: usize, indent: usize, from: usize, first: bool) -> Self {
        Rows { width, indent, used: if first { 0 } else { indent }, start: from, end: None, done: Vec::new() }
    }

    fn place(&mut self, start: usize, end: usize, cells: usize) {
        if self.end.is_none() {
            self.start = start;
        }
        self.end = Some(end);
        self.used += cells;
    }

    /// End the row, the next one beginning at NEXT.
    fn push(&mut self, next: usize) {
        let end = self.end.take().unwrap_or(self.start);
        self.done.push(self.start..end);
        self.start = next;
        self.used = self.indent;
    }

    /// Place a run of blanks or of non-blanks whole, when it fits or is a break.
    /// False when it is a word wider than any row, to be broken between glyphs.
    fn whole(&mut self, start: usize, end: usize, cells: usize, blank: bool) -> bool {
        if self.used + cells <= self.width {
            self.place(start, end, cells);
            return true;
        }
        // The break falls here. A run of spaces IS the break and is dropped;
        // a word moves down whole, unless it is wider than the pane -- and then
        // it breaks between graphemes, never through one two cells wide.
        if blank {
            self.push(end);
            return true;
        }
        if self.end.is_some() {
            self.push(start);
        }
        if self.used + cells <= self.width {
            self.place(start, end, cells);
            return true;
        }
        false
    }

    fn glyph(&mut self, start: usize, end: usize, cells: usize) {
        if self.used + cells > self.width && self.end.is_some() {
            self.push(start);
        }
        self.place(start, end, cells);
    }

    fn finish(mut self) -> Vec<Range<usize>> {
        let start = self.start;
        self.push(start);
        self.done
    }
}

/// Rows for text that is all printable ASCII: a byte is a glyph a cell wide,
/// so runs are found without a table and a long word is broken by arithmetic.
fn ascii_rows(spans: &[Span<'static>], mut rows: Rows) -> Vec<Range<usize>> {
    let from = rows.start;
    let mut run: Option<(usize, bool)> = None;
    let mut offset = 0;
    for span in spans {
        let begin = offset;
        offset += span.content.len();
        if offset <= from {
            continue;
        }
        let bytes = span.content.as_bytes();
        for at in from.max(begin)..offset {
            let blank = bytes[at - begin] == b' ';
            match run {
                Some((_, kind)) if kind == blank => {}
                Some((start, kind)) => {
                    ascii_run(&mut rows, start, at, kind);
                    run = Some((at, blank));
                }
                None => run = Some((at, blank)),
            }
        }
    }
    if let Some((start, blank)) = run {
        ascii_run(&mut rows, start, offset, blank);
    }
    rows.finish()
}

fn ascii_run(rows: &mut Rows, start: usize, end: usize, blank: bool) {
    if rows.whole(start, end, end - start, blank) {
        return;
    }
    let mut at = start;
    while at < end {
        if rows.used + 1 > rows.width && rows.end.is_some() {
            rows.push(at);
        }
        let take = rows.width.saturating_sub(rows.used).max(1).min(end - at);
        rows.place(at, at + take, take);
        at += take;
    }
}

/// Rows for any other text, measured a grapheme at a time.
fn grapheme_rows(spans: &[Span<'static>], mut rows: Rows) -> Vec<Range<usize>> {
    let from = rows.start;
    let mut glyphs: Vec<(usize, usize, usize, bool)> = Vec::new();
    let mut offset = 0;
    for span in spans {
        let begin = offset;
        offset += span.content.len();
        if offset <= from {
            continue;
        }
        for (at, grapheme, cells) in cells::glyphs(&span.content) {
            if begin + at >= from {
                glyphs.push((begin + at, begin + at + grapheme.len(), cells, grapheme == " "));
            }
        }
    }
    let mut at = 0;
    while at < glyphs.len() {
        let blank = glyphs[at].3;
        let end = glyphs[at..]
            .iter()
            .position(|glyph| glyph.3 != blank)
            .map_or(glyphs.len(), |length| at + length);
        let run = &glyphs[at..end];
        let cells: usize = run.iter().map(|glyph| glyph.2).sum();
        if !rows.whole(run[0].0, run[run.len() - 1].1, cells, blank) {
            for &(start, stop, width, _) in run {
                rows.glyph(start, stop, width);
            }
        }
        at = end;
    }
    rows.finish()
}

/// Reads rows out of a line's spans in order, never going back over a span it
/// has passed. Neighbours written the same way are joined, so a row costs what
/// it says rather than a span per piece.
struct Reader<'a> {
    spans: &'a [Span<'static>],
    index: usize,
    start: usize,
}

impl Reader<'_> {
    fn row(&mut self, indent: Option<&Span<'static>>, range: Range<usize>) -> Line<'static> {
        let mut joined: Vec<Span<'static>> = indent.into_iter().cloned().collect();
        while let Some(span) = self.spans.get(self.index) {
            let end = self.start + span.content.len();
            if end <= range.start {
                self.index += 1;
                self.start = end;
                continue;
            }
            if self.start >= range.end {
                break;
            }
            let text = &span.content[range.start.max(self.start) - self.start..range.end.min(end) - self.start];
            if !text.is_empty() {
                match joined.last_mut() {
                    Some(previous) if previous.style == span.style => previous.content.to_mut().push_str(text),
                    _ => joined.push(Span::styled(text.to_string(), span.style)),
                }
            }
            if end > range.end {
                break;
            }
            self.index += 1;
            self.start = end;
        }
        Line::from(joined)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_of(wrapped: &Wrapped) -> Vec<String> {
        wrapped
            .rows
            .iter()
            .map(|row| row.spans.iter().map(|span| span.content.as_ref()).collect())
            .collect()
    }

    /// A small deterministic generator, so a failing input can be run again.
    struct Dice(u64);

    impl Dice {
        fn roll(&mut self, sides: usize) -> usize {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            (self.0 % sides as u64) as usize
        }
    }

    #[test]
    fn a_wide_line_wraps_by_the_cells_it_takes() {
        let text = "日本語のテキストが三十文字続く長い一行をここに書いてある";
        let wrapped = wrap(&Hanging::plain(Line::from(text.to_string())), 20);
        assert!(wrapped.rows.iter().all(|row| row.width() <= 20), "a row ran past the pane: {wrapped:?}");
        assert_eq!(text_of(&wrapped).concat(), text);
        assert_eq!(wrapped.rows.len(), 3);
    }

    #[test]
    fn a_wide_glyph_with_one_cell_left_starts_the_next_row() {
        let wrapped = wrap(&Hanging::plain(Line::from("a日本".to_string())), 4);
        assert_eq!(text_of(&wrapped), ["a日", "本"]);
    }

    #[test]
    fn a_tab_keeps_the_indentation_it_stands_for() {
        let wrapped = wrap(&Hanging::plain(Line::from("\tindented".to_string())), 40);
        assert_eq!(text_of(&wrapped), ["    indented"]);
    }

    #[test]
    fn a_rule_runs_to_the_edge_after_a_title_that_fits() {
        let title = Line::from(vec![Span::raw("─ "), Span::raw("bash ls")]);
        let wrapped = wrap(&Hanging::ruled(title, Style::default()), 20);
        assert_eq!(wrapped.rows.len(), 1);
        assert_eq!(cells::width(&text_of(&wrapped)[0]), 20);
        let long = Line::from("a title far too long to leave room for any rule".to_string());
        let wrapped = wrap(&Hanging::ruled(long, Style::default()), 20);
        assert!(text_of(&wrapped).iter().all(|row| !row.contains('─')), "{wrapped:?}");
    }

    #[test]
    fn a_word_goes_down_whole_and_its_row_keeps_the_indent() {
        let line = Line::from(vec![Span::raw("› "), Span::raw("first second third".to_string())]);
        let wrapped = wrap(&Hanging::under("  ", Style::default(), line), 10);
        // A space that fits stays on its row; one that does not is the break.
        assert_eq!(text_of(&wrapped), ["› first ", "  second ", "  third"]);
    }

    #[test]
    fn only_text_added_at_the_end_extends_a_line() {
        let line = |spans: Vec<Span<'static>>| Hanging::plain(Line::from(spans));
        let older = line(vec![Span::raw("› "), Span::raw("hello")]);
        assert!(line(vec![Span::raw("› "), Span::raw("hello world")]).extends(&older));
        assert!(line(vec![Span::raw("› "), Span::raw("hello"), Span::raw("!")]).extends(&older));
        assert!(!line(vec![Span::raw("› "), Span::raw("help")]).extends(&older));
        assert!(!line(vec![Span::raw("› "), Span::styled("hello world", Style::default().bold())]).extends(&older));
        assert!(!line(vec![Span::raw("› ")]).extends(&older));
    }

    #[test]
    fn both_measures_break_ascii_into_the_same_rows() {
        const PIECES: [&str; 9] = ["a", "word", "wrap", " ", "  ", "abcdefghijklmnopqrstuvwxyz", "x-y", "", "q"];
        let mut dice = Dice(0x9e37_79b9_7f4a_7c15);
        for _ in 0..2000 {
            let spans: Vec<Span<'static>> = (0..1 + dice.roll(4))
                .map(|_| {
                    let text: String = (0..dice.roll(8)).map(|_| PIECES[dice.roll(PIECES.len())]).collect();
                    let style = if dice.roll(2) == 0 { Style::default() } else { Style::default().bold() };
                    Span::styled(text, style)
                })
                .collect();
            let width = 1 + dice.roll(24);
            let indent = dice.roll(width.min(4));
            let first = dice.roll(2) == 0;
            let by_bytes = ascii_rows(&spans, Rows::new(width, indent, 0, first));
            let by_graphemes = grapheme_rows(&spans, Rows::new(width, indent, 0, first));
            assert_eq!(by_bytes, by_graphemes, "{spans:?} at width {width}, indent {indent}");
        }
    }

    #[test]
    fn a_line_that_grows_rewraps_to_what_wrapping_it_whole_gives() {
        const TOKENS: [&str; 13] = [
            "word ", "a", " ", "   ", "abcdefghijklmnopqrstuvwxyz", "日本", "語 ", "e", "\u{301}", "👩",
            "\u{200d}💻", "\t", "x",
        ];
        let mut dice = Dice(0x2545_f491_4f6c_dd1d);
        for _ in 0..300 {
            let width = 1 + dice.roll(30) as u16;
            let indented = dice.roll(2) == 0;
            let make = |text: &str| {
                let line = Line::from(vec![Span::raw("› "), Span::raw(text.to_string())]);
                if indented {
                    Hanging::under("  ", Style::default(), line)
                } else {
                    Hanging::plain(line)
                }
            };
            let mut text = String::new();
            let mut grown = wrap(&make(&text), width);
            for _ in 0..40 {
                text.push_str(TOKENS[dice.roll(TOKENS.len())]);
                let line = make(&text);
                grown = rewrap(grown, &line, width);
                let whole = wrap(&line, width);
                assert_eq!(text_of(&grown), text_of(&whole), "{text:?} at width {width}");
                assert_eq!(grown.rows, whole.rows, "{text:?} at width {width}");
                assert_eq!(grown.starts, whole.starts, "{text:?} at width {width}");
            }
        }
    }
}
