//! Model output is markdown. Drawing it as characters shows the punctuation.
//!
//! A reply arrives with `**bold**`, backticked names, headings and lists in
//! it, because that is what a model writes. Printing it literally puts the
//! asterisks on the screen and asks a person to read past them -- and it wastes
//! the one thing the markup is for, which is telling a filename apart from a
//! sentence at a glance.
//!
//! LINE BY LINE, because the transcript is. Nothing here reflows a paragraph
//! or holds state beyond a fenced block, so a line rendered while the model is
//! still typing is the same line it will be when the reply is finished.

use ratatui::prelude::*;

const CODE: Color = Color::Indexed(180);
const HEADING: Color = Color::Indexed(111);

/// One drawn line: what it says, and what to repeat in front of the rows it
/// wraps onto, so a list item's second row sits under its own text rather than
/// under the bullet.
pub struct Drawn {
    pub spans: Vec<Span<'static>>,
    pub indent: String,
}

/// Whether the parser is inside a fenced code block, carried between lines.
#[derive(Default, Clone, Copy, PartialEq, Eq)]
pub struct Fence(bool);

impl Fence {
    pub fn open(self) -> bool {
        self.0
    }
}

/// Render one line, given whether the line before it left a fence open.
pub fn line(text: &str, fence: Fence) -> (Drawn, Fence) {
    if text.trim_start().starts_with("```") {
        let language = text.trim().trim_start_matches('`').trim();
        let label = if fence.open() || language.is_empty() {
            String::new()
        } else {
            format!("  {language}")
        };
        return (
            Drawn {
                spans: vec![Span::styled(label, Style::default().fg(CODE).add_modifier(Modifier::DIM))],
                indent: String::new(),
            },
            Fence(!fence.open()),
        );
    }
    if fence.open() {
        // Inside a fence nothing is markup. A shell command full of asterisks
        // and backticks is the exact case where guessing is worst.
        return (
            Drawn {
                spans: vec![Span::styled(text.to_string(), Style::default().fg(CODE))],
                indent: "  ".into(),
            },
            fence,
        );
    }
    if let Some(drawn) = heading(text) {
        return (drawn, fence);
    }
    let (marker, body, indent) = list_item(text);
    let mut spans = marker;
    spans.extend(inline(body));
    (Drawn { spans, indent }, fence)
}

/// A whole message, as lines.
pub fn render(text: &str) -> Vec<Drawn> {
    let mut fence = Fence::default();
    text.split('\n')
        .map(|row| {
            let (drawn, next) = line(row, fence);
            fence = next;
            drawn
        })
        .collect()
}

/// `## Title` reads as a title, without the hashes a person has to look past.
fn heading(text: &str) -> Option<Drawn> {
    let hashes = text.chars().take_while(|character| *character == '#').count();
    if hashes == 0 || hashes > 6 || !text[hashes..].starts_with(' ') {
        return None;
    }
    Some(Drawn {
        spans: vec![Span::styled(
            text[hashes + 1..].to_string(),
            Style::default().fg(HEADING).add_modifier(Modifier::BOLD),
        )],
        indent: String::new(),
    })
}

fn bullet<'a>(blank: &str, mark: String, body: &'a str) -> (Vec<Span<'static>>, &'a str, String) {
    let width = mark.chars().count();
    (
        vec![
            Span::raw(blank.to_string()),
            Span::styled(mark, Style::default().fg(HEADING)),
        ],
        body,
        format!("{blank}{}", " ".repeat(width)),
    )
}

/// The bullet or number in front of a list item, and how far its own text is
/// indented -- which is where the rows it wraps onto belong.
fn list_item(text: &str) -> (Vec<Span<'static>>, &str, String) {
    let lead = text.len() - text.trim_start().len();
    let (blank, rest) = text.split_at(lead);
    for opener in ["- ", "* ", "+ "] {
        if let Some(body) = rest.strip_prefix(opener) {
            return bullet(blank, "• ".into(), body);
        }
    }
    let digits = rest.chars().take_while(char::is_ascii_digit).count();
    if digits > 0 {
        if let Some(body) = rest[digits..].strip_prefix(". ") {
            return bullet(blank, format!("{}. ", &rest[..digits]), body);
        }
    }
    (Vec::new(), text, blank.to_string())
}

/// `**bold**`, `` `code` `` and `*italic*`, left alone when unclosed.
///
/// An unclosed run is literal on purpose: a model writing about multiplication
/// or a glob pattern is not opening emphasis, and swallowing the rest of the
/// line to look for a partner it does not have is how one stray character
/// restyles a paragraph.
fn inline(text: &str) -> Vec<Span<'static>> {
    let mut spans = styled(text, Style::default(), 0);
    if spans.is_empty() {
        spans.push(Span::raw(String::new()));
    }
    spans
}

