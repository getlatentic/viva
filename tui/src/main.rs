//! viva-tui: a full-screen client for the viva daemon.
//!
//! A separate binary that speaks the socket protocol the daemon already had.
//! It adds nothing to that protocol -- if this program needed the engine to
//! change, the boundary would be in the wrong place. The Lisp client stays
//! exactly as it is: it pipes, scripts and diffs, and that is why it exists.

mod bench;
mod commands;
mod input;
mod markdown;
mod model;
mod protocol;
mod requests;
mod status;
mod ui;

use crossterm::event::{
    self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste,
    EnableMouseCapture,
};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use model::Model;
use protocol::{Connection, Incoming};
use ratatui::prelude::*;
use requests::Requests;
use serde_json::json;
use std::io::stdout;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Restores the terminal however the program leaves -- return, error or panic.
///
/// A full-screen program that exits without giving back raw mode, the mouse
/// modes and the alternate screen leaves a shell with no echo, no scrollback
/// and an invisible cursor, and the fix a person reaches for is closing the
/// window.
struct TerminalGuard {
    mouse: bool,
}

/// Does this run want the mouse?
///
/// OFF BY DEFAULT, because asking for the mouse takes selection away. While the
/// terminal is reporting, a drag belongs to this program and the terminal will
/// not highlight anything -- so copying a line out of a model's answer stopped
/// working, and every mouse action it bought is one a key already does: the
/// wheel is PageUp and PageDown, and a click on a row is an arrow or a digit.
/// VIVA_MOUSE asks for it back, for whoever would rather have the wheel and
/// knows to hold a modifier to select.
fn mouse_wanted() -> bool {
    match std::env::var("VIVA_MOUSE") {
        Ok(value) => {
            let value = value.trim().to_ascii_lowercase();
            !matches!(value.as_str(), "" | "0" | "off" | "no" | "false")
        }
        Err(_) => false,
    }
}

impl TerminalGuard {
    fn enter() -> std::io::Result<Self> {
        let mouse = mouse_wanted();
        enable_raw_mode()?;
        // BRACKETED PASTE ALWAYS. Without it a pasted newline arrives as Enter
        // and submits, so pasting a five-line function asked the model five
        // questions and paid for five answers.
        execute!(stdout(), EnterAlternateScreen, EnableBracketedPaste)?;
        if mouse {
            execute!(stdout(), EnableMouseCapture)?;
        }
        Ok(TerminalGuard { mouse })
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        // Only what was turned on: telling a terminal to stop reporting a mouse
        // it was never reporting is a sequence some of them print.
        if self.mouse {
            let _ = execute!(stdout(), DisableMouseCapture);
        }
        let _ = execute!(stdout(), DisableBracketedPaste, LeaveAlternateScreen);
    }
}

fn main() {
    if let Err(problem) = run() {
        eprintln!("viva-tui: {problem}");
        std::process::exit(1);
    }
}

