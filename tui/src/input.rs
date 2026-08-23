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
    /// Ask what this session has retained, and show it.
    Learned,
    /// A line beginning with `/`, handled here and never sent onward.
    Command(String),
    /// Ask for every session matching what has been typed into the picker.
    Search(String),
    /// Continue a recorded session in a new tab.
    Resume(String),
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

    // The learned overlay is a look, not a mode: any key closes it. Making a
    // person learn a second way out of a read-only panel is a tax on curiosity.
    if model.showing_learned {
        model.showing_learned = false;
        return Action::None;
    }

    if model.focus == Focus::Picker {
        return picker_key(key, model);
    }

    if control {
        return match key.code {
            KeyCode::Char('p') | KeyCode::Char('f') => {
                model.focus = Focus::Picker;
                model.picker.query.clear();
                model.picker.selection = 0;
                model.picker.searching = true;
                return Action::Search(String::new());
            }
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
            KeyCode::Char('l') => Action::Learned,
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

    // The slash menu owns a few keys while it is up, and only those. It is a
    // suggestion over the prompt, not a mode: every other key still types.
    let menu = crate::commands::matching(&model.input);
    if !menu.is_empty() {
        match key.code {
            KeyCode::Up => {
                model.command_selection = model
                    .command_selection
                    .checked_sub(1)
                    .unwrap_or(menu.len() - 1);
                return Action::None;
            }
            KeyCode::Down => {
                model.command_selection = (model.command_selection + 1) % menu.len();
                return Action::None;
            }
            // Tab COMPLETES rather than runs. Completing and running on the
            // same key means a person who wanted `/find vite` gets `/find`.
            KeyCode::Tab => {
                let chosen = menu[model.command_selection.min(menu.len() - 1)];
                model.input = format!("{} ", chosen.name);
                model.command_selection = 0;
                return Action::None;
            }
            KeyCode::Enter => {
                let chosen = menu[model.command_selection.min(menu.len() - 1)];
                model.input.clear();
                model.command_selection = 0;
                follow(model);
                return Action::Command(chosen.name.to_string());
            }
            KeyCode::Esc => {
                // Dismiss the menu by abandoning the line, which is what Esc
                // means everywhere else here.
                model.input.clear();
                model.command_selection = 0;
                return Action::None;
            }
            _ => {}
        }
    }

    match key.code {
        KeyCode::Enter => {
            let text = model.input.trim().to_string();
            model.input.clear();
            if text.is_empty() {
                Action::None
            } else {
                follow(model);
                // EVERY slash line is handled locally, including one naming no
                // command at all. Falling through to the model with a typo is a
                // paid request answered by a guess at what you meant -- and
                // `/quit` answered by "Goodbye! If you need more help later"
                // is the model being polite about a key you pressed to leave.
                if text.starts_with('/') {
                    Action::Command(text)
                } else {
                    Action::Send(text)
                }
            }
        }
        KeyCode::Backspace => {
            model.input.pop();
            model.command_selection = 0;
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
            // The list shrinks as it narrows, so a highlight further down than
            // the new list would point at nothing.
            model.command_selection = 0;
            Action::None
        }
        _ => Action::None,
    }
}

/// The picker's keys. A mode, so every key here means one thing.
fn picker_key(key: &KeyEvent, model: &mut Model) -> Action {
    match key.code {
        KeyCode::Esc => {
            model.focus = Focus::Input;
            Action::None
        }
        KeyCode::Up => {
            model.picker.move_selection(-1);
            Action::None
        }
        KeyCode::Down => {
            model.picker.move_selection(1);
            Action::None
        }
        KeyCode::Enter => match model.picker.selected() {
            Some(found) => {
                let id = found.id.clone();
                model.focus = Focus::Input;
                Action::Resume(id)
            }
            None => Action::None,
        },
        KeyCode::Backspace => {
            model.picker.query.pop();
            model.picker.searching = true;
            Action::Search(model.picker.query.clone())
        }
        KeyCode::Char(character) => {
            model.picker.query.push(character);
            model.picker.selection = 0;
            model.picker.searching = true;
            Action::Search(model.picker.query.clone())
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
            // The picker is over everything, so it answers first -- otherwise
            // a click meant for it lands on whatever it is covering.
            for (index, area) in &hits.command_rows {
                if inside(*area, column, row) {
                    let menu = crate::commands::matching(&model.input);
                    if let Some(chosen) = menu.get(*index) {
                        model.input.clear();
                        model.command_selection = 0;
                        return Action::Command(chosen.name.to_string());
                    }
                }
            }
            if let Some(area) = hits.picker {
                if inside(area, column, row) {
                    for (index, row_area) in &hits.picker_rows {
                        if inside(*row_area, column, row) {
                            model.picker.selection = *index;
                            if let Some(found) = model.picker.selected() {
                                let id = found.id.clone();
                                model.focus = Focus::Input;
                                return Action::Resume(id);
                            }
                        }
                    }
                    return Action::None;
                }
                model.focus = Focus::Input;
                return Action::None;
            }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Model;

    fn typed(model: &mut Model, text: &str) -> Action {
        for character in text.chars() {
            key_pressed(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE), model);
        }
        key_pressed(&KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE), model)
    }

    #[test]
    fn a_slash_line_never_reaches_the_model() {
        // `/quit` was sent as a prompt, and the model politely said goodbye
        // while the client stayed exactly where it was. A paid request
        // answered by a guess at what somebody meant.
        let mut model = Model::new("/w".into());
        // An alias resolves to its canonical command, because the menu that
        // matched it knows which one it is. `/find vite` has a space, so no
        // menu is up and the line passes through as typed -- the argument is
        // the point of it. `/nonsense` matches nothing and reaches the
        // dispatcher to be refused there.
        for (line, expected) in [
            ("/quit", "/quit"),
            ("/exit", "/quit"),
            ("/detach", "/quit"),
            ("/help", "/help"),
            ("/new", "/new"),
            ("/find vite", "/find vite"),
            ("/nonsense", "/nonsense"),
        ] {
            match typed(&mut model, line) {
                Action::Command(captured) => assert_eq!(captured, expected, "typing {line}"),
                other => panic!("{line} became {other:?} instead of a command"),
            }
        }
    }

    #[test]
    fn the_menu_offers_only_what_the_dispatcher_accepts() {
        // Three copies of a list is three chances for the menu to offer
        // something the dispatcher refuses -- and refusing an unknown command
        // is the whole feature, so that would be the feature attacking itself.
        for command in crate::commands::COMMANDS {
            assert!(
                crate::commands::lookup(command.name).is_some(),
                "{} is offered and not dispatchable",
                command.name
            );
            for alias in command.aliases {
                assert!(
                    crate::commands::lookup(alias).is_some(),
                    "{alias} is an alias of {} and resolves to nothing",
                    command.name
                );
            }
        }
    }

    #[test]
    fn the_menu_narrows_and_gets_out_of_the_way() {
        // It appears on `/`, narrows as it is typed, and leaves once an
        // argument is being written -- a menu over the top of an argument is
        // in the way rather than in help.
        assert!(crate::commands::matching("/").len() > 3, "no menu on a bare slash");
        let narrowed = crate::commands::matching("/f");
        assert!(!narrowed.is_empty());
        assert!(narrowed.len() < crate::commands::matching("/").len(), "typing did not narrow");
        assert!(crate::commands::matching("/find vite").is_empty(), "the menu outstayed its use");
        assert!(crate::commands::matching("hello").is_empty(), "a plain line raised a menu");
        assert!(crate::commands::matching("read src/main.rs").is_empty());
    }

    #[test]
    fn tab_completes_and_enter_runs() {
        // The same key doing both means somebody who wanted `/find vite` gets
        // `/find`.
        let mut model = Model::new("/w".into());
        for character in "/fi".chars() {
            key_pressed(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE), &mut model);
        }
        let completed = key_pressed(&KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE), &mut model);
        assert_eq!(completed, Action::None, "tab ran the command instead of completing it");
        assert_eq!(model.input, "/find ", "tab did not complete the name");
        // And with a trailing space the menu is gone, so Enter sends the line.
        match key_pressed(&KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE), &mut model) {
            Action::Command(line) => assert_eq!(line, "/find"),
            other => panic!("enter after completing became {other:?}"),
        }
    }

    #[test]
    fn an_ordinary_line_still_reaches_the_model() {
        // The guard must not eat the thing it guards.
        let mut model = Model::new("/w".into());
        match typed(&mut model, "what is in this folder") {
            Action::Send(text) => assert_eq!(text, "what is in this folder"),
            other => panic!("an ordinary prompt became {other:?}"),
        }
        // A slash in the MIDDLE is not a command; paths have slashes in them.
        match typed(&mut model, "read src/main.rs") {
            Action::Send(text) => assert_eq!(text, "read src/main.rs"),
            other => panic!("a path became {other:?}"),
        }
    }

    #[test]
    fn an_empty_line_is_not_a_prompt_worth_paying_for() {
        let mut model = Model::new("/w".into());
        assert_eq!(typed(&mut model, "   "), Action::None);
    }
}
