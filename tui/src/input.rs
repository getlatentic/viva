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
    /// Continue a recorded session in a new tab, in the directory it was
    /// recorded in. The picker lists sessions from EVERY directory, so
    /// resuming one into the client's own cwd looks for it where it is not.
    Resume { id: String, cwd: String },
    /// Show or hide the sessions list beside the transcript.
    ToggleSidebar,
    /// Run a shell command in the session's directory, without asking the
    /// model to do it. The model does not see it.
    Shell(String),
    /// Offer the models this daemon can reach.
    Models,
    /// Ask the daemon again what its dynamic providers serve. A local server's
    /// list is whatever somebody pulled onto the machine, and pulling one is
    /// exactly the moment the answer here is stale.
    RefreshModels,
    /// Start a session on the named model, in a new tab.
    UseModel(String),
    /// Answer on the named model in this session, from its next turn. The turn
    /// running now finishes on the model it started with.
    SwitchModel(String),
    /// Delete the session with this id, and what is recorded under it, for
    /// good. Only ever the answer to a question: one key names the session and
    /// a second says yes.
    Delete(String),
}

pub fn read(event: &Event, model: &mut Model, hits: &Hitboxes) -> Action {
    match event {
        Event::Key(key) if key.kind == KeyEventKind::Press => key_pressed(key, model, hits),
        Event::Mouse(mouse) => clicked(mouse, model, hits),
        Event::Paste(text) => pasted(text, model),
        Event::Resize(_, _) => Action::None,
        _ => Action::None,
    }
}