fn run() -> std::io::Result<()> {
    // Said plainly, before anything else happens. Without this the failure is
    // `Device not configured (os error 6)` from deep inside raw mode, which
    // tells a person nothing about what they did.
    if !std::io::IsTerminal::is_terminal(&stdout()) {
        return Err(std::io::Error::other(
            "viva-tui needs a terminal. Use `viva attach` when piping or scripting.",
        ));
    }
    let cwd = std::env::current_dir()?.to_string_lossy().into_owned();
    let path = protocol::socket_path();
    // ONE COMMAND. Telling a person to start a daemon first is telling them
    // about our architecture; `daemon start` is idempotent, so the client can
    // simply make sure of it.
    protocol::ensure_daemon(&path)
        .map_err(|problem| std::io::Error::other(problem))?;
    let mut connection = Connection::open(&path)?;

    let mut model = Model::new(cwd);
    // No standing hint. The welcome teaches the keys and `/` lists the
    // commands, so the status carries only what happened -- and a note that
    // is always there would outrank the ones that are not.

    // Nothing waits for the daemon. The greeting opens this directory's
    // session, and each answer is handled by the loop when it lands.
    let mut asked = Requests::default();

    // Set up the terminal LAST, so any failure above prints as ordinary text
    // instead of into an alternate screen nobody will ever see.
    let _guard = TerminalGuard::enter()?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout()))?;
    terminal.clear()?;

    let mut hits = ui::Hitboxes::default();
    let mut rendered = ui::Rendered::default();
    let mut reconnect = Reconnect::default();
    // DRAW ONLY WHEN SOMETHING CHANGED. Redrawing on a timer means an idle
    // client spends the same effort as a busy one, and the effort is not small
    // -- laying out a long transcript costs the length of the conversation.
    let mut dirty = true;
    loop {
        if dirty {
            terminal.draw(|frame| hits = ui::draw(frame, &mut model, &mut rendered))?;
            dirty = false;
        }

        // Everything the daemon has said, before the next frame: one repaint
        // for a burst of twenty events rather than twenty repaints.
        for message in connection.drain() {
            dirty = true;
            let handled = match message {
                Incoming::Event(event) => {
                    model.absorb(&event);
                    Ok(())
                }
                Incoming::Response(reply) => asked
                    .answered(&mut connection, &mut model, &reply)
                    .map(|mine| {
                        if !mine {
                            requests::take_response(&mut model, &reply);
                        }
                    }),
                Incoming::Greeting(greeting) => asked.greeted(&mut connection, &mut model, &greeting),
                Incoming::Closed => {
                    asked.forget(&mut model);
                    model.connected = false;
                    reconnect.lost();
                    model.status = "connection lost — reconnecting".into();
                    Ok(())
                }
            };
            if let Err(problem) = handled {
                model.status = format!("{problem}");
            }
        }

        // A LOST CONNECTION IS RETRIED, NOT REPORTED. The daemon is the durable
        // side, and a client that gave up on it the moment a restart closed
        // the socket made `survives a restart` mean `if you restart the client
        // too`. Tried on a backoff, so a daemon that is down for a minute is
        // asked a dozen times rather than a thousand.
        if !model.connected && reconnect.due() {
            match reconnect.attempt(&path) {
                // Its greeting attaches the open tabs again.
                Some(fresh) => {
                    connection = fresh;
                    dirty = true;
                }
                None => {
                    model.status = format!("connection lost — reconnecting ({})",
                                           reconnect.attempts);
                    dirty = true;
                }
            }
        }

        // EVERY key that is already waiting, before drawing again. Holding a
        // key or spinning a wheel delivers events faster than a frame, and
        // repainting between each one makes the client slower the harder it is
        // being used -- which is the wrong way round.
        // A scroll still owed is a reason to come straight back: the frames
        // that pay it out are what make the movement visible.
        let owed = model
            .conversations
            .get(&model.current)
            .map(|conversation| conversation.owes_scroll())
            .unwrap_or(false);
        // Paced, not raced: a frame every few milliseconds is what makes the
        // movement visible, and the same wait still answers a key at once.
        let patience = if owed { 6 } else { 30 };
        let mut waiting = event::poll(Duration::from_millis(patience))?;
        while waiting {
            dirty = true;
            let action = input::read(&event::read()?, &mut model, &hits);
            match perform(&mut connection, &mut model, &mut asked, action) {
                Ok(true) => return Ok(()),
                Ok(false) => {}
                Err(problem) => model.status = format!("{problem}"),
            }
            waiting = event::poll(Duration::from_millis(0))?;
        }

        if asked.expire(&mut model, Instant::now()) {
            dirty = true;
        }
        if let Some(conversation) = model.conversations.get_mut(&model.current) {
            if conversation.settle() {
                dirty = true;
            }
        }
    }
}

