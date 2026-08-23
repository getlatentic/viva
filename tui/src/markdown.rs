//! Model output is markdown. Drawing it as characters shows the punctuation.
//!
//! A reply arrives with `**bold**`, backticked names, headings, lists and
//! tables in it, because that is what a model writes. Printing it literally
//! puts the asterisks on the screen and asks a person to read past them -- and
//! it wastes the one thing the markup is for, which is telling a filename
//! apart from a sentence at a glance.
//!
//! THE PARSING IS NOT OURS. It is `pulldown-cmark`, the CommonMark parser
//! rustdoc and mdBook use. A hand-written one covered what models usually emit
//! and quietly failed the rest -- links kept their brackets, block quotes and
//! escapes were not markup at all -- and every gap found later would have been
//! one more special case in a parser nobody set out to write. What is ours is
//! below it: turning a stream of events into styled rows a pane can draw.

use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};
use ratatui::prelude::*;

const CODE: Color = Color::Indexed(180);
const HEADING: Color = Color::Indexed(111);
const LINK: Color = Color::Indexed(75);
const QUOTE: Color = Color::Indexed(244);

/// One drawn line: what it says, and what to repeat in front of the rows it
/// wraps onto, so a list item's second row sits under its own text rather than
/// under the bullet.
pub struct Drawn {
    pub spans: Vec<Span<'static>>,
    pub indent: String,
}

/// A whole message, as lines.
pub fn render(text: &str) -> Vec<Drawn> {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    let mut layout = Layout::default();
    for event in Parser::new_ext(text, options) {
        layout.take(event);
    }
    layout.finish()
}

/// A table being collected. Column widths are not known until the last row has
/// been read, so the rows are held and drawn together.
#[derive(Default)]
struct Table {
    rows: Vec<Vec<Vec<Span<'static>>>>,
    row: Vec<Vec<Span<'static>>>,
    cell: Vec<Span<'static>>,
}

#[derive(Default)]
struct Layout {
    drawn: Vec<Drawn>,
    row: Vec<Span<'static>>,
    styles: Vec<Style>,
    /// One entry per open list: the next number, or nothing for a bullet.
    lists: Vec<Option<u64>>,
    /// What continuation rows sit behind, and what this one line leads with.
    indent: String,
    hanging: Option<String>,
    code: bool,
    table: Option<Table>,
    link: Option<String>,
}

impl Layout {
    fn style(&self) -> Style {
        self.styles.iter().fold(Style::default(), |carried, each| carried.patch(*each))
    }

    fn open(&mut self, style: Style) {
        self.styles.push(style);
    }

    fn close(&mut self) {
        self.styles.pop();
    }

    /// Text goes to the cell being read when there is one, and to the line
    /// otherwise: a table is laid out later and cannot use the row buffer.
    fn write(&mut self, text: String, style: Style) {
        if text.is_empty() {
            return;
        }
        let span = Span::styled(text, style);
        match self.table.as_mut() {
            Some(table) => table.cell.push(span),
            None => self.row.push(span),
        }
    }

    /// End the line being built, if there is one.
    ///
    /// THE BLOCK PREFIX IS DRAWN HERE, once, for every kind of block. A
    /// quotation's rule was worked out and never put on the line, because the
    /// list path pushed its own lead and the quote path had nobody to push
    /// its -- so a quoted line rendered as an ordinary one.
    fn flush(&mut self) {
        if self.row.is_empty() {
            return;
        }
        let indent = self.hanging.take().unwrap_or_else(|| self.indent.clone());
        let mut spans = Vec::with_capacity(self.row.len() + 1);
        if !self.indent.is_empty() {
            spans.push(Span::styled(self.indent.clone(), Style::default().fg(QUOTE)));
        }
        spans.append(&mut self.row);
        self.drawn.push(Drawn { spans, indent });
    }

    /// A blank line between blocks, never two together and never leading.
    fn gap(&mut self) {
        self.flush();
        if self.drawn.last().map(blank).unwrap_or(true) {
            return;
        }
        self.drawn.push(Drawn { spans: vec![Span::raw(String::new())], indent: String::new() });
    }

    /// The bullet or number this item leads with, and how far its own text is
    /// indented -- which is where the rows it wraps onto belong.
    fn marker(&mut self) {
        let lead = self.indent.clone();
        let mark = match self.lists.last_mut() {
            Some(Some(number)) => {
                let mark = format!("{number}. ");
                *number += 1;
                mark
            }
            _ => "• ".to_string(),
        };
        self.hanging = Some(format!("{lead}{}", " ".repeat(mark.chars().count())));
        self.row.push(Span::styled(mark, Style::default().fg(HEADING)));
    }