fn key_pressed(key: &KeyEvent, model: &mut Model, hits: &Hitboxes) -> Action {
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
    if model.focus == Focus::Models {
        return models_key(key, model);
    }
    if model.focus == Focus::Deleting {
        return deleting_key(key, model);
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
            // Abandon the line. Readline's binding, because a prompt you
            // cannot clear is one you empty with held Backspace -- and Esc
            // already means "put the keyboard back on the prompt", which is
            // not the same wish.
            KeyCode::Char('u') => {
                model.input.clear();
                model.command_selection = 0;
                Action::None
            }
            KeyCode::Char('n') => Action::NewTab,
            KeyCode::Char('b') => Action::ToggleSidebar,
            KeyCode::Char('w') => Action::CloseTab,
            KeyCode::Char('r') => Action::Refresh,
            KeyCode::Char('l') => Action::Learned,
            KeyCode::Char('o') => {
                // Expand every tool result, not one. Per-block expansion needs
                // a cursor in the transcript, and the question a person asks
                // is "show me what these printed", not "show me that one".
                if let Some(conversation) = model.conversations.get_mut(&model.current) {
                    conversation.expanded = !conversation.expanded;
                    conversation.revision += 1;
                }
                Action::None
            }
            _ => Action::None,
        };
    }

    // Moving through the conversation, from wherever the keyboard is: reading
    // back is never more than a key away, whichever column has it.
    match key.code {
        KeyCode::PageUp => return scroll_by(model, 10),
        KeyCode::PageDown => return scroll_by(model, -10),
        KeyCode::Home => {
            // The far end of the scrollback, clamped when it is drawn.
            if let Some(conversation) = model.conversations.get_mut(&model.current) {
                conversation.to_top();
            }
            return Action::None;
        }
        KeyCode::End => {
            follow(model);
            return Action::None;
        }
        _ => {}
    }
    let column_shown = hits.sessions.width > 0;
    if model.focus == Focus::Transcript {
        return transcript_key(key, model, column_shown);
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
            // Open it if it is running, continue it if it is not. Both are
            // `the conversation I picked`, and which verb it takes is the
            // client's business rather than the person's.
            KeyCode::Enter => match model.selected_row() {
                Some(crate::model::Listed::Live(session)) => Action::Open(session.id.clone()),
                Some(crate::model::Listed::Earlier(recorded)) => Action::Resume {
                    id: recorded.id.clone(),
                    cwd: recorded.cwd.clone(),
                },
                None => Action::None,
            },
            KeyCode::Right => {
                model.focus = reading(model);
                Action::None
            }
            // Asked first, by what the session is about, so what goes is the
            // conversation a person meant.
            KeyCode::Backspace | KeyCode::Delete => {
                if let Some((id, subject)) = model.selected_row().map(|row| (row.id().to_string(), row.subject())) {
                    model.ask_delete(&id, subject);
                }
                Action::None
            }
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
                if crate::commands::looks_like_command(&text) {
                    Action::Command(text)
                } else if let Some(shell) = text.strip_prefix('!') {
                    Action::Shell(shell.trim().to_string())
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
        KeyCode::Up => {
            // Up from the prompt reads back through the conversation. With
            // nothing said there is nothing to read, and the list of earlier
            // conversations is what a person is looking for.
            if !model.is_blank() {
                model.focus = Focus::Transcript;
                return scroll_by(model, 1);
            }
            if column_shown {
                model.focus_sessions();
            }
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

/// The model picker's keys. A mode, so every key here means one thing -- which
/// is what lets a digit mean `take that one` rather than `type a digit`.
fn models_key(key: &KeyEvent, model: &mut Model) -> Action {
    match key.code {
        KeyCode::Esc => {
            model.focus = Focus::Input;
            Action::None
        }
        KeyCode::Up => {
            model.models.move_selection(-1);
            Action::None
        }
        KeyCode::Down => {
            model.models.move_selection(1);
            Action::None
        }
        KeyCode::Backspace => {
            model.models.query.pop();
            model.models.selection = 0;
            Action::None
        }
        // A DIGIT TAKES A ROW, counted from what is on screen. This is why the
        // search is not itself an item in the list: if it were, the first
        // keystroke would have to be `go to the list` before a number meant
        // anything.
        KeyCode::Char(ch @ '1'..='9') => {
            match model.models.at_digit(ch as usize - '0' as usize) {
                Some(offer) => {
                    model.focus = Focus::Input;
                    Action::SwitchModel(offer.label)
                }
                None => Action::None,
            }
        }
        // A new session on the highlighted model, for when the conversation here
        // should stay on the one it has.
        KeyCode::Char('n') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            match model.models.selected() {
                Some(offer) => {
                    model.focus = Focus::Input;
                    Action::UseModel(offer.label)
                }
                None => Action::None,
            }
        }
        KeyCode::Char('r') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            model.models.refreshing = true;
            Action::RefreshModels
        }
        KeyCode::Char(ch) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
            model.models.type_into_query(ch);
            Action::None
        }
        KeyCode::Enter => match model.models.selected() {
            Some(offer) => {
                model.focus = Focus::Input;
                Action::SwitchModel(offer.label)
            }
            None => Action::None,
        },
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
                let (id, cwd) = (found.id.clone(), found.cwd.clone());
                model.focus = Focus::Input;
                Action::Resume { id, cwd }
            }
            None => Action::None,
        },
        KeyCode::Backspace => {
            model.picker.query.pop();
            model.picker.searching = true;
            Action::Search(model.picker.query.clone())
        }
        // Before the printable arm, which does not look at modifiers and would
        // otherwise type a literal `u` into the search it was meant to empty.
        KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
            model.picker.query.clear();
            model.picker.selection = 0;
            model.picker.searching = true;
            Action::Search(String::new())
        }
        // Not backspace, which edits the search.
        KeyCode::Char('d') if key.modifiers.contains(KeyModifiers::CONTROL) => ask_about_found(model),
        KeyCode::Delete => ask_about_found(model),
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
        conversation.follow();
    }
}

fn scroll_by(model: &mut Model, lines: i32) -> Action {
    if let Some(conversation) = model.conversations.get_mut(&model.current) {
        conversation.scroll_by(lines);
    }
    Action::None
}

