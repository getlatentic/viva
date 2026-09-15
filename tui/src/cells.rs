//! Text measured the way the terminal draws it: in cells, not characters.
//!
//! `日本語` is three characters and six cells. Counted as characters, a row of
//! wide text holds twice what fits, and the cursor sits inside what was typed.

use unicode_segmentation::{GraphemeIndices, UnicodeSegmentation};
use unicode_width::UnicodeWidthStr;

/// How far apart tab stops are. A transcript pane is narrower than the
/// terminal a stop of eight was chosen for.
pub const TAB: usize = 4;

/// The cells TEXT takes on screen.
pub fn width(text: &str) -> usize {
    if printable_ascii(text) {
        return text.len();
    }
    glyphs(text).map(|(_, _, cells)| cells).sum()
}

/// Each grapheme of TEXT, with its byte offset and the cells it takes.
///
/// By ratatui's measure, since ratatui draws it: a grapheme is as wide as
/// Unicode says, and one that comes to no width -- a control character, say --
/// is not drawn at all.
pub fn glyphs(text: &str) -> Glyphs<'_> {
    if printable_ascii(text) {
        Glyphs::Ascii { text, at: 0 }
    } else {
        Glyphs::Unicode(text.grapheme_indices(true))
    }
}

/// One cell a byte, which covers most text without a table lookup.
fn printable_ascii(text: &str) -> bool {
    text.bytes().all(|byte| (b' '..=b'~').contains(&byte))
}

pub enum Glyphs<'a> {
    Ascii { text: &'a str, at: usize },
    Unicode(GraphemeIndices<'a>),
}

impl<'a> Iterator for Glyphs<'a> {
    type Item = (usize, &'a str, usize);

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Glyphs::Ascii { text, at } => {
                let text: &'a str = text;
                let start = *at;
                let grapheme = text.get(start..start + 1)?;
                *at += 1;
                Some((start, grapheme, 1))
            }
            Glyphs::Unicode(graphemes) => {
                graphemes.next().map(|(start, grapheme)| (start, grapheme, grapheme.width()))
            }
        }
    }
}

/// The longest start of TEXT that fits in ROOM cells. A glyph two cells wide
/// with one cell left for it is left out, not split.
pub fn cut(text: &str, room: usize) -> &str {
    let mut used = 0;
    for (start, _, cells) in glyphs(text) {
        if used + cells > room {
            return &text[..start];
        }
        used += cells;
    }
    text
}

/// TEXT within ROOM cells, ending in `…` when it did not fit.
pub fn clip(text: &str, room: usize) -> String {
    if width(text) <= room {
        return text.to_string();
    }
    format!("{}…", cut(text, room.saturating_sub(1)).trim_end())
}

/// TEXT followed by the spaces that make it ROOM cells wide. Never shorter
/// than TEXT: padding does not cut.
pub fn pad(text: &str, room: usize) -> String {
    let short = room.saturating_sub(width(text));
    let mut padded = String::with_capacity(text.len() + short);
    padded.push_str(text);
    padded.extend(std::iter::repeat(' ').take(short));
    padded
}

/// TEXT with each tab turned into the spaces that reach the next stop. COLUMN
/// is the cell TEXT starts at, and is left at the cell it ends at. A terminal
/// draws a tab by moving the cursor; ratatui draws it as nothing.
pub fn expand_tabs(text: &str, column: &mut usize) -> String {
    let mut expanded = String::with_capacity(text.len());
    for (_, grapheme, cells) in glyphs(text) {
        if grapheme == "\t" {
            let spaces = TAB - *column % TAB;
            expanded.extend(std::iter::repeat(' ').take(spaces));
            *column += spaces;
        } else {
            expanded.push_str(grapheme);
            *column += cells;
        }
    }
    expanded
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;
    use ratatui::widgets::Paragraph;
    use ratatui::Terminal;

    #[test]
    fn the_cells_counted_are_the_cells_ratatui_fills() {
        for text in ["abc", "日本語", "🙂 ok", "e\u{301}x", "a\u{1b}b", "👩\u{200d}💻!", "１２３", "a\u{7f}b"] {
            let mut terminal = Terminal::new(TestBackend::new(24, 1)).unwrap();
            terminal
                .draw(|frame| frame.render_widget(Paragraph::new(format!("{text}|")), frame.area()))
                .unwrap();
            let drawn: Vec<&str> = terminal.backend().buffer().content().iter().map(|cell| cell.symbol()).collect();
            let bar = drawn.iter().position(|symbol| *symbol == "|").expect("the marker was drawn");
            assert_eq!(width(text), bar, "{text:?}");
            assert_eq!(glyphs(text).map(|(_, _, cells)| cells).sum::<usize>(), bar, "{text:?}");
        }
    }

    #[test]
    fn clipping_counts_cells_and_leaves_out_a_glyph_that_would_be_split() {
        assert_eq!(clip("abcdef", 4), "abc…");
        assert_eq!(clip("fits", 4), "fits");
        assert_eq!(clip("日本語テキスト", 7), "日本語…");
        assert_eq!(clip("日本語テキスト", 8), "日本語…", "half of テ was kept");
        assert_eq!(cut("a日本", 2), "a");
    }

    #[test]
    fn padding_counts_cells_and_never_cuts() {
        assert_eq!(pad("日本", 6), "日本  ");
        assert_eq!(pad("ab", 4), "ab  ");
        assert_eq!(pad("toolong", 3), "toolong");
    }

    #[test]
    fn a_tab_reaches_the_next_stop_from_where_it_starts() {
        let mut column = 0;
        assert_eq!(expand_tabs("a\tb", &mut column), "a   b");
        assert_eq!(column, 5);
        let mut column = 0;
        assert_eq!(expand_tabs("\t日\tx", &mut column), "    日  x");
        let mut column = 2;
        assert_eq!(expand_tabs("\tx", &mut column), "  x");
    }
}