    fn take(&mut self, event: Event<'_>) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) => self.text(&text),
            Event::Code(text) => {
                let style = self.style().patch(Style::default().fg(CODE));
                self.write(text.to_string(), style);
            }
            // Wrapping happens later and against the real pane width, so a
            // break the author did not ask for is a space.
            Event::SoftBreak => {
                let style = self.style();
                self.write(" ".into(), style);
            }
            Event::HardBreak => self.flush(),
            Event::Rule => {
                self.gap();
                self.drawn.push(Drawn {
                    spans: vec![Span::styled("─".repeat(24), Style::default().fg(QUOTE))],
                    indent: String::new(),
                });
                self.gap();
            }
            Event::Html(text) | Event::InlineHtml(text) => {
                let style = self.style();
                self.write(text.trim_end().to_string(), style);
            }
            _ => {}
        }
    }

    fn text(&mut self, text: &str) {
        if !self.code {
            let style = self.style();
            return self.write(text.to_string(), style);
        }
        // Inside a fence nothing is markup and every newline is real: a shell
        // command full of asterisks is the case where guessing is worst.
        for (index, line) in text.split('\n').enumerate() {
            if index > 0 {
                self.flush();
            }
            if line.is_empty() {
                continue;
            }
            self.hanging = Some(format!("{}  ", self.indent));
            self.row.push(Span::raw("  ".to_string()));
            self.row.push(Span::styled(line.to_string(), Style::default().fg(CODE)));
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => {}
            Tag::Heading { .. } => {
                self.gap();
                self.open(Style::default().fg(HEADING).add_modifier(Modifier::BOLD));
            }
            Tag::List(first) => {
                if self.lists.is_empty() {
                    self.gap();
                } else {
                    self.flush();
                    self.indent.push_str("  ");
                }
                self.lists.push(first);
            }
            Tag::Item => self.marker(),
            Tag::CodeBlock(kind) => {
                self.gap();
                self.code = true;
                if let CodeBlockKind::Fenced(language) = kind {
                    if !language.is_empty() {
                        let indent = self.indent.clone();
                        self.drawn.push(Drawn {
                            spans: vec![Span::styled(
                                format!("{indent}  {language}"),
                                Style::default().fg(CODE).add_modifier(Modifier::DIM),
                            )],
                            indent: String::new(),
                        });
                    }
                }
            }
            Tag::BlockQuote(_) => {
                self.gap();
                self.indent.push_str("│ ");
                self.open(Style::default().fg(QUOTE).add_modifier(Modifier::ITALIC));
            }
            Tag::Emphasis => self.open(Style::default().add_modifier(Modifier::ITALIC)),
            Tag::Strong => self.open(Style::default().add_modifier(Modifier::BOLD)),
            Tag::Strikethrough => self.open(Style::default().add_modifier(Modifier::CROSSED_OUT)),
            Tag::Link { dest_url, .. } => {
                self.link = Some(dest_url.to_string());
                self.open(Style::default().fg(LINK).add_modifier(Modifier::UNDERLINED));
            }
            Tag::Table(_) => {
                self.gap();
                self.table = Some(Table::default());
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => self.gap(),
            TagEnd::Heading(_) => {
                self.flush();
                self.close();
            }
            TagEnd::List(_) => {
                self.flush();
                self.lists.pop();
                if self.lists.is_empty() {
                    self.gap();
                } else {
                    self.indent.pop();
                    self.indent.pop();
                }
            }
            TagEnd::Item => self.flush(),
            TagEnd::CodeBlock => {
                self.flush();
                self.code = false;
                self.gap();
            }
            TagEnd::BlockQuote(_) => {
                self.flush();
                self.indent.pop();
                self.indent.pop();
                self.close();
                self.gap();
            }
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough => self.close(),
            TagEnd::Link => {
                self.close();
                // The address, when the text does not already carry it: a
                // terminal cannot follow a link, so text alone throws it away.
                if let Some(url) = self.link.take() {
                    let shown: String =
                        self.row.iter().map(|span| span.content.as_ref()).collect();
                    if !shown.contains(url.trim_end_matches('/')) {
                        let style = self.style().patch(Style::default().fg(QUOTE));
                        self.write(format!(" ({url})"), style);
                    }
                }
            }
            TagEnd::TableCell => {
                if let Some(table) = self.table.as_mut() {
                    let cell = std::mem::take(&mut table.cell);
                    table.row.push(cell);
                }
            }
            TagEnd::TableRow | TagEnd::TableHead => {
                if let Some(table) = self.table.as_mut() {
                    let row = std::mem::take(&mut table.row);
                    table.rows.push(row);
                }
            }
            TagEnd::Table => self.draw_table(),
            _ => {}
        }
    }

    /// The rows as columns. Drawn as characters a table is a wall of pipes
    /// with a row of dashes through it -- the one construct actively harder to
    /// read as its own source than as anything else.
    fn draw_table(&mut self) {
        let Some(table) = self.table.take() else {
            return;
        };
        let columns = table.rows.iter().map(Vec::len).max().unwrap_or(0);
        let mut widths = vec![0usize; columns];
        for row in &table.rows {
            for (column, cell) in row.iter().enumerate() {
                widths[column] = widths[column].max(width_of(cell));
            }
        }
        let emphasis = Style::default().fg(HEADING).add_modifier(Modifier::BOLD);
        for (index, row) in table.rows.iter().enumerate() {
            let mut spans: Vec<Span<'static>> = vec![Span::raw(self.indent.clone())];
            for (column, width) in widths.iter().enumerate() {
                let empty = Vec::new();
                let cell = row.get(column).unwrap_or(&empty);
                // The first row is the header, marked rather than ruled: a
                // rule under it costs a row and says less.
                for span in cell {
                    let style = if index == 0 { span.style.patch(emphasis) } else { span.style };
                    spans.push(Span::styled(span.content.to_string(), style));
                }
                // The last column is not padded: a run of spaces to the pane
                // edge is invisible and costs the wrap.
                if column + 1 < columns {
                    spans.push(Span::raw(" ".repeat(width - width_of(cell) + 2)));
                }
            }
            self.drawn.push(Drawn { spans, indent: format!("{}  ", self.indent) });
        }
        self.gap();
    }

    fn finish(mut self) -> Vec<Drawn> {
        self.flush();
        while self.drawn.last().map(blank) == Some(true) {
            self.drawn.pop();
        }
        if self.drawn.is_empty() {
            self.drawn.push(Drawn { spans: vec![Span::raw(String::new())], indent: String::new() });
        }
        self.drawn
    }
}

