//! vivarium-tui: a full-screen client for the vivarium daemon.
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
mod status;
mod ui;

use crossterm::event::{self, DisableMouseCapture, EnableMouseCapture};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use model::Model;
use protocol::{Connection, Incoming, Recorded, SessionInfo};
use ratatui::prelude::*;
use serde_json::{json, Value};
use std::io::stdout;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Restores the terminal however the program leaves -- return, error or panic.
///
/// A full-screen program that exits without giving back raw mode, the mouse
/// modes and the alternate screen leaves a shell with no echo, no scrollback
/// and an invisible cursor, and the fix a person reaches for is closing the
/// window.
struct TerminalGuard;

impl TerminalGuard {
    fn enter() -> std::io::Result<Self> {
        enable_raw_mode()?;
        execute!(stdout(), EnterAlternateScreen, EnableMouseCapture)?;
        Ok(TerminalGuard)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(stdout(), DisableMouseCapture, LeaveAlternateScreen);
    }
}

fn main() {
    if let Err(problem) = run() {
        eprintln!("vivarium-tui: {problem}");
        std::process::exit(1);
    }
}

fn run() -> std::io::Result<()> {
    // Said plainly, before anything else happens. Without this the failure is
    // `Device not configured (os error 6)` from deep inside raw mode, which
    // tells a person nothing about what they did.
    if !std::io::IsTerminal::is_terminal(&stdout()) {
        return Err(std::io::Error::other(
            "vivarium-tui needs a terminal. Use `vivarium attach` when piping or scripting.",
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

    let mut model = Model::new(cwd.clone());
    // No standing hint. The welcome teaches the keys and `/` lists the
    // commands, so the status carries only what happened -- and a note that
    // is always there would outrank the ones that are not.

    // THE GREETING ALREADY CARRIES THE SESSIONS. Asking for them again was
    // the first draft: a second round trip to learn what the daemon had
    // already said, and a first frame that was empty until it answered.
    // Wait for the GREETING, not for a non-empty session list. Waiting for
    // sessions meant a daemon with none -- a fresh one, which is exactly when
    // somebody is looking hardest at how long this takes -- stalled for the
    // whole deadline before drawing anything.
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut greeted = false;
    while !greeted && Instant::now() < deadline {
        for message in connection.drain() {
            match message {
                Incoming::Greeting(greeting) => {
                    take_sessions(&mut model, &greeting);
                    greeted = true;
                }
                Incoming::Event(event) => model.absorb(&event),
                Incoming::Response(reply) => take_response(&mut model, &reply),
                Incoming::Closed => {
                    model.connected = false;
                    greeted = true;
                }
            }
        }
        if !greeted {
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    // Open the session for this directory, or the newest one anywhere, so the
    // client starts pointed at something rather than at nothing.
    let opening = model
        .sessions
        .iter()
        .find(|session| session.cwd.trim_end_matches('/') == cwd.trim_end_matches('/'))
        .or_else(|| model.sessions.last())
        .map(|session| session.id.clone());
    if let Some(id) = opening {
        open_session(&mut connection, &mut model, &id)?;
        // Before the first frame, so the counts are there from the start
        // rather than appearing a moment later.
        let _ = refresh_learned(&mut connection, &mut model);
    }
    let _ = refresh_recent(&mut connection, &mut model);

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
            terminal.draw(|frame| hits = ui::draw(frame, &model, &mut rendered))?;
            dirty = false;
        }

        // Everything the daemon has said, before the next frame: one repaint
        // for a burst of twenty events rather than twenty repaints.
        for message in connection.drain() {
            dirty = true;
            match message {
                Incoming::Event(event) => model.absorb(&event),
                Incoming::Response(reply) => take_response(&mut model, &reply),
                Incoming::Greeting(_) => {}
                Incoming::Closed => {
                    model.connected = false;
                    reconnect.lost();
                    model.status = "connection lost — reconnecting".into();
                }
            }
        }

        // A LOST CONNECTION IS RETRIED, NOT REPORTED. The daemon is the durable
        // side, and a client that gave up on it the moment a restart closed
        // the socket made `survives a restart` mean `if you restart the client
        // too`. Tried on a backoff, so a daemon that is down for a minute is
        // asked a dozen times rather than a thousand.
        if !model.connected && reconnect.due() {
            match reconnect.attempt(&path) {
                Some(fresh) => {
                    connection = fresh;
                    rejoin(&mut connection, &mut model);
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
            match perform(&mut connection, &mut model, action) {
                Ok(true) => return Ok(()),
                Ok(false) => {}
                Err(problem) => model.status = format!("{problem}"),
            }
            waiting = event::poll(Duration::from_millis(0))?;
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
            connection.send(json!({
                "type": "prompt", "session": model.current, "text": text
            }))?;
        }
        Action::Open(id) => open_session(connection, model, &id)?,
        Action::NewTab => {
            let started =
                connection.send(json!({"type": "session.start", "cwd": model.cwd.clone()}))?;
            let (reply, events) = connection.wait_for(started, Duration::from_secs(30));
            for event in events {
                model.absorb(&event);
            }
            if let Some(id) = reply
                .as_ref()
                .and_then(|reply| reply.get("session"))
                .and_then(|session| session.get("id"))
                .and_then(Value::as_str)
            {
                let id = id.to_string();
                model.open_tab(&id);
                refresh_sessions(connection, model)?;
                attach(connection, model, &id)?;
            }
        }
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
        Action::Refresh => refresh_sessions(connection, model)?,
        Action::Learned => {
            refresh_learned(connection, model)?;
            model.showing_learned = true;
        }
        Action::Command(line) => return run_command(connection, model, &line),
        Action::ToggleSidebar => {
            model.sidebar = !model.sidebar;
            model.focus = if model.sidebar { model::Focus::Sessions } else { model::Focus::Input };
        }
        Action::Search(text) => {
            let asked = if text.trim().is_empty() {
                connection.send(json!({"type": "session.recorded", "limit": 50}))?
            } else {
                connection.send(json!({"type": "session.search", "text": text, "limit": 50}))?
            };
            let (reply, events) = connection.wait_for(asked, Duration::from_secs(15));
            for event in events {
                model.absorb(&event);
            }
            model.picker.searching = false;
            if let Some(found) = reply.as_ref().and_then(|r| r.get("recorded")).and_then(Value::as_array) {
                model.picker.results = found
                    .iter()
                    .filter_map(|value| serde_json::from_value::<Recorded>(value.clone()).ok())
                    .collect();
                model.picker.selection = 0;
            }
        }
        Action::Resume { id, cwd } => {
            // Continue it in a NEW cell. A recorded session is a file, not a
            // running thing, so resuming is starting -- and the daemon
            // publishes what it loaded, which is what makes it visible here.
            // ITS OWN directory, not ours. The daemon scopes find-session to
            // the cwd it is given, so resuming a session recorded elsewhere
            // into the client's directory finds nothing -- and a resume that
            // finds nothing succeeds, producing an empty session that looks
            // exactly like history that failed to load.
            let where_it_lived = if cwd.is_empty() { model.cwd.clone() } else { cwd };
            let started = connection.send(json!({
                "type": "session.start", "cwd": where_it_lived, "resume": id
            }))?;
            let (reply, events) = connection.wait_for(started, Duration::from_secs(60));
            for event in events {
                model.absorb(&event);
            }
            if let Some(new_id) = reply
                .as_ref()
                .and_then(|reply| reply.get("session"))
                .and_then(|session| session.get("id"))
                .and_then(Value::as_str)
            {
                let new_id = new_id.to_string();
                refresh_sessions(connection, model)?;
                open_session(connection, model, &new_id)?;
            }
        }
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
        "/learned" => return perform(connection, model, input::Action::Learned).map(|_| false),
        "/new" => return perform(connection, model, input::Action::NewTab).map(|_| false),
        "/sessions" => return perform(connection, model, input::Action::ToggleSidebar).map(|_| false),
        "/find" => {
            model.focus = model::Focus::Picker;
            model.picker.query = rest.clone();
            model.picker.selection = 0;
            model.picker.searching = true;
            return perform(connection, model, input::Action::Search(rest)).map(|_| false);
        }
        "/close" => return perform(connection, model, input::Action::CloseTab).map(|_| false),
        "/refresh" => return perform(connection, model, input::Action::Refresh).map(|_| false),
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
}

impl Reconnect {
    fn lost(&mut self) {
        if self.next.is_none() {
            self.wait = Duration::from_millis(500);
            self.attempts = 0;
            self.next = Some(Instant::now() + self.wait);
        }
    }

    fn due(&self) -> bool {
        self.next.map(|at| Instant::now() >= at).unwrap_or(false)
    }

    /// One try. Starts a daemon if none is listening, the same way the first
    /// connection does -- a person who closed the lid on a daemon that was
    /// then killed should open it to a working client, not to instructions.
    fn attempt(&mut self, path: &PathBuf) -> Option<Connection> {
        self.attempts += 1;
        let fresh = protocol::ensure_daemon(path)
            .ok()
            .and_then(|()| Connection::open(path).ok());
        match fresh {
            Some(connection) => {
                self.next = None;
                Some(connection)
            }
            None => {
                self.wait = (self.wait * 2).min(Duration::from_secs(5));
                self.next = Some(Instant::now() + self.wait);
                None
            }
        }
    }
}

/// Pick up where the old connection left off, on a daemon that may be new.
///
/// EVERYTHING IS RE-READ. A daemon that restarted brought the sessions back
/// under the same ids, but its streams begin again at sequence one: folding
/// the replay onto what this client already holds would show every turn
/// twice, and trusting `last_seq` would skip most of it. The tabs stay --
/// they name sessions, and the sessions are the thing that survived.
fn rejoin(connection: &mut Connection, model: &mut Model) {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut greeted = false;
    while !greeted && Instant::now() < deadline {
        for message in connection.drain() {
            if let Incoming::Greeting(greeting) = message {
                take_sessions(model, &greeting);
                greeted = true;
            }
        }
        if !greeted {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    if !greeted {
        return;
    }
    model.connected = true;
    model.conversations.clear();
    let open: Vec<String> = model.tabs.clone();
    for id in open {
        model.conversation(&id);
        let _ = attach(connection, model, &id);
    }
    let _ = refresh_learned(connection, model);
    let _ = refresh_recent(connection, model);
    model.status = "reconnected".into();
}

/// What was recorded in this directory, for the welcome. A handful, newest
/// first: the welcome is a door, not the picker.
fn refresh_recent(connection: &mut Connection, model: &mut Model) -> std::io::Result<()> {
    let asked = connection.send(json!({
        "type": "session.recorded", "cwd": model.cwd, "limit": 6
    }))?;
    let (reply, events) = connection.wait_for(asked, Duration::from_secs(5));
    for event in events {
        model.absorb(&event);
    }
    if let Some(found) = reply.as_ref().and_then(|r| r.get("recorded")).and_then(Value::as_array) {
        model.recent = found
            .iter()
            .filter_map(|value| serde_json::from_value::<Recorded>(value.clone()).ok())
            .collect();
    }
    Ok(())
}

fn open_session(
    connection: &mut Connection,
    model: &mut Model,
    id: &str,
) -> std::io::Result<()> {
    model.open_tab(id);
    attach(connection, model, id)
}

/// Subscribe, from the beginning.
///
/// SINCE 0 because this client shows a STATE, and an empty state is a claim.
/// Opening a session onto a blank pane is indistinguishable from opening the
/// wrong one. The replay arrives before the response, which is why the events
/// collected while waiting are folded rather than dropped.
fn attach(connection: &mut Connection, model: &mut Model, id: &str) -> std::io::Result<()> {
    let already = model
        .conversations
        .get(id)
        .map(|conversation| !conversation.entries.is_empty())
        .unwrap_or(false);
    if already {
        return Ok(());
    }
    let asked = connection.send(json!({
        "type": "session.attach", "session": id, "since": 0
    }))?;
    let (_, events) = connection.wait_for(asked, Duration::from_secs(20));
    for event in events {
        model.absorb(&event);
    }
    Ok(())
}

/// What this session has retained, in one request.
///
/// ONE request, not four: session.inspect answers notes, skills, tools and
/// trust from a single instant. Four questions about one moment answered by
/// four round trips would be four different moments.
fn refresh_learned(connection: &mut Connection, model: &mut Model) -> std::io::Result<()> {
    if model.current.is_empty() {
        return Ok(());
    }
    let asked = connection.send(json!({
        "type": "session.inspect", "session": model.current
    }))?;
    let (reply, events) = connection.wait_for(asked, Duration::from_secs(15));
    for event in events {
        model.absorb(&event);
    }
    if let Some(reply) = reply {
        model.learned = protocol::Learned::from_reply(&reply);
    }
    Ok(())
}

fn refresh_sessions(connection: &mut Connection, model: &mut Model) -> std::io::Result<()> {
    let asked = connection.send(json!({"type": "session.list"}))?;
    let (reply, events) = connection.wait_for(asked, Duration::from_secs(10));
    for event in events {
        model.absorb(&event);
    }
    if let Some(reply) = reply {
        take_sessions(model, &reply);
    }
    Ok(())
}

fn take_response(model: &mut Model, reply: &Value) {
    if reply.get("sessions").is_some() {
        take_sessions(model, reply);
    } else if reply.get("success").and_then(Value::as_bool) == Some(false) {
        if let Some(error) = reply.get("error").and_then(Value::as_str) {
            model.status = error.to_string();
        }
    }
}

fn take_sessions(model: &mut Model, reply: &Value) {
    let Some(array) = reply.get("sessions").and_then(Value::as_array) else {
        return;
    };
    model.sessions = array
        .iter()
        .filter_map(|value| serde_json::from_value::<SessionInfo>(value.clone()).ok())
        .collect();
    model.prune_tabs();
    if model.selection >= model.sessions.len() {
        model.selection = model.sessions.len().saturating_sub(1);
    }
}