/// Do what a keypress or click asked for. Returns true to leave.
fn perform(
    connection: &mut Connection,
    model: &mut Model,
    asked: &mut Requests,
    action: input::Action,
) -> std::io::Result<bool> {
    use input::Action;
    match action {
        Action::None => {}
        Action::Quit => return Ok(true),
        Action::Cancel => {
            connection.send(json!({"type": "cancel", "session": model.current}))?;
        }
        Action::Send(text) => {
            // No local echo: the daemon publishes user.message and it comes
            // back through the same path as everything else. Echoing here as
            // well shows the prompt twice; echoing here INSTEAD shows it once
            // and loses it on the next attach.
            if model.current.is_empty() {
                // Enter has already emptied the line, and there is no session
                // to send it to yet, so it goes back rather than away.
                model.input = text;
                model.status = "no session is open yet".into();
            } else {
                connection.send(json!({
                    "type": "prompt", "session": model.current, "text": text
                }))?;
            }
        }
        Action::Open(id) => asked.open(connection, model, &id)?,
        Action::NewTab => asked.start(connection, model, None)?,
        Action::Models => {
            model.models.query.clear();
            model.models.refreshing = true;
            asked.ask_models(connection, false)?;
            model.focus = model::Focus::Models;
        }
        Action::RefreshModels => asked.ask_models(connection, true)?,
        Action::UseModel(label) => asked.start(connection, model, Some(&label))?,
        Action::CloseTab => {
            let index = model.tab;
            model.close_tab(index);
            if let Some(id) = model.tabs.get(model.tab).cloned() {
                model.current = id;
            }
        }
        Action::SelectTab(index) => {
            if let Some(id) = model.tabs.get(index).cloned() {
                model.tab = index;
                model.current = id;
            }
        }
        Action::Refresh => asked.ask_sessions(connection)?,
        Action::Learned => {
            asked.ask_learned(connection, model)?;
            model.showing_learned = true;
        }
        Action::Command(line) => return run_command(connection, model, asked, &line),
        Action::Shell(line) => {
            if line.is_empty() {
                model.status = "! needs a command".into();
            } else if model.current.is_empty() {
                model.input = format!("!{line}");
                model.status = "no session to run it in".into();
            } else {
                connection.send(json!({
                    "type": "shell", "session": model.current, "command": line
                }))?;
            }
        }
        Action::ToggleSidebar => {
            model.sidebar = !model.sidebar;
            model.focus = if model.sidebar { model::Focus::Sessions } else { model::Focus::Input };
        }
        Action::Search(text) => asked.search(connection, &text)?,
        Action::Resume { id, cwd } => asked.resume(connection, model, &id, &cwd)?,
    }
    Ok(false)
}

/// A line beginning with `/`. Returns true to leave.
///
/// A CLOSED SET, and an unknown one is refused rather than forwarded. The
/// alternative is what the transcript showed: `/quit` sent to the model, and
/// the model politely saying goodbye while the client stayed exactly where it
/// was. That is a paid request answered by a guess at what somebody meant.
fn run_command(
    connection: &mut Connection,
    model: &mut Model,
    asked: &mut Requests,
    line: &str,
) -> std::io::Result<bool> {
    let mut parts = line.trim().splitn(2, char::is_whitespace);
    let verb = parts.next().unwrap_or("").to_ascii_lowercase();
    let rest = parts.next().unwrap_or("").trim().to_string();
    // Resolved through the ONE table, so the menu cannot offer a command the
    // dispatcher refuses -- which would be the feature attacking itself.
    let Some(command) = commands::lookup(&verb) else {
        model.note(format!(
            "{verb} is not a command here. /help lists them. Nothing was sent to the model."
        ));
        return Ok(false);
    };
    match command.name {
        // Leaving the client is not ending the session. That distinction is
        // the whole point of a daemon, so every word for it does the same.
        "/quit" => return Ok(true),
        "/help" => model.note(commands::help()),
        "/learned" => return perform(connection, model, asked, input::Action::Learned).map(|_| false),
        "/new" => return perform(connection, model, asked, input::Action::NewTab).map(|_| false),
        "/sessions" => return perform(connection, model, asked, input::Action::ToggleSidebar).map(|_| false),
        "/shell" => return perform(connection, model, asked, input::Action::Shell(rest)).map(|_| false),
        "/find" => {
            model.focus = model::Focus::Picker;
            model.picker.query = rest.clone();
            model.picker.selection = 0;
            model.picker.searching = true;
            return perform(connection, model, asked, input::Action::Search(rest)).map(|_| false);
        }
        // Ctrl-C is the fast way and only fires when this client believes the
        // session is busy. That belief is a cached event, and a loop that
        // starts its next turn between two frames is exactly the case where it
        // is wrong -- so the brake a person reaches for deliberately does not
        // consult it.
        "/stop" => return perform(connection, model, asked, input::Action::Cancel).map(|_| false),
        "/close" => return perform(connection, model, asked, input::Action::CloseTab).map(|_| false),
        "/refresh" => return perform(connection, model, asked, input::Action::Refresh).map(|_| false),
        "/models" => {
            // The typed remainder seeds the search, so `/models oss` narrows on
            // the way in rather than making somebody type it twice.
            let outcome = perform(connection, model, asked, input::Action::Models);
            model.models.query = rest.clone();
            model.models.selection = 0;
            return outcome.map(|_| false);
        }
        _ => {}
    }
    Ok(false)
}