/// Marks nest: a filename inside a bold run is written `**`name`**` and is
/// both. Emphasis recurses and code does not -- inside backticks the text is
/// what it says it is.
///
/// DEPTH IS CAPPED. Each level consumes at least two characters, so a long
/// line of nothing but asterisks would otherwise recurse as deep as it is
/// long.
fn styled(text: &str, outer: Style, depth: usize) -> Vec<Span<'static>> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut plain = String::new();
    let characters: Vec<char> = text.chars().collect();
    let mut at = 0;
    while at < characters.len() {
        let matched = (depth < 8)
            .then(|| {
                ["**", "`", "*", "_"].into_iter().find_map(|mark| {
                    let marks: Vec<char> = mark.chars().collect();
                    characters[at..].starts_with(marks.as_slice()).then(|| ()).and_then(|()| {
                        closing(&characters, at + marks.len(), &marks)
                            .map(|end| (mark, marks.len(), end))
                    })
                })
            })
            .flatten();
        match matched {
            Some((mark, width, end)) => {
                if !plain.is_empty() {
                    spans.push(Span::styled(std::mem::take(&mut plain), outer));
                }
                let body: String = characters[at + width..end].iter().collect();
                let inner = outer.patch(style_for(mark));
                if mark == "`" {
                    spans.push(Span::styled(body, inner));
                } else {
                    spans.extend(styled(&body, inner, depth + 1));
                }
                at = end + width;
            }
            None => {
                plain.push(characters[at]);
                at += 1;
            }
        }
    }
    if !plain.is_empty() {
        spans.push(Span::styled(plain, outer));
    }
    spans
}

fn style_for(mark: &str) -> Style {
    match mark {
        "**" => Style::default().add_modifier(Modifier::BOLD),
        "`" => Style::default().fg(CODE),
        _ => Style::default().add_modifier(Modifier::ITALIC),
    }
}

/// Where the run closes, or nothing. An empty run (`****`) is not emphasis.
fn closing(characters: &[char], from: usize, marks: &[char]) -> Option<usize> {
    (from..characters.len())
        .find(|at| characters[*at..].starts_with(marks))
        .filter(|at| *at > from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drawn(text: &str) -> Drawn {
        line(text, Fence::default()).0
    }

    fn shown(drawn: &Drawn) -> String {
        drawn.spans.iter().map(|span| span.content.as_ref()).collect()
    }

    #[test]
    fn the_punctuation_is_the_style_and_does_not_stay_on_screen() {
        // A reply arrives full of `**bold**` and backticks because that is
        // what a model writes. Drawn literally, a person reads past them.
        let result = drawn("a small **React** app using `vite`");
        assert_eq!(shown(&result), "a small React app using vite");
        let bold = result.spans.iter().find(|span| span.content == "React").unwrap();
        assert!(bold.style.add_modifier.contains(Modifier::BOLD));
        let code = result.spans.iter().find(|span| span.content == "vite").unwrap();
        assert_eq!(code.style.fg, Some(CODE));
    }

    #[test]
    fn an_unclosed_mark_is_a_character_not_a_style() {
        // A model writing about `2 * 3` or a glob is not opening emphasis, and
        // swallowing the rest of the line to look for a partner it does not
        // have is how one stray character restyles a paragraph.
        for text in ["2 * 3 = 6", "use *.rs to match", "**unclosed bold"] {
            assert_eq!(shown(&drawn(text)), text, "{text:?} was treated as markup");
        }
    }

    #[test]
    fn a_name_inside_a_bold_run_is_both() {
        // Models write `**`package.json`**`. Taking the bold body as literal
        // text left the backticks on screen inside the bold.
        let result = drawn("- **`package.json`** lists the dependencies");
        assert_eq!(shown(&result), "• package.json lists the dependencies");
        let name = result.spans.iter().find(|span| span.content == "package.json").unwrap();
        assert!(name.style.add_modifier.contains(Modifier::BOLD), "lost the bold");
        assert_eq!(name.style.fg, Some(CODE), "lost the code colour");
    }

    #[test]
    fn a_list_item_wraps_under_its_own_text() {
        let result = drawn("- the source lives under src/");
        assert_eq!(shown(&result), "• the source lives under src/");
        assert_eq!(result.indent, "  ", "a wrapped item would sit under the bullet");
        let numbered = drawn("  12. install uv");
        assert_eq!(shown(&numbered), "  12. install uv");
        assert_eq!(numbered.indent, "      ");
    }

    #[test]
    fn a_heading_reads_as_one_without_its_hashes() {
        let result = drawn("## Scripts");
        assert_eq!(shown(&result), "Scripts");
        assert!(result.spans[0].style.add_modifier.contains(Modifier::BOLD));
        // Not every hash opens a heading.
        assert_eq!(shown(&drawn("#1 in the list")), "#1 in the list");
        assert_eq!(shown(&drawn("####### too many")), "####### too many");
    }

    #[test]
    fn nothing_inside_a_fence_is_markup() {
        // A shell command full of asterisks and backticks is the exact case
        // where guessing is worst.
        let rendered = render("run this:\n```bash\nrm *.o && echo `date`\n```\ndone");
        let texts: Vec<String> = rendered.iter().map(shown).collect();
        assert_eq!(texts[2], "rm *.o && echo `date`");
        assert_eq!(texts[4], "done");
        assert_eq!(rendered[2].spans[0].style.fg, Some(CODE));
    }

    #[test]
    fn a_fence_that_is_never_closed_does_not_eat_the_rest_of_the_reply() {
        // It does -- correctly -- until the reply ends, which is what the
        // model asked for. What must not happen is the state leaking into the
        // NEXT message, so rendering starts closed every time.
        let rendered = render("```\nstill open");
        assert_eq!(shown(&rendered[1]), "still open");
        let after = render("plain **bold**");
        assert_eq!(shown(&after[0]), "plain bold");
    }
}
