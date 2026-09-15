//! The colours the frame is drawn in, and the marks a session's state is shown by.

use ratatui::style::Color;

pub const ACCENT: Color = Color::Indexed(13);
pub const DIM: Color = Color::Indexed(244);
pub const BORDER: Color = Color::Indexed(240);

/// A character as well as a colour, so the state still reads on a monochrome
/// terminal.
pub fn state_mark(state: &str) -> (&'static str, Color) {
    match state {
        "working" => ("*", Color::Indexed(220)),
        "stuck" => ("!", Color::Indexed(203)),
        "suspended" => ("~", Color::Indexed(111)),
        "stopping" => (".", DIM),
        _ => ("-", BORDER),
    }
}