/// The transcript's keys. Down past the newest line hands the keyboard back to
/// the prompt, so reading back and carrying on are one direction of travel.
fn transcript_key(key: &KeyEvent, model: &mut Model, column_shown: bool) -> Action {
    match key.code {
        KeyCode::Up => scroll_by(model, 1),
        KeyCode::Down => {
            let at_end = model
                .current_conversation()
                .map(|conversation| conversation.following && !conversation.owes_scroll())
                .unwrap_or(true);
            if !at_end {
                return scroll_by(model, -1);
            }
            model.focus = Focus::Input;
            Action::None
        }
        KeyCode::Left if column_shown => {
            model.focus_sessions();
            Action::None
        }
        KeyCode::Esc | KeyCode::Enter => {
            model.focus = Focus::Input;
            Action::None
        }
        KeyCode::Tab => next_tab(model),
        // Typing means writing again, so the prompt takes the key.
        KeyCode::Backspace => {
            model.focus = Focus::Input;
            model.input.pop();
            Action::None
        }
        KeyCode::Char(character) => {
            model.focus = Focus::Input;
            model.input.push(character);
            Action::None
        }
        _ => Action::None,
    }
}

/// Where the keyboard goes to read: the transcript, unless nothing is in it.
fn reading(model: &Model) -> Focus {
    if model.is_blank() {
        Focus::Input
    } else {
        Focus::Transcript
    }
}

/// Ask whether to delete the session the picker has highlighted.
fn ask_about_found(model: &mut Model) -> Action {
    if let Some((id, subject)) = model.picker.selected().map(|found| (found.id.clone(), found.subject())) {
        model.ask_delete(&id, subject);
    }
    Action::None
}

/// The delete question's keys: enter or `y` deletes, esc or `n` keeps the
/// session, and anything else leaves the question standing.
fn deleting_key(key: &KeyEvent, model: &mut Model) -> Action {
    let delete = match key.code {
        KeyCode::Enter | KeyCode::Char('y') => true,
        KeyCode::Esc | KeyCode::Char('n') => false,
        _ => return Action::None,
    };
    let Some(deletion) = model.deleting.take() else {
        model.focus = Focus::Input;
        return Action::None;
    };
    model.focus = deletion.from;
    if delete {
        Action::Delete(deletion.id)
    } else {
        Action::None
    }
}

/// Over the sessions column the wheel moves its window and leaves the
/// selection where it is; anywhere else it scrolls the transcript.
fn wheel(model: &mut Model, hits: &Hitboxes, column: u16, row: u16, lines: i32) -> Action {
    if inside(hits.sessions, column, row) {
        let total = crate::sidebar::rows(model).len();
        model.session_list.wheel(-lines as isize, total, hits.sessions.height as usize);
        return Action::None;
    }
    scroll_by(model, lines)
}

/// Pasted text goes in whole, and does not submit.
///
/// A terminal with no bracketed paste sends a newline as Enter, so a pasted
/// function was one prompt per line -- each answered and each paid for. Arriving
/// as one event, the newlines are the paste's own and are kept: what reaches the
/// model is what was copied. The input is drawn on one line, so DRAW_INPUT shows
/// them as a glyph rather than trying to lay them out.
///
/// Carriage returns are normalised, because a paste can carry either ending and
/// a stray \r inside a prompt is invisible until something downstream splits on
/// it.
fn pasted(text: &str, model: &mut Model) -> Action {
    if text.is_empty() {
        return Action::None;
    }
    let normalised = text.replace("\r\n", "\n").replace('\r', "\n");
    match model.focus {
        // Only where typing goes. A paste into a picker is a search term the
        // filter never sees, and into the transcript it is nothing at all --
        // better ignored than silently appended to a prompt nobody is writing.
        Focus::Input => {
            model.input.push_str(&normalised);
            Action::None
        }
        _ => Action::None,
    }
}

