//! vivarium-tui: a full-screen client for the vivarium daemon.
//!
//! A separate binary that speaks the socket protocol the daemon already had.
//! It adds nothing to that protocol -- if this program needed the engine to
//! change, the boundary would be in the wrong place. The Lisp client stays
//! exactly as it is: it pipes, scripts and diffs, and that is why it exists.

mod input;
mod model;
mod protocol;
mod ui;

use crossterm::event::{self, DisableMouseCapture, EnableMouseCapture};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use model::Model;
use protocol::{Connection, Incoming, SessionInfo};
use ratatui::prelude::*;
use serde_json::{json, Value};
use std::io::stdout;
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
    let cwd = std::env::current_dir()?.to_string_lossy().into_owned();
    let path = protocol::socket_path();
    let mut connection = Connection::open(&path).map_err(|problem| {
        std::io::Error::new(
            problem.kind(),
            format!("no daemon on {} ({problem}). Start one with `vivarium daemon start`.",
                    path.display()),
        )
    })?;

    let mut model = Model::new(cwd.clone());
    model.status = "ready — tab/click switches, arrows walk the list, ctrl-c stops a turn".into();

    // THE GREETING ALREADY CARRIES THE SESSIONS. Asking for them again was
    // the first draft: a second round trip to learn what the daemon had
    // already said, and a first frame that was empty until it answered.
    let deadline = Instant::now() + Duration::from_secs(10);
    while model.sessions.is_empty() && Instant::now() < deadline {
        for message in connection.drain() {
            match message {
                Incoming::Greeting(greeting) => take_sessions(&mut model, &greeting),
                Incoming::Event(event) => model.absorb(&event),
                Incoming::Response(reply) => take_response(&mut model, &reply),
                Incoming::Closed => {
                    model.connected = false;
                    break;
                }
            }
        }
        if model.sessions.is_empty() {
            std::thread::sleep(Duration::from_millis(20));
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
    }

    // Set up the terminal LAST, so any failure above prints as ordinary text
    // instead of into an alternate screen nobody will ever see.
    let _guard = TerminalGuard::enter()?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout()))?;
    terminal.clear()?;

    let mut hits = ui::Hitboxes::default();
    loop {
        terminal.draw(|frame| hits = ui::draw(frame, &model))?;

        // Everything the daemon has said, before the next frame: one repaint
        // for a burst of twenty events rather than twenty repaints.
        for message in connection.drain() {
            match message {
                Incoming::Event(event) => model.absorb(&event),
                Incoming::Response(reply) => take_response(&mut model, &reply),
                Incoming::Greeting(_) => {}
                Incoming::Closed => {
                    model.connected = false;
                    model.status = "the daemon closed the connection".into();
                }
            }
        }

        if event::poll(Duration::from_millis(50))? {
            let action = input::read(&event::read()?, &mut model, &hits);
            match perform(&mut connection, &mut model, action) {
                Ok(true) => break,
                Ok(false) => {}
                Err(problem) => model.status = format!("{problem}"),
            }
        }
    }
    Ok(())
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
    }
    Ok(false)
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