/// Getting back to a daemon that went away.
#[derive(Default)]
struct Reconnect {
    next: Option<Instant>,
    wait: Duration,
    attempts: u32,
    /// Daemon starts spent since the connection was last good.
    starts: u32,
}

impl Reconnect {
    /// How many times to pay for a daemon start before only listening. Three
    /// covers a daemon that is slow to come up; past that it is not coming up,
    /// and paying an SBCL image every few seconds to learn so is the cost that
    /// gets noticed a day later.
    const STARTS_ALLOWED: u32 = 3;

    fn lost(&mut self) {
        if self.next.is_none() {
            self.wait = Duration::from_millis(500);
            self.attempts = 0;
            self.starts = 0;
            self.next = Some(Instant::now() + self.wait);
        }
    }

    fn due(&self) -> bool {
        self.next.map(|at| Instant::now() >= at).unwrap_or(false)
    }

    /// One try. Starts a daemon if none is listening, the same way the first
    /// connection does -- a person who closed the lid on a daemon that was
    /// then killed should open it to a working client, not to instructions.
    ///
    /// CONNECTING IS CHEAP AND STARTING IS NOT. A daemon start loads an SBCL
    /// image: 1.3 seconds of CPU, measured. Running one on every retry against
    /// a backoff that tops out at five seconds is a quarter of a core, forever,
    /// on a client nobody is touching -- which is what two of them were found
    /// doing, a day after the daemon they wanted had gone. So the socket is
    /// tried first every time, and a start is attempted only while there is
    /// budget for one.
    fn attempt(&mut self, path: &PathBuf) -> Option<Connection> {
        self.attempts += 1;
        let fresh = Connection::open(path).ok().or_else(|| {
            if self.starts < Self::STARTS_ALLOWED {
                self.starts += 1;
                protocol::ensure_daemon(path)
                    .ok()
                    .and_then(|()| Connection::open(path).ok())
            } else {
                None
            }
        });
        match fresh {
            Some(connection) => {
                self.next = None;
                self.starts = 0;
                Some(connection)
            }
            None => {
                // Far enough apart that a client waiting on a daemon that is
                // never coming back costs nothing worth measuring, and near
                // enough that one that does come back is found within a minute.
                self.wait = (self.wait * 2).min(Duration::from_secs(30));
                self.next = Some(Instant::now() + self.wait);
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::unix::net::UnixStream;

    #[test]
    fn a_prompt_with_no_session_open_goes_back_to_the_line() {
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        theirs.set_read_timeout(Some(Duration::from_millis(50))).expect("a read timeout");
        let mut connection = Connection::over(ours).expect("a connection");
        let mut model = Model::new("/w".into());
        let mut asked = Requests::default();
        let typed = input::Action::Send("what is in this folder".into());
        perform(&mut connection, &mut model, &mut asked, typed).unwrap();
        assert_eq!(model.input, "what is in this folder");
        assert_eq!(model.status, "no session is open yet");
        let mut line = String::new();
        let sent = BufReader::new(theirs).read_line(&mut line);
        assert!(!matches!(sent, Ok(read) if read > 0), "the prompt went to no session: {line}");
    }
}