fn clicked(mouse: &MouseEvent, model: &mut Model, hits: &Hitboxes) -> Action {
    let column = mouse.column;
    let row = mouse.row;
    match mouse.kind {
        // The wheel scrolls whatever it is over, which is the one mouse
        // behaviour nobody thinks about before using.
        MouseEventKind::ScrollUp => wheel(model, hits, column, row, 3),
        MouseEventKind::ScrollDown => wheel(model, hits, column, row, -3),
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
                                let (id, cwd) = (found.id.clone(), found.cwd.clone());
                                model.focus = Focus::Input;
                                return Action::Resume { id, cwd };
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
                model.focus_sessions();
                for (id, area) in &hits.session_rows {
                    if inside(*area, column, row) {
                        model.select_session(id);
                        return match model.selected_row() {
                            Some(crate::model::Listed::Live(session)) => {
                                Action::Open(session.id.clone())
                            }
                            Some(crate::model::Listed::Earlier(recorded)) => Action::Resume {
                                id: recorded.id.clone(),
                                cwd: recorded.cwd.clone(),
                            },
                            None => Action::None,
                        };
                    }
                }
                return Action::None;
            }
            if inside(hits.transcript, column, row) {
                model.focus = reading(model);
            } else if inside(hits.input, column, row) {
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
            key_pressed(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE), model, &Hitboxes::default());
        }
        key_pressed(&KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE), model, &Hitboxes::default())
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
            key_pressed(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE), &mut model, &Hitboxes::default());
        }
        let completed = key_pressed(&KeyEvent::new(KeyCode::Tab, KeyModifiers::NONE), &mut model, &Hitboxes::default());
        assert_eq!(completed, Action::None, "tab ran the command instead of completing it");
        assert_eq!(model.input, "/find ", "tab did not complete the name");
        // And with a trailing space the menu is gone, so Enter sends the line.
        match key_pressed(&KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE), &mut model, &Hitboxes::default()) {
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
    fn control_u_abandons_the_line() {
        let mut model = Model::new("/w".into());
        for character in "a half written prompt".chars() {
            key_pressed(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE), &mut model, &Hitboxes::default());
        }
        let cleared =
            key_pressed(&KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL), &mut model, &Hitboxes::default());
        assert_eq!(cleared, Action::None, "clearing the line asked the daemon for something");
        assert!(model.input.is_empty(), "ctrl-u left {:?} behind", model.input);
        // And it must not be mistaken for quitting, which is what the other
        // empty-input control key does.
        assert_ne!(cleared, Action::Quit);
    }

    #[test]
    fn control_u_empties_the_picker_search_rather_than_typing_into_it() {
        let mut model = Model::new("/w".into());
        key_pressed(&KeyEvent::new(KeyCode::Char('p'), KeyModifiers::CONTROL), &mut model, &Hitboxes::default());
        for character in "vite".chars() {
            key_pressed(&KeyEvent::new(KeyCode::Char(character), KeyModifiers::NONE), &mut model, &Hitboxes::default());
        }
        assert_eq!(model.picker.query, "vite");
        match key_pressed(&KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL), &mut model, &Hitboxes::default()) {
            Action::Search(query) => assert!(query.is_empty(), "searched for {query:?}"),
            other => panic!("ctrl-u in the picker became {other:?}"),
        }
        assert!(model.picker.query.is_empty(), "ctrl-u typed into the query it should have emptied");
    }

    #[test]
    fn a_model_picked_is_for_this_session_and_ctrl_n_takes_it_to_a_new_one() {
        let mut model = Model::new("/w".into());
        model.models.absorb(vec![crate::model::ModelOffer { label: "local/qwen".into(), id: "qwen".into() }]);
        model.focus = Focus::Models;
        assert_eq!(
            key_pressed(&KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE), &mut model, &Hitboxes::default()),
            Action::SwitchModel("local/qwen".into())
        );
        model.focus = Focus::Models;
        assert_eq!(
            key_pressed(&KeyEvent::new(KeyCode::Char('1'), KeyModifiers::NONE), &mut model, &Hitboxes::default()),
            Action::SwitchModel("local/qwen".into())
        );
        model.focus = Focus::Models;
        assert_eq!(
            key_pressed(&KeyEvent::new(KeyCode::Char('n'), KeyModifiers::CONTROL), &mut model, &Hitboxes::default()),
            Action::UseModel("local/qwen".into())
        );
    }

    #[test]
    fn an_empty_line_is_not_a_prompt_worth_paying_for() {
        let mut model = Model::new("/w".into());
        assert_eq!(typed(&mut model, "   "), Action::None);
    }

    fn press(model: &mut Model, code: KeyCode, hits: &Hitboxes) -> Action {
        key_pressed(&KeyEvent::new(code, KeyModifiers::NONE), model, hits)
    }

    /// Two sessions, EARLIER recorded ones, and a conversation in the first
    /// long enough to read back through.
    fn talking(earlier: usize) -> Model {
        let mut model = Model::new("/w".into());
        model.sessions = vec![
            crate::protocol::SessionInfo { id: "s1".into(), ..Default::default() },
            crate::protocol::SessionInfo { id: "s2".into(), ..Default::default() },
        ];
        model.recent = (0..earlier)
            .map(|index| crate::protocol::Recorded { id: format!("r{index}"), messages: 2, ..Default::default() })
            .collect();
        model.open_tab("s1");
        let said: crate::protocol::Event = serde_json::from_value(serde_json::json!({
            "event": "user.message", "session": "s1", "seq": 1,
            "data": {"text": "a question\n\n".repeat(60)}
        }))
        .unwrap();
        model.absorb(&said);
        model
    }

    fn column_on_screen() -> Hitboxes {
        Hitboxes { sessions: ratatui::layout::Rect::new(0, 1, 29, 10), ..Default::default() }
    }

    #[test]
    fn up_from_the_prompt_reads_back_and_the_arrows_then_scroll_the_talk_not_the_list() {
        let shown = column_on_screen();
        let mut model = talking(0);
        press(&mut model, KeyCode::Up, &shown);
        assert_eq!(model.focus, Focus::Transcript, "up from the prompt did not go to the conversation");
        assert!(model.current_conversation().unwrap().owes_scroll(), "up did not scroll the conversation");
        model.focus_sessions();
        model.focus = Focus::Transcript;
        press(&mut model, KeyCode::Up, &shown);
        press(&mut model, KeyCode::Up, &shown);
        assert_eq!(model.selected_row().unwrap().id(), "s1", "the arrows walked the list");
        // Left crosses to the column, on the open session, where the same
        // arrows walk the list; right comes back to the conversation.
        press(&mut model, KeyCode::Left, &shown);
        assert_eq!(model.focus, Focus::Sessions);
        press(&mut model, KeyCode::Down, &shown);
        assert_eq!(model.selected_row().unwrap().id(), "s2");
        press(&mut model, KeyCode::Right, &shown);
        assert_eq!(model.focus, Focus::Transcript);
    }

    #[test]
    fn down_past_the_newest_line_hands_the_keyboard_back_to_the_prompt() {
        let none = Hitboxes::default();
        let mut model = talking(0);
        model.focus = Focus::Transcript;
        press(&mut model, KeyCode::Up, &none);
        press(&mut model, KeyCode::Down, &none);
        assert_eq!(model.focus, Focus::Transcript, "down left while a scroll was still owed");
        press(&mut model, KeyCode::Down, &none);
        assert_eq!(model.focus, Focus::Input, "down at the newest line did not return to the prompt");
        model.focus = Focus::Transcript;
        press(&mut model, KeyCode::Char('h'), &none);
        assert_eq!((model.focus, model.input.as_str()), (Focus::Input, "h"), "typing did not reach the prompt");
        // With no sessions column on screen, left has nowhere to go.
        model.focus = Focus::Transcript;
        press(&mut model, KeyCode::Left, &none);
        assert_eq!(model.focus, Focus::Transcript);
    }

    #[test]
    fn page_keys_move_the_conversation_from_the_sessions_column_and_leave_its_selection() {
        let shown = column_on_screen();
        let mut model = talking(3);
        model.focus_sessions();
        press(&mut model, KeyCode::Down, &shown);
        let selected = model.selected_row().unwrap().id().to_string();
        press(&mut model, KeyCode::PageUp, &shown);
        assert!(model.current_conversation().unwrap().owes_scroll(), "page up did not move the conversation");
        assert_eq!((model.focus, model.selected_row().unwrap().id()), (Focus::Sessions, selected.as_str()));
    }

    #[test]
    fn the_wheel_over_the_sessions_column_moves_the_column_and_not_the_talk() {
        let shown = column_on_screen();
        let mut model = talking(40);
        let wheel_at = |column: u16, row: u16| {
            Event::Mouse(MouseEvent { kind: MouseEventKind::ScrollDown, column, row, modifiers: KeyModifiers::NONE })
        };
        read(&wheel_at(3, 5), &mut model, &shown);
        assert!(!model.current_conversation().unwrap().owes_scroll(), "the wheel over the column scrolled the talk");
        let total = crate::sidebar::rows(&model).len();
        assert_eq!(model.session_list.window(total, None, 10).first, 3, "the column did not move");
        read(&wheel_at(60, 5), &mut model, &shown);
        assert!(model.current_conversation().unwrap().owes_scroll(), "the wheel over the talk did not scroll it");
    }

    #[test]
    fn a_session_is_deleted_only_once_asked_and_esc_keeps_it() {
        let shown = column_on_screen();
        let mut model = talking(2);
        model.focus_sessions();
        press(&mut model, KeyCode::Down, &shown);
        press(&mut model, KeyCode::Down, &shown);
        let chosen = model.selected_row().unwrap().id().to_string();
        assert_eq!(chosen, "r0");
        assert_eq!(press(&mut model, KeyCode::Backspace, &shown), Action::None, "backspace deleted without asking");
        assert_eq!(model.focus, Focus::Deleting);
        assert_eq!(press(&mut model, KeyCode::Char('x'), &shown), Action::None);
        assert_eq!(model.focus, Focus::Deleting, "a stray key answered the question");
        press(&mut model, KeyCode::Esc, &shown);
        assert_eq!((model.focus, model.deleting.is_none()), (Focus::Sessions, true), "esc did not keep the session");
        press(&mut model, KeyCode::Delete, &shown);
        assert_eq!(press(&mut model, KeyCode::Enter, &shown), Action::Delete(chosen));
        assert_eq!(model.focus, Focus::Sessions);
    }

    #[test]
    fn ctrl_d_in_the_picker_asks_about_the_highlighted_session() {
        let none = Hitboxes::default();
        let mut model = Model::new("/w".into());
        model.focus = Focus::Picker;
        model.picker.results = vec![crate::protocol::Recorded {
            id: "r9".into(),
            messages: 3,
            opening: "found it".into(),
            ..Default::default()
        }];
        press(&mut model, KeyCode::Backspace, &none);
        assert_eq!(model.focus, Focus::Picker, "backspace in the search asked to delete");
        key_pressed(&KeyEvent::new(KeyCode::Char('d'), KeyModifiers::CONTROL), &mut model, &none);
        assert_eq!(model.deleting.as_ref().map(|asked| asked.subject.as_str()), Some("found it"));
        assert_eq!(press(&mut model, KeyCode::Char('y'), &none), Action::Delete("r9".into()));
        assert_eq!(model.focus, Focus::Picker, "the picker was not given back after the answer");
    }
}


