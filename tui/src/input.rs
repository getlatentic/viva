//! Turning a keypress or a click into something to do.
//!
//! Returns an ACTION rather than doing the work. The model can be changed here
//! -- moving a highlight is not an effect anybody needs to see -- but anything
//! that touches the socket is named and handed back, which is what lets a test
//! press a key and assert on the outcome without a daemon.

use crate::model::{Focus, Model};
use crate::ui::Hitboxes;
use crossterm::event::{
    Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    None,
    Quit,
    Cancel,
    Send(String),
    Open(String),
    NewTab,
    CloseTab,
    SelectTab(usize),
    Refresh,
}

pub fn read(event: &Event, model: &mut Model, hits: &Hitboxes) -> Action {
    match event {
        Event::Key(key) if key.kind == KeyEventKind::Press => key_pressed(key, model),
        Event::Mouse(mouse) => clicked(mouse, model, hits),
        Event::Resize(_, _) => Action::None,
        _ => Action::None,
    }
}

fn key_pressed(key: &KeyEvent, model: &mut Model) -> Action {
    let control = key.modifiers.contains(KeyModifiers::CONTROL);
    let busy = model
        .current_conversation()
        .map(|conversation| conversation.busy)
        .unwrap_or(false);

    if control {
        return match key.code {
            // Ctrl-C stops the TURN and only leaves when there is none.
            // Quitting on the key people press to stop a runaway command is how
            // a client loses a session someone was in the middle of.
            KeyCode::Char('c') => {
                if busy {
                    Action::Cancel
                } else {
                    Action::Quit
                }
            }
            KeyCode::Char('d') if model.input.is_empty() => Action::Quit,
            KeyCode::Char('n') => Action::NewTab,
            KeyCode::Char('w') => Action::CloseTab,
            KeyCode::Char('r') => Action::Refresh,
            _ => Action::None,
        };
    }

    // With the sidebar focused the arrows walk the list; with the input
    // focused they belong to the prompt. Without this distinction every key is
    // the prompt's, and a list on screen is a list you cannot walk.
    if model.focus == Focus::Sessions {
        return match key.code {
            KeyCode::Up => {
                model.move_selection(-1);
                Action::None
            }
            KeyCode::Down => {
                model.move_selection(1);
                Action::None
            }
            KeyCode::Enter => model
                .selected_session()
                .map(|session| Action::Open(session.id.clone()))
                .unwrap_or(Action::None),
            KeyCode::Esc => {
                model.focus = Focus::Input;
                Action::None
            }
            KeyCode::Tab => next_tab(model),
            KeyCode::Char(character) => {
                // A printable key means the person has started typing, so the
                // prompt takes it rather than the sidebar swallowing it.
                model.focus = Focus::Input;
                model.input.push(character);
                Action::None
            }
            _ => Action::None,
        };
    }

    match key.code {
        KeyCode::Enter => {
            let text = model.input.trim().to_string();
            model.input.clear();
            if text.is_empty() {
                Action::None
            } else {
                follow(model);
                Action::Send(text)
            }
        }
        KeyCode::Backspace => {
            model.input.pop();
            Action::None
        }
        KeyCode::Tab => next_tab(model),
        KeyCode::Esc => {
            model.focus = Focus::Input;
            Action::None
        }
        KeyCode::PageUp => scroll_by(model, 10),
        KeyCode::PageDown => scroll_by(model, -10),
        KeyCode::Home => {
            // The far end of the scrollback, clamped when it is drawn.
            if let Some(conversation) = model.conversations.get_mut(&model.current) {
                conversation.following = false;
                conversation.scroll = u16::MAX;
            }
            Action::None
        }
        KeyCode::End => {
            follow(model);
            Action::None
        }
        KeyCode::Up => {
            // Up from the prompt reaches the list, which is where a person
            // looks first when they want another session.
            model.focus = Focus::Sessions;
            Action::None
        }
        KeyCode::Char(character) => {
            model.input.push(character);
            Action::None
        }
        _ => Action::None,
    }
}

fn next_tab(model: &mut Model) -> Action {
    if model.tabs.len() < 2 {
        return Action::None;
    }
    Action::SelectTab((model.tab + 1) % model.tabs.len())
}

fn follow(model: &mut Model) {
    if let Some(conversation) = model.conversations.get_mut(&model.current) {
        conversation.following = true;
        conversation.scroll = 0;
    }
}

fn scroll_by(model: &mut Model, lines: i32) -> Action {
    if let Some(conversation) = model.conversations.get_mut(&model.current) {
        let current = conversation.scroll as i32;
        let next = (current + lines).max(0);
        conversation.scroll = next.min(u16::MAX as i32) as u16;
        // Reaching the bottom resumes following, so a person who scrolled back
        // and then returned does not have to know there is a mode.
        conversation.following = next == 0;
    }
    Action::None
}

fn clicked(mouse: &MouseEvent, model: &mut Model, hits: &Hitboxes) -> Action {
    let column = mouse.column;
    let row = mouse.row;
    match mouse.kind {
        // The wheel scrolls whatever it is over, which is the one mouse
        // behaviour nobody thinks about before using.
        MouseEventKind::ScrollUp => scroll_by(model, 3),
        MouseEventKind::ScrollDown => scroll_by(model, -3),
        MouseEventKind::Down(MouseButton::Left) => {
            if let Some(area) = hits.new_tab {
                if inside(area, column, row) {
                    return Action::NewTab;
                }
            }
            for (index, area) in &hits.tabs {
                if inside(*area, column, row) {
                    return Action::SelectTab(*index);
                }
            }
            if inside(hits.sessions, column, row) {
                // A click gives the sidebar the keyboard as well as selecting,
                // so the arrows work from where the eye already is.
                model.focus = Focus::Sessions;
                for (index, area) in &hits.session_rows {
                    if inside(*area, column, row) {
                        model.selection = *index;
                        if let Some(session) = model.sessions.get(*index) {
                            return Action::Open(session.id.clone());
                        }
                    }
                }
                return Action::None;
            }
            if inside(hits.transcript, column, row) || inside(hits.input, column, row) {
                model.focus = Focus::Input;
            }
            Action::None
        }
        _ => Action::None,
    }
}

fn inside(area: ratatui::layout::Rect, column: u16, row: u16) -> bool {
    column >= area.x
        && column < area.x.saturating_add(area.width)
        && row >= area.y
        && row < area.y.saturating_add(area.height)
}
