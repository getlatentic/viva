//! Talking to the daemon.
//!
//! One connection, line-delimited JSON, exactly the protocol the Lisp client
//! speaks. Nothing here is new: if this file needs the daemon to change, the
//! boundary has been drawn in the wrong place.
//!
//! Requests and events share the socket, so a reader thread would steal
//! replies from a caller waiting on one. Instead the connection is drained by
//! a single reader that hands EVERYTHING to the caller as `Incoming`, and a
//! request is a write followed by watching that stream for its response.

use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;

/// Where the daemon listens. `VIVARIUM_SOCKET` wins, as it does for the Lisp
/// client, so a test daemon on its own socket is reachable the same way.
pub fn socket_path() -> PathBuf {
    if let Ok(from_environment) = std::env::var("VIVARIUM_SOCKET") {
        return PathBuf::from(from_environment);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    PathBuf::from(home).join(".vivarium/vivariumd.sock")
}

/// One line from the daemon. The distinction matters to the caller: a response
/// answers something it asked, an event happened to a session it watches.
#[derive(Debug, Clone)]
pub enum Incoming {
    Greeting(Value),
    Response(Value),
    Event(Event),
    /// The connection ended. Reported rather than silent: a client that draws
    /// a stale frame forever is worse than one that says the daemon has gone.
    Closed,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Event {
    #[serde(rename = "event")]
    pub name: String,
    #[serde(default)]
    pub session: String,
    /// Monotonic per session. Kept because a gap in it is the one thing that
    /// says the replay/live seam dropped something, and a client that cannot
    /// notice that cannot report it.
    #[serde(default)]
    pub seq: u64,
    #[serde(default)]
    pub data: Value,
}

impl Event {
    /// A string field of the event's payload, or "".
    pub fn text(&self, key: &str) -> &str {
        self.data.get(key).and_then(Value::as_str).unwrap_or("")
    }
}

/// The launcher that can start a daemon, if one can be found.
///
/// Looked for in the order a person would expect: what they told us, what is
/// on their PATH, then the repository this binary was built inside. The last
/// matters because a freshly built client is usually being run from a checkout
/// where `vivarium` has not been installed yet.
pub fn launcher() -> Option<PathBuf> {
    if let Ok(named) = std::env::var("VIVARIUM_BIN") {
        let path = PathBuf::from(named);
        if path.exists() {
            return Some(path);
        }
    }
    if let Ok(path) = std::env::var("PATH") {
        for directory in path.split(':') {
            let candidate = PathBuf::from(directory).join("vivarium");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }
    // tui/target/{debug,release}/vivarium-tui -> ../../../bin/vivarium
    let exe = std::env::current_exe().ok()?;
    let root = exe.parent()?.parent()?.parent()?.parent()?;
    let candidate = root.join("bin/vivarium");
    candidate.exists().then_some(candidate)
}

/// Start a daemon and wait for its socket, if there is not one already.
///
/// `daemon start` is idempotent -- it answers `already running` and exits
/// zero -- so this does not need to ask first, and asking would be a race
/// anyway: between the answer and the start, either could change.
pub fn ensure_daemon(path: &PathBuf) -> Result<(), String> {
    if UnixStream::connect(path).is_ok() {
        return Ok(());
    }
    let launcher = launcher().ok_or_else(|| {
        format!("no daemon on {}, and no `vivarium` to start one with. \
Put it on your PATH or set VIVARIUM_BIN.", path.display())
    })?;
    let started = std::process::Command::new(&launcher)
        .args(["daemon", "start", "--background"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .output()
        .map_err(|problem| format!("could not run {}: {problem}", launcher.display()))?;
    if !started.status.success() {
        return Err(format!(
            "{} daemon start failed: {}",
            launcher.display(),
            String::from_utf8_lossy(&started.stderr).trim()
        ));
    }
    // The first start of the day compiles the world, so this waits in minutes
    // rather than seconds -- and says what it is waiting for, because a blank
    // terminal for four minutes is indistinguishable from a hang.
    eprintln!("starting the vivarium daemon…");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
    while std::time::Instant::now() < deadline {
        if UnixStream::connect(path).is_ok() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    Err(format!("the daemon did not come up on {}", path.display()))
}

pub struct Connection {
    writer: UnixStream,
    incoming: Receiver<Incoming>,
    next_id: u64,
}

impl Connection {
    pub fn open(path: &PathBuf) -> std::io::Result<Self> {
        let stream = UnixStream::connect(path)?;
        let writer = stream.try_clone()?;
        let (sender, incoming) = mpsc::channel();
        // The reader owns the socket's read half and nothing else. Parsing
        // happens here so a malformed line costs one line rather than the
        // connection.
        thread::spawn(move || {
            let reader = BufReader::new(stream);
            for line in reader.lines() {
                let message = match line {
                    Ok(text) => classify(&text),
                    Err(_) => Some(Incoming::Closed),
                };
                if let Some(message) = message {
                    let closed = matches!(message, Incoming::Closed);
                    if sender.send(message).is_err() || closed {
                        return;
                    }
                }
            }
            let _ = sender.send(Incoming::Closed);
        });
        Ok(Connection { writer, incoming, next_id: 1 })
    }

    /// Write a request without waiting. The caller's loop reads the reply out
    /// of the same stream everything else arrives on, so waiting here would
    /// stop it drawing until the daemon answered.
    pub fn send(&mut self, request: Value) -> std::io::Result<u64> {
        let id = self.next_id;
        self.next_id += 1;
        let mut request = request;
        if let Some(object) = request.as_object_mut() {
            object.insert("id".into(), json!(id));
        }
        let mut line = serde_json::to_string(&request).unwrap_or_default();
        line.push('\n');
        self.writer.write_all(line.as_bytes())?;
        self.writer.flush()?;
        Ok(id)
    }

    /// Everything that has arrived, without blocking.
    pub fn drain(&mut self) -> Vec<Incoming> {
        let mut batch = Vec::new();
        loop {
            match self.incoming.try_recv() {
                Ok(message) => batch.push(message),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    batch.push(Incoming::Closed);
                    break;
                }
            }
        }
        batch
    }

    /// Block until the response to `id` arrives, collecting the events that
    /// come first. The replay after `session.attach ... since 0` arrives this
    /// way -- before the response -- and dropping it is how a client shows an
    /// empty pane for a session with a hundred turns in it.
    pub fn wait_for(&mut self, id: u64, timeout: std::time::Duration)
        -> (Option<Value>, Vec<Event>)
    {
        let deadline = std::time::Instant::now() + timeout;
        let mut events = Vec::new();
        while std::time::Instant::now() < deadline {
            match self.incoming.recv_timeout(std::time::Duration::from_millis(50)) {
                Ok(Incoming::Event(event)) => events.push(event),
                Ok(Incoming::Response(value)) => {
                    let matches_id = value.get("id").and_then(Value::as_u64) == Some(id);
                    if matches_id {
                        return (Some(value), events);
                    }
                }
                Ok(Incoming::Greeting(_)) => {}
                Ok(Incoming::Closed) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        (None, events)
    }
}

fn classify(line: &str) -> Option<Incoming> {
    let value: Value = serde_json::from_str(line).ok()?;
    if value.get("event").is_some() {
        return serde_json::from_value::<Event>(value).ok().map(Incoming::Event);
    }
    match value.get("type").and_then(Value::as_str) {
        Some("response") => Some(Incoming::Response(value)),
        Some("ready") => Some(Incoming::Greeting(value)),
        _ => None,
    }
}

/// A session as the daemon describes it.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct SessionInfo {
    pub id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub effort: String,
    /// What the provider reported for the last request, and what this model
    /// accepts. Measured by the daemon: a client cannot know how full a
    /// context is from the transcript it happens to hold.
    #[serde(default)]
    pub tokens: u64,
    #[serde(default)]
    pub limit: u64,
}

/// A session that is not running: what choosing one from a list needs.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Recorded {
    pub id: String,
    #[serde(default)]
    pub cwd: String,
    /// When it was recorded, as Lisp universal time: seconds since 1900.
    #[serde(default)]
    pub time: u64,
    #[serde(default)]
    pub messages: u64,
    #[serde(default)]
    pub opening: String,
}

impl Recorded {
    /// How long ago, as a person says it: `3m`, `2h`, `4d`. Universal time
    /// counts from 1900 and Unix from 1970; the gap is a constant.
    pub fn age(&self, now_unix: u64) -> String {
        const GAP: u64 = 2_208_988_800;
        let then = self.time.saturating_sub(GAP);
        let seconds = now_unix.saturating_sub(then);
        match seconds {
            0..=59 => "now".into(),
            60..=3599 => format!("{}m", seconds / 60),
            3600..=86_399 => format!("{}h", seconds / 3600),
            _ => format!("{}d", seconds / 86_400),
        }
    }
}

/// One thing a project has retained: a note, a skill or a tool.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Retained {
    pub name: String,
    #[serde(default)]
    pub detail: String,
    /// "machine" or "project" -- where it was found, and therefore who else
    /// sees it. A machine-level tool loads in every project you open.
    #[serde(default)]
    pub scope: String,
}

/// What a session knows, from one `session.inspect`.
#[derive(Debug, Clone, Default)]
pub struct Learned {
    /// Whether we have asked yet. Distinguishes "retained nothing" from "have
    /// not looked", which look identical as counts and are different facts.
    pub inspected: bool,
    pub trusted: bool,
    pub notes: Vec<Retained>,
    pub skills: Vec<Retained>,
    pub tools: Vec<Retained>,
    /// Present on disk and NOT loaded, because the project is untrusted.
    /// Shown as refused rather than folded in: "there is a tool here" and "the
    /// agent can call it" are different facts.
    pub refused: Vec<Retained>,
}

impl Learned {
    pub fn total(&self) -> usize {
        self.notes.len() + self.skills.len() + self.tools.len()
    }

    pub fn from_reply(reply: &Value) -> Self {
        let list = |key: &str| -> Vec<Retained> {
            reply
                .get(key)
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| serde_json::from_value(item.clone()).ok())
                        .collect()
                })
                .unwrap_or_default()
        };
        Learned {
            inspected: true,
            trusted: reply.get("trusted").and_then(Value::as_bool).unwrap_or(false),
            notes: list("notes"),
            skills: list("skills"),
            tools: list("tools"),
            refused: list("refused"),
        }
    }
}

impl Recorded {
    pub fn short_cwd(&self) -> &str {
        let trimmed = self.cwd.trim_end_matches('/');
        match trimmed.rsplit_once('/') {
            Some((_, last)) if !last.is_empty() => last,
            _ => trimmed,
        }
    }
}

impl SessionInfo {
    /// The project, not the path it would be truncated to. Four sessions in
    /// sibling directories all rendered as `/Users/dev/works` in a twenty
    /// column sidebar said nothing at all.
    pub fn short_label(&self) -> &str {
        let source = if self.label.is_empty() { &self.cwd } else { &self.label };
        let trimmed = source.trim_end_matches('/');
        match trimmed.rsplit_once('/') {
            Some((_, last)) if !last.is_empty() => last,
            _ => trimmed,
        }
    }
}