#[cfg(test)]
mod paste_tests {
    use super::*;
    use crate::model::Model;

    fn typing() -> Model {
        let mut model = Model::new("/w".into());
        model.focus = Focus::Input;
        model
    }

    #[test]
    fn a_paste_keeps_its_newlines_and_does_not_send() {
        let mut model = typing();
        // Enter is what a terminal WITHOUT bracketed paste would have sent for
        // each of these breaks, and each one submitted.
        assert!(matches!(pasted("def f():\n    return 1\n", &mut model), Action::None));
        assert_eq!(model.input, "def f():\n    return 1\n");
    }

    #[test]
    fn either_line_ending_becomes_one() {
        let mut model = typing();
        pasted("a\r\nb\rc", &mut model);
        assert_eq!(model.input, "a\nb\nc", "a stray carriage return is invisible until something splits on it");
    }

    #[test]
    fn a_paste_appends_to_what_was_typed() {
        let mut model = typing();
        model.input.push_str("fix ");
        pasted("this", &mut model);
        assert_eq!(model.input, "fix this");
    }

    #[test]
    fn a_paste_outside_the_input_is_ignored() {
        // Into a picker it is a search term the filter never sees -- better
        // dropped than appended to a prompt nobody is writing.
        let mut model = Model::new("/w".into());
        model.focus = Focus::Picker;
        pasted("stray", &mut model);
        assert_eq!(model.input, "");
    }

    #[test]
    fn an_empty_paste_changes_nothing() {
        let mut model = typing();
        model.input.push_str("kept");
        pasted("", &mut model);
        assert_eq!(model.input, "kept");
    }
}