fn blank(drawn: &Drawn) -> bool {
    drawn.spans.iter().all(|span| span.content.trim().is_empty())
}

/// How wide a cell lands once its markup has become styling.
fn width_of(cell: &[Span<'static>]) -> usize {
    cell.iter().map(|span| span.content.chars().count()).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shown(drawn: &Drawn) -> String {
        drawn.spans.iter().map(|span| span.content.as_ref()).collect()
    }

    fn lines(text: &str) -> Vec<String> {
        render(text).iter().map(shown).collect()
    }

    fn styled(text: &str, needle: &str) -> Style {
        for drawn in render(text) {
            for span in &drawn.spans {
                if span.content.contains(needle) {
                    return span.style;
                }
            }
        }
        panic!("{needle:?} is not in the output of {text:?}");
    }

    #[test]
    fn the_punctuation_is_the_style_and_does_not_stay_on_screen() {
        assert_eq!(lines("a small **React** app using `vite`"),
                   vec!["a small React app using vite"]);
        assert!(styled("a **React** app", "React").add_modifier.contains(Modifier::BOLD));
        assert_eq!(styled("using `vite` here", "vite").fg, Some(CODE));
    }

    #[test]
    fn a_name_inside_a_bold_run_is_both() {
        // Models write `**`package.json`**`. Taking the bold body as literal
        // text left the backticks on screen inside the bold.
        let style = styled("- **`package.json`** lists the dependencies", "package.json");
        assert!(style.add_modifier.contains(Modifier::BOLD), "lost the bold");
        assert_eq!(style.fg, Some(CODE), "lost the code colour");
    }

    #[test]
    fn an_unclosed_mark_is_a_character_not_a_style() {
        // A model writing about `2 * 3` or a glob is not opening emphasis.
        for text in ["2 * 3 = 6", "use *.rs to match"] {
            assert_eq!(lines(text), vec![text.to_string()], "{text:?} was treated as markup");
        }
    }

    #[test]
    fn a_list_item_wraps_under_its_own_text() {
        let drawn = render("- the source lives under src/");
        assert_eq!(shown(&drawn[0]), "• the source lives under src/");
        assert_eq!(drawn[0].indent, "  ", "a wrapped item would sit under the bullet");
        let numbered = render("12. install uv");
        assert_eq!(shown(&numbered[0]), "12. install uv");
        assert_eq!(numbered[0].indent, "    ");
    }

    #[test]
    fn a_numbered_item_keeps_its_number_on_the_same_line() {
        // A list whose items are paragraphs -- what CommonMark calls a loose
        // list, and what a model writes whenever it leaves a blank line --
        // opens a paragraph INSIDE the item. Flushing the line when a
        // paragraph opened drew the number alone with its text below it.
        let rows = lines("1. first thing\n\n2. second thing");
        assert!(rows.iter().any(|row| row.starts_with("1. first thing")),
                "the number was drawn on its own line: {rows:?}");
        assert!(rows.iter().any(|row| row.starts_with("2. second thing")), "{rows:?}");
    }

    #[test]
    fn a_wrapped_line_of_code_stays_under_the_code() {
        // Everything inside a fence is offset, and a line long enough to wrap
        // began again at the pane edge -- outside the block it belongs to.
        let drawn = render("```sh\nnpm install  # a comment long enough to wrap somewhere\n```");
        let code = drawn.iter().find(|row| shown(row).contains("npm install")).unwrap();
        assert!(code.indent.ends_with("  "),
                "a wrapped code line would start at the edge: {:?}", code.indent);
    }

    #[test]
    fn a_nested_list_is_drawn_inside_the_one_that_holds_it() {
        // The hand-written renderer indented by whatever whitespace the source
        // happened to use, so the same structure drew differently depending on
        // how the model spaced it.
        let rows = lines("- outer\n    - inner\n- outer again");
        let inner = rows.iter().find(|row| row.contains("inner")).unwrap();
        let outer = rows.iter().find(|row| row.contains("outer again")).unwrap();
        assert!(inner.starts_with("  "), "the nested item is not indented: {inner:?}");
        assert!(!outer.starts_with(' '), "the outer item is indented: {outer:?}");
    }

    #[test]
    fn a_heading_reads_as_one_without_its_hashes() {
        assert!(lines("## Scripts").contains(&"Scripts".to_string()));
        assert!(styled("## Scripts", "Scripts").add_modifier.contains(Modifier::BOLD));
        // Not every hash opens a heading.
        assert!(lines("#1 in the list").contains(&"#1 in the list".to_string()));
    }

    #[test]
    fn nothing_inside_a_fence_is_markup() {
        let rows = lines("run this:\n```bash\nrm *.o && echo `date`\n```\ndone");
        assert!(rows.iter().any(|row| row.contains("rm *.o && echo `date`")),
                "the fence was parsed as markup: {rows:?}");
        assert!(rows.iter().any(|row| row.trim() == "done"));
    }

    #[test]
    fn a_table_is_drawn_as_columns_and_not_as_pipes() {
        let rows = lines("| Prerequisite | How to satisfy |\n\
|---|---|\n\
| Node.js | Install from nodejs.org |\n\
| Git | Only to clone |\n\n\
after");
        assert!(!rows.iter().any(|row| row.contains('|')), "pipes survived: {rows:?}");
        assert!(!rows.iter().any(|row| row.contains("---")), "the divider survived");
        assert!(rows.iter().any(|row| row.trim() == "after"), "the line after was lost");
        let node = rows.iter().find(|row| row.contains("Install")).unwrap();
        let git = rows.iter().find(|row| row.contains("Only")).unwrap();
        assert_eq!(node.find("Install"), git.find("Only"), "columns do not line up:\n{node}\n{git}");
    }

    #[test]
    fn a_cell_is_measured_by_what_it_shows_not_by_its_markup() {
        // A cell written `**Git**` is three characters wide on screen and
        // seven in the source. Padding by the source pushes every later
        // column out by the width of punctuation that is no longer there.
        let rows = lines("| a | b |\n|---|---|\n| **Git** | x |\n| gitgit | y |");
        let first = rows.iter().find(|row| row.contains('x')).unwrap();
        let second = rows.iter().find(|row| row.contains('y')).unwrap();
        assert_eq!(first.find('x'), second.find('y'), "markup was counted as width");
    }

    #[test]
    fn a_link_keeps_its_text_and_does_not_lose_its_address() {
        // A terminal cannot follow a link, so text alone throws the address
        // away. The hand-written renderer showed the brackets instead.
        let line = lines("see [the docs](https://example.com/guide) for more").join(" ");
        assert!(!line.contains('['), "the brackets survived: {line:?}");
        assert!(line.contains("the docs"), "the text was lost");
        assert!(line.contains("https://example.com/guide"), "the address was lost: {line:?}");
        // Not repeated when the text already is the address.
        let bare = lines("see <https://example.com/guide> now").join(" ");
        assert_eq!(bare.matches("example.com").count(), 1, "the address was said twice");
    }

    #[test]
    fn a_quotation_is_marked_as_one() {
        // Not markup the hand-written renderer knew at all: a quoted line kept
        // its `>` and read as part of the sentence around it.
        let rows = lines("> it was already broken\n\nso we fixed it");
        let quoted = rows.iter().find(|row| row.contains("already broken")).unwrap();
        assert!(!quoted.contains('>'), "the marker survived: {quoted:?}");
        assert!(quoted.contains('│'), "a quotation is not marked: {quoted:?}");
    }

    #[test]
    fn an_escape_is_the_character_it_escapes() {
        // `\*` is an asterisk. Not markup the hand-written renderer knew, so
        // the backslash stayed on screen.
        assert_eq!(lines(r"a \*literal\* asterisk"), vec!["a *literal* asterisk"]);
    }

    #[test]
    fn an_empty_reply_is_one_empty_line_not_nothing() {
        assert_eq!(render("").len(), 1);
        assert_eq!(lines(""), vec![""]);
    }
}
